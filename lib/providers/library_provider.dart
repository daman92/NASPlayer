import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/app_database.dart';
import '../models/track.dart';
import '../services/local_scanner.dart';
import '../services/saf_scanner.dart';
import '../services/settings_service.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  return AppDatabase.instance;
});

final settingsServiceProvider = Provider<SettingsService>((ref) {
  return SettingsService();
});

final localScannerProvider = Provider<LocalScanner>((ref) => LocalScanner());
final safScannerProvider = Provider<SafScanner>((ref) => SafScanner());

// ── Current local folder ───────────────────────────────────────────────────

final currentFolderProvider = StateProvider<String?>((ref) => null);

/// Restores the last opened folder on launch so the cached SQLite index is
/// immediately visible without a rescan (design 6.2).
final lastFolderRestoreProvider = FutureProvider<String?>((ref) async {
  final settings = ref.watch(settingsServiceProvider);
  return settings.getLastLocalFolder();
});

// ── Library sort/filter state (design 6.3) ─────────────────────────────────

enum LibrarySort { name, artist, album, dateModified, duration }

final librarySortProvider = StateProvider<LibrarySort>((ref) => LibrarySort.name);
final libraryFormatFilterProvider = StateProvider<String>((ref) => '');
final libraryGroupByAlbumProvider = StateProvider<bool>((ref) => false);

// ── Library tracks for current folder ─────────────────────────────────────

/// Page size for incremental loading of very large libraries (design 6.2).
const libraryPageSize = 500;

final folderTracksProvider =
    FutureProvider.family<List<Track>, String>((ref, folderPath) async {
  final db = ref.watch(databaseProvider);
  final rows = await db.getTracksForFolder(folderPath);
  return rows.map(rowToTrack).toList();
});

final folderTrackCountProvider =
    FutureProvider.family<int, String>((ref, folderPath) async {
  final db = ref.watch(databaseProvider);
  return db.countTracksForFolder(folderPath);
});

final folderTracksPageProvider = FutureProvider.family<List<Track>,
    ({String folder, int page})>((ref, args) async {
  final db = ref.watch(databaseProvider);
  final rows = await db.getTracksForFolder(
    args.folder,
    limit: libraryPageSize,
    offset: args.page * libraryPageSize,
  );
  return rows.map(rowToTrack).toList();
});

// ── Scan state ─────────────────────────────────────────────────────────────

class ScanState {
  final bool scanning;
  final int scanned;
  final int found;
  final String? currentPath;
  final String? error;

  const ScanState({
    this.scanning = false,
    this.scanned = 0,
    this.found = 0,
    this.currentPath,
    this.error,
  });

  ScanState copyWith({
    bool? scanning,
    int? scanned,
    int? found,
    String? currentPath,
    String? error,
  }) =>
      ScanState(
        scanning: scanning ?? this.scanning,
        scanned: scanned ?? this.scanned,
        found: found ?? this.found,
        currentPath: currentPath ?? this.currentPath,
        error: error ?? this.error,
      );
}

class ScanNotifier extends StateNotifier<ScanState> {
  final LocalScanner _scanner;
  final AppDatabase _db;
  final SettingsService _settings;
  final Ref _ref;

  ScanNotifier(this._scanner, this._db, this._settings, this._ref)
      : super(const ScanState());

  Future<void> scanFolder(String folderPath) async {
    state = const ScanState(scanning: true);

    // SAF document trees (Google Drive, USB, other cloud providers) have no
    // filesystem path — scan them through the DocumentsProvider channel.
    if (folderPath.startsWith('content://')) {
      await _scanSafTree(folderPath);
      return;
    }

    try {
      // A missing folder (unmounted SD card, renamed path) must NOT wipe
      // the existing cached index with an empty scan result.
      if (!Directory(folderPath).existsSync()) {
        state = ScanState(
          scanning: false,
          error: 'Folder not found: $folderPath — keeping the cached index',
        );
        return;
      }

      await _settings.setLastLocalFolder(folderPath);

      final tracks = <Track>[];
      await for (final progress in _scanner.scan(
        folderPath,
        onTrackFound: (track) => tracks.add(track),
      )) {
        state = state.copyWith(
          scanned: progress.scanned,
          found: progress.found,
          currentPath: progress.currentPath,
        );
      }

      // Atomic delete+insert: an interrupted scan can't wipe the old index.
      await _db.replaceTracksForFolder(
          folderPath, tracks.map(trackToRow).toList());

      state = ScanState(
        scanning: false,
        scanned: state.scanned,
        found: tracks.length,
      );

      // Refresh every view of this folder (design 6.2: rescan visibility).
      _ref.invalidate(folderTracksProvider);
      _ref.invalidate(folderTracksPageProvider);
      _ref.invalidate(folderTrackCountProvider);
    } catch (e) {
      state = ScanState(scanning: false, error: e.toString());
    }
  }

