import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../models/playlist.dart';
import '../models/track.dart';
import 'library_provider.dart';

const _uuid = Uuid();

class PlaylistNotifier extends StateNotifier<AsyncValue<List<Playlist>>> {
  final AppDatabase _db;

  PlaylistNotifier(this._db) : super(const AsyncLoading()) {
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await _db.getAllPlaylists();
      final playlists = <Playlist>[];
      for (final row in rows) {
        final id = row['id'] as String;
        final trackRows = await _db.getPlaylistTracks(id);
        playlists.add(Playlist(
          id: id,
          name: row['name'] as String,
          trackIds: trackRows.map((t) => t['track_id'] as String).toList(),
          trackPaths: trackRows.map((t) => t['track_path'] as String).toList(),
          createdAt: DateTime.fromMillisecondsSinceEpoch(
              (row['created_at'] as int?) ?? 0),
          updatedAt: DateTime.fromMillisecondsSinceEpoch(
              (row['updated_at'] as int?) ?? 0),
          coverArtPath: row['cover_art_path'] as String?,
        ));
      }
      state = AsyncData(playlists);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<Playlist> createPlaylist(String name, List<Track> tracks) async {
    final id = _uuid.v4();
    final now = DateTime.now().millisecondsSinceEpoch;

    await _db.upsertPlaylist({
      'id': id,
      'name': name,
      'created_at': now,
      'updated_at': now,
    });

    if (tracks.isNotEmpty) {
      await _db.replacePlaylistTracks(
        id,
        tracks.asMap().entries.map((e) => {
              'playlist_id': id,
              'track_id': e.value.id,
              'track_path': e.value.filePath,
              'position': e.key,
            }).toList(),
      );
    }

    await _load();
    return Playlist(
      id: id,
      name: name,
      trackIds: tracks.map((t) => t.id).toList(),
      trackPaths: tracks.map((t) => t.filePath).toList(),
      createdAt: DateTime.fromMillisecondsSinceEpoch(now),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(now),
    );
  }

  Future<void> addTracksToPlaylist(
      String playlistId, List<Track> newTracks) async {
    final existing = await _db.getPlaylistTracks(playlistId);
    final startPos = existing.length;

    await _db.replacePlaylistTracks(playlistId, [
      ...existing.map((t) => {
            'playlist_id': t['playlist_id'],
            'track_id': t['track_id'],
            'track_path': t['track_path'],
            'position': t['position'],
          }),
      ...newTracks.asMap().entries.map((e) => {
            'playlist_id': playlistId,
            'track_id': e.value.id,
            'track_path': e.value.filePath,
            'position': startPos + e.key,
          }),
    ]);

    await _touchPlaylist(playlistId);
    await _load();
  }

  Future<void> removeTrack(String playlistId, int index) async {
    final tracks = await _db.getPlaylistTracks(playlistId);
    final updated = List<Map<String, Object?>>.from(tracks)..removeAt(index);

    await _db.replacePlaylistTracks(
      playlistId,
      updated.asMap().entries.map((e) => {
            'playlist_id': playlistId,
            'track_id': e.value['track_id'],
            'track_path': e.value['track_path'],
            'position': e.key,
          }).toList(),
    );
    await _touchPlaylist(playlistId);
    await _load();
  }

  Future<void> reorderTrack(
      String playlistId, int oldIndex, int newIndex) async {
    final tracks = await _db.getPlaylistTracks(playlistId);
    final list = List<Map<String, Object?>>.from(tracks);
    final item = list.removeAt(oldIndex);
    list.insert(newIndex < oldIndex ? newIndex : newIndex - 1, item);

    await _db.replacePlaylistTracks(
      playlistId,
      list.asMap().entries.map((e) => {
            'playlist_id': playlistId,
            'track_id': e.value['track_id'],
            'track_path': e.value['track_path'],
            'position': e.key,
          }).toList(),
    );
    await _load();
  }

  Future<void> renamePlaylist(String playlistId, String newName) async {
    final current = state.value?.firstWhere((p) => p.id == playlistId);
    if (current == null) return;
    await _db.upsertPlaylist({
      'id': playlistId,
      'name': newName,
      'created_at': current.createdAt.millisecondsSinceEpoch,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    });
    await _load();
  }

  Future<void> deletePlaylist(String playlistId) async {
    await _db.deletePlaylist(playlistId);
    await _load();
  }

  Future<void> clearPlaylist(String playlistId) async {
    await _db.replacePlaylistTracks(playlistId, []);
    await _touchPlaylist(playlistId);
    await _load();
  }

  Future<void> _touchPlaylist(String playlistId) async {
    final current = state.value?.firstWhere(
      (p) => p.id == playlistId,
      orElse: () => Playlist(
        id: playlistId,
        name: '',
        trackIds: [],
        trackPaths: [],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
    if (current == null) return;
    await _db.upsertPlaylist({
      'id': playlistId,
      'name': current.name,
      'created_at': current.createdAt.millisecondsSinceEpoch,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    });
  }
}

final playlistNotifierProvider =
    StateNotifierProvider<PlaylistNotifier, AsyncValue<List<Playlist>>>((ref) {
  return PlaylistNotifier(ref.watch(databaseProvider));
});

// ── Multi-select state ──────────────────────────────────────────────────────

class SelectionNotifier extends StateNotifier<Set<String>> {
  SelectionNotifier() : super({});

  void toggle(String path) {
    final s = Set<String>.from(state);
    if (s.contains(path)) {
      s.remove(path);
    } else {
      s.add(path);
    }
    state = s;
  }

  void clear() => state = {};

  bool isSelected(String path) => state.contains(path);
}

final selectionProvider =
    StateNotifierProvider<SelectionNotifier, Set<String>>((ref) {
  return SelectionNotifier();
});
