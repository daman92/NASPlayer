import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../models/playlist.dart';
import '../models/track.dart';
import 'library_provider.dart';
import 'nas_provider.dart';

const _uuid = Uuid();

/// Prefix marking a NAS path in playlist storage. NAS playlist entries store
/// the raw NAS path (not a stream URL), so they can be re-resolved with fresh
/// session cookies at play time.
const nasPathPrefix = 'nas://';

String playlistPathForTrack(Track t) =>
    t.source == TrackSource.nas && t.nasPath != null
        ? '$nasPathPrefix${t.nasPath}'
        : t.filePath;

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

    await _db.insertPlaylist({
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
              'track_path': playlistPathForTrack(e.value),
              'position': e.key,
            }).toList(),
      );
    }

    await _load();
    return Playlist(
      id: id,
      name: name,
      trackIds: tracks.map((t) => t.id).toList(),
      trackPaths: tracks.map(playlistPathForTrack).toList(),
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
            'track_path': playlistPathForTrack(e.value),
            'position': startPos + e.key,
          }),
    ]);

    await _touchPlaylist(playlistId);
    await _load();
  }

  Future<void> removeTrack(String playlistId, int index) async {
    final tracks = await _db.getPlaylistTracks(playlistId);
    if (index < 0 || index >= tracks.length) return;
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

  /// Accepts raw ReorderableListView onReorder indices (newIndex includes
  /// the removed slot when dragging down).
  Future<void> reorderTrack(String playlistId, int oldIndex, int newIndex) {
    var target = newIndex;
    if (target > oldIndex) target -= 1;
    return moveTrack(playlistId, oldIndex, target);
  }

  /// Move with already-adjusted indices (onReorderItem semantics).
  Future<void> moveTrack(
      String playlistId, int oldIndex, int target) async {
    final tracks = await _db.getPlaylistTracks(playlistId);
    if (oldIndex < 0 ||
        oldIndex >= tracks.length ||
        target < 0 ||
        target >= tracks.length ||
        target == oldIndex) {
      return;
    }

    final list = List<Map<String, Object?>>.from(tracks);
    final item = list.removeAt(oldIndex);
    list.insert(target, item);

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
    await _db.updatePlaylist(playlistId, {
      'name': newName,
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
    await _db.updatePlaylist(playlistId, {
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    });
  }
}

final playlistNotifierProvider =
    StateNotifierProvider<PlaylistNotifier, AsyncValue<List<Playlist>>>((ref) {
  return PlaylistNotifier(ref.watch(databaseProvider));
});

// ── Playlist playback resolution (design 5.3 / 7) ──────────────────────────

class ResolvedPlaylist {
  final List<Track> tracks;
  final List<String> skipped;

  /// For each entry in [tracks], its index in the ORIGINAL path list — used
  /// to remap a tapped row index onto the resolved (shortened) list.
  final List<int> originalIndices;

  const ResolvedPlaylist(this.tracks, this.skipped, this.originalIndices);

  /// Index into [tracks] for the original row [originalIndex] (the first
  /// resolved entry at-or-after it, so taps below skipped rows stay aligned).
  int resolveStartIndex(int originalIndex) {
    for (var i = 0; i < originalIndices.length; i++) {
      if (originalIndices[i] >= originalIndex) return i;
    }
    return tracks.isEmpty ? 0 : tracks.length - 1;
  }
}

/// Resolve playlist paths into playable Tracks:
/// - local paths are looked up in the library index (fallback: raw file) and
///   verified to exist — missing files are skipped and reported (design 7);
/// - NAS paths (`nas://...`) are re-resolved to authenticated stream URLs
///   with the active adapter; without a session they are skipped.
Future<ResolvedPlaylist> resolvePlaylistTracks(
    WidgetRef ref, List<String> paths) async {
  final db = ref.read(databaseProvider);
  final adapter = ref.read(authenticatedNasProvider);

  final lookupPaths = paths
      .map((p) => p.startsWith(nasPathPrefix)
          ? p.substring(nasPathPrefix.length)
          : p)
      .toList();
  final rows = await db.getTracksByPaths(lookupPaths);
  final byPath = <String, Map<String, Object?>>{
    for (final row in rows) row['file_path'] as String: row,
    for (final row in rows)
      if (row['nas_path'] != null) row['nas_path'] as String: row,
  };

  final tracks = <Track>[];
  final skipped = <String>[];
  final originalIndices = <int>[];

  for (var pathIndex = 0; pathIndex < paths.length; pathIndex++) {
    final rawPath = paths[pathIndex];
    final isNas = rawPath.startsWith(nasPathPrefix);
    final path =
        isNas ? rawPath.substring(nasPathPrefix.length) : rawPath;
    final name = path.split(RegExp(r'[\\/]')).last;
    final title =
        name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;

    if (isNas) {
      if (adapter == null) {
        skipped.add(name);
        continue;
      }
      final row = byPath[path];
      tracks.add(Track(
        id: row?['id'] as String? ?? path,
        title: row?['title'] as String? ?? title,
        artist: row?['artist'] as String? ?? 'Unknown Artist',
        album: row?['album'] as String? ?? 'Unknown Album',
        duration:
            Duration(milliseconds: (row?['duration_ms'] as int?) ?? 0),
        filePath: adapter.getStreamUrl(path),
        nasPath: path,
        httpHeaders: adapter.streamHeaders,
        source: TrackSource.nas,
        format: name.contains('.') ? name.split('.').last.toLowerCase() : '',
      ));
      originalIndices.add(pathIndex);
      continue;
    }

    // Local: skip files that no longer exist (design 7). SAF content URIs
    // (Google Drive etc.) can't be cheaply checked — assume available and
    // let the player's error auto-skip handle outages.
    if (!path.startsWith('content://') && !File(path).existsSync()) {
      skipped.add(name);
      continue;
    }

    final row = byPath[path];
    if (row != null) {
      tracks.add(rowToTrack(row));
    } else {
      tracks.add(Track(
        id: path,
        title: title,
        artist: 'Unknown Artist',
        album: 'Unknown Album',
        duration: Duration.zero,
        filePath: path,
        source: TrackSource.local,
        format: name.contains('.') ? name.split('.').last.toLowerCase() : '',
      ));
    }
    originalIndices.add(pathIndex);
  }

  return ResolvedPlaylist(tracks, skipped, originalIndices);
}

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

  void addAll(Iterable<String> paths) {
    state = {...state, ...paths};
  }

  void removeAll(Iterable<String> paths) {
    final s = Set<String>.from(state)..removeAll(paths);
    state = s;
  }

  void clear() => state = {};

  bool isSelected(String path) => state.contains(path);
}

/// Selection for the local Library browse surface (keys: local file paths).
final selectionProvider =
    StateNotifierProvider<SelectionNotifier, Set<String>>((ref) {
  return SelectionNotifier();
});

/// Separate selection for the NAS browser (keys: NAS paths / 'dir:<path>').
/// Keeping the two apart prevents a Library selection from leaking into the
/// NAS toolbar and being misinterpreted as NAS paths.
final nasSelectionProvider =
    StateNotifierProvider<SelectionNotifier, Set<String>>((ref) {
  return SelectionNotifier();
});
