import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../models/nas_config.dart';
import '../nas/nas_adapter.dart';
import '../nas/nas_detector.dart';
import '../nas/synology_adapter.dart';
import '../services/settings_service.dart';
import 'library_provider.dart';

const _uuid = Uuid();

final nasDetectorProvider = Provider<NasDetector>((ref) {
  return NasDetector(ref.watch(settingsServiceProvider));
});

// ── NAS config list ────────────────────────────────────────────────────────

class NasConfigNotifier extends StateNotifier<List<NasConfig>> {
  final AppDatabase _db;

  NasConfigNotifier(this._db) : super([]) {
    _load();
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

  Future<void> updateVendor(String id, NasVendor vendor) async {
    final current = state.firstWhere((c) => c.id == id);
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
    await _load();
  }

  NasConfig? get activeConfig {
    try {
      return state.firstWhere((c) => c.isActive);
    } catch (_) {
      return state.isNotEmpty ? state.first : null;
    }
  }
}

final nasConfigNotifierProvider =
    StateNotifierProvider<NasConfigNotifier, List<NasConfig>>((ref) {
  return NasConfigNotifier(ref.watch(databaseProvider));
});

// ── Authenticated NAS adapter (with cookies) ───────────────────────────────

class AuthenticatedNasNotifier extends StateNotifier<NasAdapter?> {
  final SettingsService _settings;

  AuthenticatedNasNotifier(this._settings) : super(null);

  Future<void> authenticate(
      String nasId, String baseUrl, String cookies) async {
    await _settings.saveCookiesForNas(nasId, cookies);
    state = SynologyAdapter(baseUrl, cookies: cookies);
  }

  Future<void> restoreSession(String nasId, String baseUrl) async {
    final cookies = await _settings.getCookiesForNas(nasId);
    if (cookies != null && cookies.isNotEmpty) {
      state = SynologyAdapter(baseUrl, cookies: cookies);
    }
  }

  void clear() => state = null;
}

final authenticatedNasProvider =
    StateNotifierProvider<AuthenticatedNasNotifier, NasAdapter?>((ref) {
  return AuthenticatedNasNotifier(ref.watch(settingsServiceProvider));
});

// ── NAS file browsing ──────────────────────────────────────────────────────

final nasBrowseProvider =
    FutureProvider.family<List<NasFileEntry>, String>((ref, path) async {
  final adapter = ref.watch(authenticatedNasProvider);
  if (adapter == null) return [];
  return adapter.listDirectory(path);
});