  Future<void> _scanSafTree(String treeUri) async {
    try {
      await _settings.setLastLocalFolder(treeUri);
      state = const ScanState(
          scanning: true, currentPath: 'Listing cloud folder...');

      final tracks = await _ref.read(safScannerProvider).scanTree(treeUri);

      // Guard against wiping a previously indexed tree when the provider
      // returns nothing (e.g. Drive briefly offline).
      if (tracks.isEmpty && await _db.countTracksForFolder(treeUri) > 0) {
        state = const ScanState(
          scanning: false,
          error: 'No files returned — keeping the cached index',
        );
        return;
      }

      await _db.replaceTracksForFolder(
          treeUri, tracks.map(trackToRow).toList());

      state = ScanState(
        scanning: false,
        scanned: tracks.length,
        found: tracks.length,
      );

      _ref.invalidate(folderTracksProvider);
      _ref.invalidate(folderTracksPageProvider);
      _ref.invalidate(folderTrackCountProvider);
    } catch (e) {
      state = ScanState(scanning: false, error: e.toString());
    }
  }
}

final scanNotifierProvider =
    StateNotifierProvider<ScanNotifier, ScanState>((ref) {
  return ScanNotifier(
    ref.watch(localScannerProvider),
    ref.watch(databaseProvider),
    ref.watch(settingsServiceProvider),
    ref,
  );
});

// ── Search (design 6.3: within folder or full library) ────────────────────

final searchQueryProvider = StateProvider<String>((ref) => '');
final searchInFolderProvider = StateProvider<bool>((ref) => false);

final searchResultsProvider = FutureProvider.family<List<Track>,
    ({String query, String? folder})>((ref, args) async {
  if (args.query.isEmpty) return [];
  final db = ref.watch(databaseProvider);
  final rows = await db.searchTracks(args.query, folderPath: args.folder);
  return rows.map(rowToTrack).toList();
});

/// All indexed tracks — used for format-filter browsing with no query.
final allTracksProvider = FutureProvider<List<Track>>((ref) async {
  final db = ref.watch(databaseProvider);
  final rows = await db.getAllTracks();
  return rows.map(rowToTrack).toList();
});

// ── Row converters ─────────────────────────────────────────────────────────

Track rowToTrack(Map<String, Object?> row) => Track(
      id: row['id'] as String,
      title: row['title'] as String,
      artist: row['artist'] as String? ?? 'Unknown Artist',
      album: row['album'] as String? ?? 'Unknown Album',
      duration: Duration(milliseconds: (row['duration_ms'] as int?) ?? 0),
      filePath: row['file_path'] as String,
      nasPath: row['nas_path'] as String?,
      artworkPath: row['artwork_path'] as String?,
      source: (row['source'] as String?) == 'nas'
          ? TrackSource.nas
          : TrackSource.local,
      format: row['format'] as String? ?? '',
      bitDepth: row['bit_depth'] as int?,
      sampleRate: row['sample_rate'] as int?,
      bitrate: row['bitrate'] as int?,
      dateModified: row['date_modified'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['date_modified'] as int)
          : null,
    );

Map<String, Object?> trackToRow(Track t) {
  final folderPath = t.filePath.contains('/')
      ? t.filePath.substring(0, t.filePath.lastIndexOf('/') + 1)
      : t.filePath.contains(r'\')
          ? t.filePath.substring(0, t.filePath.lastIndexOf(r'\') + 1)
          : '';

  return {
    'id': t.id,
    'title': t.title,
    'artist': t.artist,
    'album': t.album,
    'title_lc': t.title.toLowerCase(),
    'artist_lc': t.artist.toLowerCase(),
    'album_lc': t.album.toLowerCase(),
    'duration_ms': t.duration.inMilliseconds,
    'file_path': t.filePath,
    'nas_path': t.nasPath,
    'artwork_path': t.artworkPath,
    'format': t.format,
    'bit_depth': t.bitDepth,
    'sample_rate': t.sampleRate,
    'bitrate': t.bitrate,
    'source': t.source.name,
    'folder_path': folderPath,
    'date_modified': t.dateModified?.millisecondsSinceEpoch,
    'indexed_at': DateTime.now().millisecondsSinceEpoch,
  };
}
