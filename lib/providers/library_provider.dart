import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/app_database.dart';
import '../models/track.dart';
import '../services/local_scanner.dart';
import '../services/settings_service.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  return AppDatabase.instance;
});

final settingsServiceProvider = Provider<SettingsService>((ref) {
  return SettingsService();
});

final localScannerProvider = Provider<LocalScanner>((ref) => LocalScanner());

// ── Current local folder ───────────────────────────────────────────────────

final currentFolderProvider = StateProvider<String?>((ref) => null);

// ── Library tracks for current folder ─────────────────────────────────────

final folderTracksProvider =
    FutureProvider.family<List<Track>, String>((ref, folderPath) async {
  final db = ref.watch(databaseProvider);
  final rows = await db.getTracksForFolder(folderPath);
  return rows.map(_rowToTrack).toList();
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

  ScanNotifier(this._scanner, this._db, this._settings)
      : super(const ScanState());

  Future<void> scanFolder(String folderPath) async {
    state = const ScanState(scanning: true);

    try {
      await _db.deleteTracksForFolder(folderPath);
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

      if (tracks.isNotEmpty) {
        await _db.upsertTracks(tracks.map(_trackToRow).toList());
      }

      state = ScanState(
        scanning: false,
        scanned: state.scanned,
        found: tracks.length,
      );
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
  );
});

// ── Search ─────────────────────────────────────────────────────────────────

final searchQueryProvider = StateProvider<String>((ref) => '');

final searchResultsProvider =
    FutureProvider.family<List<Track>, String>((ref, query) async {
  if (query.isEmpty) return [];
  final db = ref.watch(databaseProvider);
  final rows = await db.searchTracks(query);
  return rows.map(_rowToTrack).toList();
});

// ── Row converters ─────────────────────────────────────────────────────────

Track _rowToTrack(Map<String, Object?> row) => Track(
      id: row['id'] as String,
      title: row['title'] as String,
      artist: row['artist'] as String? ?? 'Unknown Artist',
      album: row['album'] as String? ?? 'Unknown Album',
      duration: Duration(milliseconds: (row['duration_ms'] as int?) ?? 0),
      filePath: row['file_path'] as String,
      artworkPath: row['artwork_path'] as String?,
      source: (row['source'] as String?) == 'nas'
          ? TrackSource.nas
          : TrackSource.local,
      format: row['format'] as String? ?? '',
      bitDepth: row['bit_depth'] as int?,
      sampleRate: row['sample_rate'] as int?,
      bitrate: row['bitrate'] as int?,
    );

Map<String, Object?> _trackToRow(Track t) {
  final folderPath = t.filePath.contains('/')
      ? t.filePath.substring(0, t.filePath.lastIndexOf('/') + 1)
      : t.filePath.contains('\\')
          ? t.filePath.substring(0, t.filePath.lastIndexOf('\\') + 1)
          : '';

  return {
    'id': t.id,
    'title': t.title,
    'artist': t.artist,
    'album': t.album,
    'duration_ms': t.duration.inMilliseconds,
    'file_path': t.filePath,
    'artwork_path': t.artworkPath,
    'format': t.format,
    'bit_depth': t.bitDepth,
    'sample_rate': t.sampleRate,
    'bitrate': t.bitrate,
    'source': t.source.name,
    'folder_path': folderPath,
    'indexed_at': DateTime.now().millisecondsSinceEpoch,
  };
}
