import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../models/nas_config.dart';
import '../models/track.dart';
import '../nas/nas_adapter.dart';
import '../nas/nas_detector.dart';
import '../services/settings_service.dart';
import 'audio_provider.dart';
import 'library_provider.dart';

const _uuid = Uuid();

final nasDetectorProvider = Provider<NasDetector>((ref) {
  return const NasDetector();
});

// ── NAS config list ────────────────────────────────────────────────────────

class NasConfigNotifier extends StateNotifier<List<NasConfig>> {
  final AppDatabase _db;
  final SettingsService _settings;

  /// Completes when the initial SQLite load has populated [state] — lets
  /// startup code await configs instead of racing the async constructor.
  late final Future<void> ready;

  NasConfigNotifier(this._db, this._settings) : super([]) {
    ready = _load();
  }

  Future<void> _load() async {
    final rows = await _db.getAllNasConfigs();
    state = rows
        .map((r) => NasConfig(
              id: r['id'] as String,
              name: r['name'] as String,
              baseUrl: r['base_url'] as String,
              vendor: NasVendor.values.firstWhere(
                (v) => v.name == (r['vendor'] as String? ?? 'unknown'),
                orElse: () => NasVendor.unknown,
              ),
              isActive: (r['is_active'] as int?) == 1,
              addedAt: DateTime.fromMillisecondsSinceEpoch(
                  (r['added_at'] as int?) ?? 0),
            ))
        .toList();
  }

  Future<NasConfig> addConfig(String name, String baseUrl) async {
    final id = _uuid.v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.upsertNasConfig({
      'id': id,
      'name': name,
      'base_url': baseUrl,
      'vendor': NasVendor.unknown.name,
      'is_active': 0,
      'added_at': now,
    });
    await _load();
    return NasConfig(
      id: id,
      name: name,
      baseUrl: baseUrl,
      vendor: NasVendor.unknown,
      addedAt: DateTime.fromMillisecondsSinceEpoch(now),
    );
  }

  /// Edit a device's display name and/or URL. Returns true when the URL
  /// changed (callers should drop the live session — its cookies belong to
  /// the old address).
  Future<bool> updateConfig(String id,
      {required String name, required String baseUrl}) async {
    final current = state.firstWhereOrNull((c) => c.id == id);
    if (current == null) return false;
    final urlChanged = current.baseUrl != baseUrl;
    await _db.upsertNasConfig({
      'id': id,
      'name': name,
      'base_url': baseUrl,
      'vendor': current.vendor.name,
      'is_active': current.isActive ? 1 : 0,
      'added_at': current.addedAt.millisecondsSinceEpoch,
    });
    if (urlChanged) {
      await _settings.deleteCookiesForNas(id);
      await _db.clearNasIndex(id);
    }
    await _load();
    return urlChanged;
  }

  Future<void> updateVendor(String id, NasVendor vendor) async {
    final current = state.firstWhereOrNull((c) => c.id == id);
    if (current == null) return;
    await _db.upsertNasConfig({
      'id': id,
      'name': current.name,
      'base_url': current.baseUrl,
      'vendor': vendor.name,
      'is_active': current.isActive ? 1 : 0,
      'added_at': current.addedAt.millisecondsSinceEpoch,
    });
    await _load();
  }

  Future<void> setActive(String id) async {
    await _db.setActiveNasConfig(id);
    await _load();
  }

  Future<void> remove(String id) async {
    await _db.deleteNasConfig(id);
    // Don't leave stale session cookies or cached listings behind.
    await _settings.deleteCookiesForNas(id);
    await _db.clearNasIndex(id);
    await _load();
  }

  NasConfig? get activeConfig {
    return state.firstWhereOrNull((c) => c.isActive) ??
        (state.isNotEmpty ? state.first : null);
  }
}

final nasConfigNotifierProvider =
    StateNotifierProvider<NasConfigNotifier, List<NasConfig>>((ref) {
  return NasConfigNotifier(
    ref.watch(databaseProvider),
    ref.watch(settingsServiceProvider),
  );
});

// ── Authenticated NAS adapter (with cookies) ───────────────────────────────

class AuthenticatedNasNotifier extends StateNotifier<NasAdapter?> {
  final Ref _ref;

  AuthenticatedNasNotifier(this._ref) : super(null);

  SettingsService get _settings => _ref.read(settingsServiceProvider);

