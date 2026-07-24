import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'library_provider.dart';

class PlayHistoryEntry {
  final String trackId;
  final String title;
  final String artist;
  final String album;
  final String filePath;
  final String? nasPath;
  final String source;
  final DateTime playedAt;
  final int playCount;

  const PlayHistoryEntry({
    required this.trackId,
    required this.title,
    required this.artist,
    required this.album,
    required this.filePath,
    required this.source,
    required this.playedAt,
    this.nasPath,
    this.playCount = 1,
  });
}

PlayHistoryEntry _rowToEntry(Map<String, Object?> row) => PlayHistoryEntry(
      trackId: row['track_id'] as String? ?? '',
      title: row['title'] as String? ?? 'Unknown',
      artist: row['artist'] as String? ?? '',
      album: row['album'] as String? ?? '',
      filePath: row['file_path'] as String? ?? '',
      nasPath: row['nas_path'] as String?,
      source: row['source'] as String? ?? 'local',
      playedAt: DateTime.fromMillisecondsSinceEpoch(
          (row['played_at'] as int?) ?? (row['last_played'] as int?) ?? 0),
      playCount: (row['play_count'] as int?) ?? 1,
    );

/// Recent plays, newest first. Watch [historyRefreshProvider] to re-query.
final recentPlaysProvider = FutureProvider<List<PlayHistoryEntry>>((ref) async {
  ref.watch(historyRefreshProvider);
  final db = ref.watch(databaseProvider);
  final rows = await db.getRecentPlays(limit: 200);
  return rows.map(_rowToEntry).toList();
});

final mostPlayedProvider = FutureProvider<List<PlayHistoryEntry>>((ref) async {
  ref.watch(historyRefreshProvider);
  final db = ref.watch(databaseProvider);
  final rows = await db.getMostPlayed(limit: 100);
  return rows.map(_rowToEntry).toList();
});

/// Bump to force history re-query after playback or clearing.
final historyRefreshProvider = StateProvider<int>((ref) => 0);