  /// Called after WebView login. Detects the vendor (design 8.2), persists
  /// it, builds the matching adapter, and plumbs streaming headers into the
  /// audio handler.
  Future<NasVendor?> authenticate(
    String nasId,
    String baseUrl,
    String cookies, {
    Map<String, String> extraHeaders = const {},
  }) async {
    await _settings.saveCookiesForNas(nasId, cookies);
    if (extraHeaders.isNotEmpty) {
      await _settings.saveExtraHeadersForNas(nasId, extraHeaders);
    }

    final detector = _ref.read(nasDetectorProvider);
    final configNotifier = _ref.read(nasConfigNotifierProvider.notifier);
    final config = _ref
        .read(nasConfigNotifierProvider)
        .firstWhereOrNull((c) => c.id == nasId);

    NasVendor? vendor = config?.vendor;
    if (vendor == null || vendor == NasVendor.unknown) {
      vendor = await detector.detectVendor(baseUrl, cookies,
          extraHeaders: extraHeaders);
      if (vendor != null) {
        await configNotifier.updateVendor(nasId, vendor);
      }
    }

    final adapter = detector.adapterForVendor(
      vendor ?? NasVendor.synology,
      baseUrl,
      cookies,
      extraHeaders: extraHeaders,
    );
    await adapter.prepare();
    state = adapter;
    _wireStreamingHeaders(adapter);
    await _settings.saveActiveNasContext(
        nasId: nasId, baseUrl: baseUrl, vendor: adapter.vendor.name);
    _ref.read(nasAuthExpiredProvider.notifier).state = false;

    // Rebuild any queued NAS sources with the fresh session so playback
    // recovers after a mid-queue re-login.
    try {
      await _ref.read(audioHandlerProvider).refreshNasSources();
    } catch (_) {}
    return vendor;
  }

  /// Rebuild the adapter from stored cookies (app relaunch — design 8.2).
  Future<bool> restoreSession(String nasId, String baseUrl,
      {NasVendor vendor = NasVendor.unknown}) async {
    final cookies = await _settings.getCookiesForNas(nasId);
    if (cookies == null || cookies.isEmpty) return false;
    final extraHeaders = await _settings.getExtraHeadersForNas(nasId);

    final detector = _ref.read(nasDetectorProvider);
    final adapter = detector.adapterForVendor(
      vendor == NasVendor.unknown ? NasVendor.synology : vendor,
      baseUrl,
      cookies,
      extraHeaders: extraHeaders,
    );
    await adapter.prepare();
    state = adapter;
    _wireStreamingHeaders(adapter);
    await _settings.saveActiveNasContext(
        nasId: nasId, baseUrl: baseUrl, vendor: adapter.vendor.name);
    return true;
  }

  /// Rebuild the adapter when the user manually overrides the vendor.
  Future<void> rebuildForVendor(
      String nasId, String baseUrl, NasVendor vendor) async {
    final cookies = await _settings.getCookiesForNas(nasId) ?? '';
    if (cookies.isEmpty) return;
    final extraHeaders = await _settings.getExtraHeadersForNas(nasId);
    final adapter = _ref.read(nasDetectorProvider).adapterForVendor(
          vendor,
          baseUrl,
          cookies,
          extraHeaders: extraHeaders,
        );
    await adapter.prepare();
    state = adapter;
    _wireStreamingHeaders(adapter);
    await _settings.saveActiveNasContext(
        nasId: nasId, baseUrl: baseUrl, vendor: vendor.name);
  }

  void _wireStreamingHeaders(NasAdapter adapter) {
    try {
      final handler = _ref.read(audioHandlerProvider);
      handler.nasHeaderProvider = () => adapter.streamHeaders;
      handler.nasUrlResolver = adapter.getStreamUrl;
    } catch (_) {
      // Handler not initialized (tests).
    }
    // Persist for headless (Android Auto) queue restore.
    _settings.saveActiveNasHeaders(adapter.streamHeaders);
  }

  void markExpired() {
    _ref.read(nasAuthExpiredProvider.notifier).state = true;
  }

  void clear() => state = null;
}

final authenticatedNasProvider =
    StateNotifierProvider<AuthenticatedNasNotifier, NasAdapter?>((ref) {
  return AuthenticatedNasNotifier(ref);
});

/// True when the NAS rejected the session — the UI shows a re-login prompt
/// (design section 7: session cookie expiry).
final nasAuthExpiredProvider = StateProvider<bool>((ref) => false);

/// One-shot startup restore of the active NAS session.
final nasSessionRestoreProvider = FutureProvider<bool>((ref) async {
  final notifier = ref.read(nasConfigNotifierProvider.notifier);
  await notifier.ready;
  final active = notifier.activeConfig;
  if (active == null) return false;
  return ref.read(authenticatedNasProvider.notifier).restoreSession(
        active.id,
        active.baseUrl,
        vendor: active.vendor,
      );
});

// ── NAS search (over the cached index) ─────────────────────────────────────

/// Search NAS audio files by filename against the locally cached index.
/// Coverage grows as folders are browsed, or becomes complete after a full
/// index crawl ([nasIndexCrawlProvider]).
final nasSearchResultsProvider =
    FutureProvider.family<List<Track>, String>((ref, query) async {
  if (query.isEmpty) return [];
  final adapter = ref.watch(authenticatedNasProvider);
  if (adapter == null) return [];
  final active = ref.read(nasConfigNotifierProvider.notifier).activeConfig;
  if (active == null) return [];

  // Re-query after a crawl finishes.
  ref.watch(nasIndexCrawlProvider);

  final db = ref.read(databaseProvider);
  final rows = await db.searchNasIndex(active.id, query);
  return rows
      .map((r) => NasFileEntry(
            name: r['name'] as String,
            path: r['path'] as String,
            isDirectory: false,
            size: r['size_bytes'] as int?,
          ))
      .where((e) => e.isAudio)
      .map(adapter.entryToTrack)
      .toList();
});

class NasCrawlState {
  final bool crawling;
  final int folders;
  final int files;
  final DateTime? lastCompleted;
  final String? error;

  const NasCrawlState({
    this.crawling = false,
    this.folders = 0,
    this.files = 0,
    this.lastCompleted,
    this.error,
  });
}

/// Walks the whole NAS tree and caches every listing into the nas_index
/// table, making NAS search comprehensive (design 6.2: NAS library index
/// cached locally).
class NasIndexCrawlNotifier extends StateNotifier<NasCrawlState> {
  final Ref _ref;
  bool _cancelRequested = false;

  static const _maxFolders = 5000;

  NasIndexCrawlNotifier(this._ref) : super(const NasCrawlState());

  Future<void> crawl() async {
    if (state.crawling) return;
    final adapter = _ref.read(authenticatedNasProvider);
    final active = _ref.read(nasConfigNotifierProvider.notifier).activeConfig;
    if (adapter == null || active == null) return;

    _cancelRequested = false;
    state = const NasCrawlState(crawling: true);
    final db = _ref.read(databaseProvider);

    var folders = 0;
    var files = 0;
    final pending = <String>['/'];

    try {
      while (pending.isNotEmpty && !_cancelRequested) {
        if (folders >= _maxFolders) break;
        final path = pending.removeAt(0);

        List<NasFileEntry> entries;
        try {
          entries = await adapter.listDirectory(path);
        } on NasAuthException {
          _ref.read(nasAuthExpiredProvider.notifier).state = true;
          rethrow;
        } catch (_) {
          continue; // Unreadable folder — skip, keep crawling.
        }
        folders++;

        final now = DateTime.now().millisecondsSinceEpoch;
        await db.replaceNasIndexForParent(
          active.id,
          path,
          entries
              .map((e) => <String, Object?>{
                    'nas_id': active.id,
                    'path': e.path,
                    'name': e.name,
                    'parent_path': path,
                    'is_directory': e.isDirectory ? 1 : 0,
                    'size_bytes': e.size,
                    'modified_at': e.modified?.millisecondsSinceEpoch,
                    'indexed_at': now,
                  })
              .toList(),
        );

        for (final e in entries) {
          if (e.isDirectory) {
            pending.add(e.path);
          } else if (e.isAudio) {
            files++;
          }
        }
        if (mounted) {
          state = NasCrawlState(crawling: true, folders: folders, files: files);
        }
      }

      if (mounted) {
        state = NasCrawlState(
          crawling: false,
          folders: folders,
          files: files,
          lastCompleted: _cancelRequested ? null : DateTime.now(),
        );
      }
    } catch (e) {
      if (mounted) {
        state = NasCrawlState(
          crawling: false,
          folders: folders,
          files: files,
          error: e.toString(),
        );
      }
    }
  }

  void cancel() => _cancelRequested = true;
}

final nasIndexCrawlProvider =
    StateNotifierProvider<NasIndexCrawlNotifier, NasCrawlState>((ref) {
  return NasIndexCrawlNotifier(ref);
});

// ── NAS file browsing (live, cached into SQLite for offline fallback) ──────

final nasBrowseProvider =
    FutureProvider.family<List<NasFileEntry>, String>((ref, path) async {
  final adapter = ref.watch(authenticatedNasProvider);
  if (adapter == null) return [];

  final db = ref.read(databaseProvider);
  final active = ref.read(nasConfigNotifierProvider.notifier).activeConfig;
  final nasId = active?.id ?? '';

  try {
    final entries = await adapter.listDirectory(path);

    // Cache the listing locally so browsing survives NAS outages (design 6.2).
    if (nasId.isNotEmpty) {
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.replaceNasIndexForParent(
        nasId,
        path,
        entries
            .map((e) => <String, Object?>{
                  'nas_id': nasId,
                  'path': e.path,
                  'name': e.name,
                  'parent_path': path,
                  'is_directory': e.isDirectory ? 1 : 0,
                  'size_bytes': e.size,
                  'modified_at': e.modified?.millisecondsSinceEpoch,
                  'indexed_at': now,
                })
            .toList(),
      );
    }
    return entries;
  } on NasAuthException {
    ref.read(nasAuthExpiredProvider.notifier).state = true;
    rethrow;
  } on Exception {
    // Offline fallback: serve the cached index when the NAS is unreachable.
    if (nasId.isNotEmpty) {
      final cached = await db.getNasIndexForParent(nasId, path);
      if (cached.isNotEmpty) {
        return cached
            .map((r) => NasFileEntry(
                  name: r['name'] as String,
                  path: r['path'] as String,
                  isDirectory: (r['is_directory'] as int?) == 1,
                  size: r['size_bytes'] as int?,
                  modified: r['modified_at'] != null
                      ? DateTime.fromMillisecondsSinceEpoch(
                          r['modified_at'] as int)
                      : null,
                ))
            .toList();
      }
    }
    rethrow;
  }
});
