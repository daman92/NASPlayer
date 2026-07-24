import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import '../database/app_database.dart';
import '../models/nas_config.dart';
import '../models/track.dart';
import '../nas/http_nas_adapter.dart';
import '../nas/nas_detector.dart';
import '../utils/filename_parser.dart';
import 'settings_service.dart';

class NasPlayerAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  final AppDatabase _db;
  final SettingsService _settings;

  late final AndroidEqualizer equalizer;
  late final AndroidLoudnessEnhancer loudnessEnhancer;
  late final AudioPlayer _player;

  ConcatenatingAudioSource? _queueSource;
  Timer? _resumeSaveTimer;
  Timer? _queuePersistDebounce;
  int? _lastHistoryIndex;
  int _consecutiveErrorSkips = 0;

  /// Resolves fresh NAS session headers at play time (set after NAS login).
  Map<String, String> Function()? nasHeaderProvider;

  /// Rebuilds a NAS stream URL from a raw NAS path with the CURRENT session
  /// (set after NAS login) — keeps QNAP-style sid-in-URL tokens fresh.
  String Function(String nasPath)? nasUrlResolver;

  /// Playback errors surfaced to the UI (snackbar / reconnect prompt).
  final _errorController = StreamController<String>.broadcast();
  Stream<String> get errorStream => _errorController.stream;

  /// Media ids of the most recently browsed Android Auto leaf list, so
  /// selecting a browsed item can play it in the context of its siblings.
  List<MediaItem> _lastBrowsedLeaves = [];

  NasPlayerAudioHandler({
    required AppDatabase db,
    required SettingsService settings,
  })  : _db = db,
        _settings = settings {
    equalizer = AndroidEqualizer();
    loudnessEnhancer = AndroidLoudnessEnhancer();
    _player = AudioPlayer(
      audioPipeline: AudioPipeline(
        androidAudioEffects: [equalizer, loudnessEnhancer],
      ),
    );

    _player.playbackEventStream.listen(
      _broadcastState,
      onError: _onPlayerError,
    );

    // Reset the error-skip counter once something actually plays.
    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.ready) _consecutiveErrorSkips = 0;
    });

    // Persist the queue (debounced) on every mutation, so resume-on-launch
    // survives adds/removes/reorders and Android Auto-initiated playback.
    queue.listen((_) {
      _queuePersistDebounce?.cancel();
      _queuePersistDebounce =
          Timer(const Duration(seconds: 1), _persistQueueSnapshot);
    });

    // Keep notification / Android Auto metadata current across natural
    // (gapless) track transitions, not just manual skips.
    _player.currentIndexStream.listen((index) {
      if (index == null) return;
      final q = queue.value;
      if (index >= 0 && index < q.length) {
        mediaItem.add(q[index]);
        // Only count as a play when audio is actually running (a restored
        // paused queue shouldn't pollute history).
        if (_player.playing) _recordHistory(index, q[index]);
      }
    });

    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed && !_player.hasNext) {
        // End of queue: stop the periodic resume saving and pause.
        _player.pause();
        _settings.clearResumeState();
      }
    });

    // Untagged / NAS / cloud tracks start with a zero duration, which
    // leaves the car's (and notification's) seek bar dead. Push the real
    // duration into the queue + metadata once the player knows it.
    _player.durationStream.listen((duration) {
      if (duration == null || duration <= Duration.zero) return;
      final index = _player.currentIndex;
      final q = queue.value;
      if (index == null || index < 0 || index >= q.length) return;
      final item = q[index];
      final known = item.duration ?? Duration.zero;
      if ((known - duration).abs() > const Duration(seconds: 1)) {
        final updated = item.copyWith(duration: duration);
        final newQueue = List<MediaItem>.from(q);
        newQueue[index] = updated;
        queue.add(newQueue);
        mediaItem.add(updated);
      }
    });

    _startResumeSaver();
    _restoreVolume();
  }

  Future<void> _restoreVolume() async {
    final volume = await _settings.getVolume();
    await _player.setVolume(volume.clamp(0.0, 1.0));
  }

  // ── Queue loading ──────────────────────────────────────────────────────────

  AudioSource _sourceForTrack(Track track) {
    final item = track.toMediaItem();
    if (track.source == TrackSource.local) {
      // SAF documents (Google Drive etc.) are content:// URIs, which
      // ExoPlayer streams natively; everything else is a filesystem path.
      final uri = track.filePath.startsWith('content://')
          ? Uri.parse(track.filePath)
          : Uri.file(track.filePath);
      return AudioSource.uri(uri, tag: item);
    }
    final headers = track.httpHeaders ?? nasHeaderProvider?.call();
    return AudioSource.uri(
      Uri.parse(track.filePath),
      headers: headers == null || headers.isEmpty ? null : headers,
      tag: item,
    );
  }

  AudioSource _sourceForMediaItem(MediaItem item) {
    final extras = item.extras ?? const {};
    if (extras['source'] == TrackSource.nas.name) {
      // Prefer LIVE session headers/URL over ones frozen into the item, so
      // re-login refreshes already-queued tracks.
      final live = nasHeaderProvider?.call();
      final rawHeaders = extras['headers'];
      final headers = (live != null && live.isNotEmpty)
          ? live
          : rawHeaders is Map
              ? rawHeaders.map((k, v) => MapEntry(k.toString(), v.toString()))
              : null;
      final nasPath = extras['nasPath'] as String?;
      final url = (nasPath != null && nasUrlResolver != null)
          ? nasUrlResolver!(nasPath)
          : item.id;
      return AudioSource.uri(
        Uri.parse(url),
        headers: headers == null || headers.isEmpty ? null : headers,
        tag: item,
      );
    }
    final uri = item.id.startsWith('content://')
        ? Uri.parse(item.id)
        : Uri.file(item.id);
    return AudioSource.uri(uri, tag: item);
  }

  Future<void> loadTracks(
    List<Track> tracks, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
    bool autoPlay = false,
  }) async {
    if (tracks.isEmpty) return;
    final safeIndex = initialIndex.clamp(0, tracks.length - 1);
    final items = tracks.map((t) => t.toMediaItem()).toList();
    queue.add(items);

    _lastHistoryIndex = null;
    _queueSource = ConcatenatingAudioSource(
      children: tracks.map(_sourceForTrack).toList(),
    );

    try {
      await _player.setAudioSource(
        _queueSource!,
        initialIndex: safeIndex,
        initialPosition: initialPosition,
      );
    } on PlayerException catch (e) {
      _errorController.add('Could not load track: ${e.message}');
    }

    mediaItem.add(items[safeIndex]);
    // Not awaited — see play(): its future pends until the next pause.
    if (autoPlay) unawaited(play());
  }

  Future<void> loadSingleTrack(Track track) => loadTracks([track]);

  // ── Playback controls ──────────────────────────────────────────────────────

  String? _activeNasId;
  bool _nasContextAttempted = false;

  /// Make NAS streaming possible even when the app was started headlessly
  /// by Android Auto: rebuild an adapter from the persisted session context
  /// so fresh stream URLs + auth headers can be produced. No-op when the
  /// phone UI already wired a live session.
  Future<void> ensureNasContext() async {
    if (nasUrlResolver != null && _activeNasId != null) return;
    if (_nasContextAttempted && nasUrlResolver == null) {
      // Still try to learn the nasId for index browsing.
    }
    try {
      final context = await _settings.getActiveNasContext();
      if (context == null) return;
      _activeNasId = context.nasId;
      if (nasUrlResolver != null) return; // Live session already wired.
      if (_nasContextAttempted) return;
      _nasContextAttempted = true;

      final cookies = await _settings.getCookiesForNas(context.nasId);
      if (cookies == null || cookies.isEmpty) return;
      final extraHeaders =
          await _settings.getExtraHeadersForNas(context.nasId);

      final vendor = NasVendor.values.firstWhere(
        (v) => v.name == context.vendor,
        orElse: () => NasVendor.synology,
      );
      final adapter = const NasDetector().adapterForVendor(
        vendor,
        context.baseUrl,
        cookies,
        extraHeaders: extraHeaders,
      );
      await adapter.prepare();
      nasUrlResolver = adapter.getStreamUrl;
      nasHeaderProvider = () => adapter.streamHeaders;
    } catch (_) {
      // Headless NAS is best effort — never break playback over it.
    }
  }

  bool _restoreAttempted = false;

  /// Restore the persisted queue + position when playback is requested and
  /// nothing is loaded. Covers Android Auto cold starts, where the service
  /// runs headlessly and the phone UI's restore-on-launch never executes.
  Future<void> ensureQueueRestored() async {
    if (_restoreAttempted || queue.value.isNotEmpty) {
      _restoreAttempted = true;
      return;
    }
    _restoreAttempted = true;

    try {
      if (!await _settings.getResumeEnabled()) return;
      final resume = await _settings.getResumeState();
      if (resume == null) return;

      // Rebuild NAS streaming context first so headless (car) restores can
      // produce fresh, authenticated stream URLs.
      await ensureNasContext();
      final storedHeaders = await _settings.getActiveNasHeaders();
      final liveHeaders = nasHeaderProvider?.call();
      final nasHeaders =
          (liveHeaders != null && liveHeaders.isNotEmpty)
              ? liveHeaders
              : storedHeaders;

      final tracks = <Track>[];
      for (final t in resume.queue) {
        final source =
            t['source'] == 'nas' ? TrackSource.nas : TrackSource.local;
        var filePath = t['filePath'] as String? ?? '';
        final nasPath = t['nasPath'] as String?;
        // Prefer a freshly resolved stream URL over the stored one.
        if (source == TrackSource.nas &&
            nasPath != null &&
            nasUrlResolver != null) {
          filePath = nasUrlResolver!(nasPath);
        }
        if (filePath.isEmpty) continue;
        if (source == TrackSource.local &&
            !filePath.startsWith('content://') &&
            !File(filePath).existsSync()) {
          continue;
        }
        tracks.add(Track(
          id: t['id'] as String? ?? filePath,
          title: t['title'] as String? ?? 'Unknown',
          artist: t['artist'] as String? ?? 'Unknown Artist',
          album: t['album'] as String? ?? 'Unknown Album',
          duration: Duration(milliseconds: (t['durationMs'] as int?) ?? 0),
          filePath: filePath,
          nasPath: t['nasPath'] as String?,
          httpHeaders:
              source == TrackSource.nas && nasHeaders.isNotEmpty
                  ? nasHeaders
                  : null,
          artworkPath: t['artworkPath'] as String?,
          source: source,
          format: t['format'] as String? ?? '',
        ));
      }
      if (tracks.isEmpty) return;

      await loadTracks(
        tracks,
        initialIndex: resume.index.clamp(0, tracks.length - 1),
        initialPosition: Duration(milliseconds: resume.positionMs),
      );
    } catch (_) {
      // Never let restore break a play request.
    }
  }

  @override
  Future<void> prepare() => ensureQueueRestored();

  @override
  Future<void> play() async {
    // A play command with nothing loaded (car/media-button cold start)
    // resumes the last session.
    await ensureQueueRestored();

    // Record BEFORE starting playback: _player.play()'s future only
    // completes when playback is later paused/finished.
    final index = _player.currentIndex;
    final q = queue.value;
    if (index != null && index >= 0 && index < q.length) {
      _recordHistory(index, q[index]);
    }
    await _player.play();
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() async {
    // An explicit "next" must advance even under repeat-one, where
    // just_audio's seekToNext would restart the same track.
    final loopOne = _player.loopMode == LoopMode.one;
    if (loopOne) await _player.setLoopMode(LoopMode.all);
    if (_player.hasNext) {
      await _player.seekToNext();
    }
    if (loopOne) await _player.setLoopMode(LoopMode.one);
  }

  @override
  Future<void> skipToPrevious() async {
    if (_player.position > const Duration(seconds: 3)) {
      await _player.seek(Duration.zero);
      return;
    }
    final loopOne = _player.loopMode == LoopMode.one;
    if (loopOne) await _player.setLoopMode(LoopMode.all);
    if (_player.hasPrevious) {
      await _player.seekToPrevious();
    } else {
      await _player.seek(Duration.zero);
    }
    if (loopOne) await _player.setLoopMode(LoopMode.one);
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= queue.value.length) return;
    await _player.seek(Duration.zero, index: index);
    unawaited(_player.play());
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    final enabled = shuffleMode == AudioServiceShuffleMode.all;
    if (enabled) {
      // Design 4.5: shuffle re-randomizes the queue on activation.
      await _player.shuffle();
    }
    await _player.setShuffleModeEnabled(enabled);
    playbackState.add(playbackState.value.copyWith(shuffleMode: shuffleMode));
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    switch (repeatMode) {
      case AudioServiceRepeatMode.none:
        await _player.setLoopMode(LoopMode.off);
      case AudioServiceRepeatMode.one:
        await _player.setLoopMode(LoopMode.one);
      case AudioServiceRepeatMode.all:
      case AudioServiceRepeatMode.group:
        await _player.setLoopMode(LoopMode.all);
    }
    playbackState.add(playbackState.value.copyWith(repeatMode: repeatMode));
  }

  // ── Volume (design 4.1) ────────────────────────────────────────────────────

  double get volume => _player.volume;
  Stream<double> get volumeStream => _player.volumeStream;

  Future<void> setVolume(double volume) async {
    final v = volume.clamp(0.0, 1.0);
    await _player.setVolume(v);
    await _settings.setVolume(v);
  }

  // ── Queue mutation (design 4.5: reorder/remove active queue) ──────────────

  @override
  Future<void> addQueueItem(MediaItem mediaItem) async {
    final source = _queueSource;
    if (source == null) {
      // Bootstrap a queue from scratch (nothing loaded yet).
      _queueSource =
          ConcatenatingAudioSource(children: [_sourceForMediaItem(mediaItem)]);
      queue.add([mediaItem]);
      this.mediaItem.add(mediaItem);
      try {
        await _player.setAudioSource(_queueSource!);
      } on PlayerException catch (e) {
        _errorController.add('Could not load track: ${e.message}');
      }
      return;
    }
    await source.add(_sourceForMediaItem(mediaItem));
    queue.add([...queue.value, mediaItem]);
  }

  /// Stop playback and drop the whole queue (also clears resume state).
  Future<void> clearQueue() async {
    await _player.stop();
    _queueSource = null;
    queue.add([]);
    mediaItem.add(null);
    _lastHistoryIndex = null;
    await _settings.clearResumeState();
  }

  @override
  Future<void> removeQueueItemAt(int index) async {
    final source = _queueSource;
    final q = List<MediaItem>.from(queue.value);
    if (source == null || index < 0 || index >= q.length) return;
    // Removing the currently playing item: just_audio advances automatically.
    await source.removeAt(index);
    q.removeAt(index);
    queue.add(q);
  }

  /// Rebuild queued NAS sources with the current session (called after a
  /// re-login) so remaining tracks stream with fresh cookies instead of the
  /// ones frozen in at load time. Preserves position and play state.
  Future<void> refreshNasSources() async {
    final q = queue.value;
    if (_queueSource == null || q.isEmpty) return;
    if (!q.any((i) => (i.extras?['source']) == TrackSource.nas.name)) return;

    final index = _player.currentIndex ?? 0;
    final position = _player.position;
    final wasPlaying = _player.playing;

    // Drop stale frozen headers so _sourceForMediaItem uses the live session.
    final refreshed = q.map((item) {
      final extras = Map<String, dynamic>.from(item.extras ?? {});
      extras.remove('headers');
      return item.copyWith(extras: extras);
    }).toList();

    queue.add(refreshed);
    _queueSource = ConcatenatingAudioSource(
      children: refreshed.map(_sourceForMediaItem).toList(),
    );
    try {
      await _player.setAudioSource(
        _queueSource!,
        initialIndex: index.clamp(0, refreshed.length - 1),
        initialPosition: position,
      );
      if (wasPlaying) unawaited(_player.play());
    } on PlayerException catch (e) {
      _errorController.add('Could not resume after re-login: ${e.message}');
    }
  }

  /// Move a queue item without interrupting playback.
  Future<void> moveQueueItem(int oldIndex, int newIndex) async {
    final source = _queueSource;
    final q = List<MediaItem>.from(queue.value);
    if (source == null ||
        oldIndex < 0 ||
        oldIndex >= q.length ||
        newIndex < 0 ||
        newIndex >= q.length ||
        oldIndex == newIndex) {
      return;
    }
    await source.move(oldIndex, newIndex);
    final item = q.removeAt(oldIndex);
    q.insert(newIndex, item);
    queue.add(q);
  }

  // ── Voice control (design 4.2: "play [artist]") ───────────────────────────

  @override
  Future<void> playFromSearch(String query,
      [Map<String, dynamic>? extras]) async {
    final rows = await _db.searchTracks(query);
    if (rows.isEmpty) return;
    final tracks = rows.map(_rowToTrack).toList();
    await loadTracks(tracks, autoPlay: true);
  }

  @override
  Future<void> prepareFromSearch(String query,
      [Map<String, dynamic>? extras]) async {
    final rows = await _db.searchTracks(query);
    if (rows.isEmpty) return;
    await loadTracks(rows.map(_rowToTrack).toList());
  }

  // ── Android Auto browse tree (design 8.3: Artist > Album > Track) ─────────

  static const _rootRecent = 'recent';
  static const _rootPlaylists = 'playlists';
  static const _rootLibrary = 'library';
  static const _nodeArtists = 'artists';
  static const _nodeAlbums = 'albums';
  static const _nodeFolders = 'folders';
  static const _nodeNas = 'nasroot';

  /// Android Auto's search UI (and long-press voice search results list).
  @override
  Future<List<MediaItem>> search(String query,
      [Map<String, dynamic>? extras]) async {
    final rows = await _db.searchTracks(query);
    final items = rows.map(_rowToMediaItem).toList();
    _lastBrowsedLeaves = items;
    return items;
  }

  @override
  Future<List<MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) async {
    switch (parentMediaId) {
      case AudioService.browsableRootId:
        // The car may browse before anything played this session — restore
        // the last queue so 'Current Queue' (and resume) work immediately.
        unawaited(ensureQueueRestored());
        return const [
          MediaItem(id: _rootLibrary, title: 'Library', playable: false),
          MediaItem(id: _rootPlaylists, title: 'Playlists', playable: false),
          MediaItem(id: _rootRecent, title: 'Recently Played', playable: false),
          MediaItem(id: 'queue', title: 'Current Queue', playable: false),
        ];

      case 'queue':
        _lastBrowsedLeaves = queue.value;
        return queue.value;

      case _rootRecent:
        await ensureNasContext();
        final rows = await _db.getRecentPlays(limit: 50);
        final seen = <String>{};
        final items = <MediaItem>[];
        for (final row in rows) {
          var path = row['file_path'] as String;
          final nasPath = row['nas_path'] as String?;
          final isNas = (row['source'] as String?) == 'nas';
          // Recorded NAS stream URLs go stale — re-resolve when possible.
          if (isNas && nasPath != null && nasUrlResolver != null) {
            path = nasUrlResolver!(nasPath);
          }
          if (!seen.add(nasPath ?? path)) continue;
          items.add(MediaItem(
            id: path,
            title: row['title'] as String? ?? path,
            artist: row['artist'] as String?,
            album: row['album'] as String?,
            playable: true,
            extras: {
              'source': row['source'] ?? 'local',
              'trackId': row['track_id'],
              if (nasPath != null) 'nasPath': nasPath,
            },
          ));
        }
        _lastBrowsedLeaves = items;
        return items;

      case _rootPlaylists:
        final playlists = await _db.getAllPlaylists();
        return playlists
            .map((row) => MediaItem(
                  id: 'playlist:${row['id']}',
                  title: row['name'] as String? ?? 'Playlist',
                  playable: false,
                ))
            .toList();

      case _rootLibrary:
        await ensureNasContext();
        return [
          const MediaItem(id: _nodeArtists, title: 'Artists', playable: false),
          const MediaItem(id: _nodeAlbums, title: 'Albums', playable: false),
          const MediaItem(id: _nodeFolders, title: 'Folders', playable: false),
          if (_activeNasId != null)
            const MediaItem(id: _nodeNas, title: 'NAS', playable: false),
        ];

      case _nodeNas:
        return _nasIndexChildren('/');

      case _nodeFolders:
        final folders = await _db.getDistinctFolders();
        return folders
            .map((f) => MediaItem(
                  id: 'folder:$f',
                  title: _folderLabel(f),
                  playable: false,
                ))
            .toList();

      case _nodeArtists:
        final artists = await _db.getDistinctArtists();
        return artists
            .map((a) => MediaItem(
                id: 'artist:$a', title: a, playable: false))
            .toList();

      case _nodeAlbums:
        final albums = await _db.getDistinctAlbums();
        return albums
            .map((a) => MediaItem(id: 'album:$a', title: a, playable: false))
            .toList();

      default:
        if (parentMediaId.startsWith('naspath:')) {
          return _nasIndexChildren(parentMediaId.substring(8));
        }
        if (parentMediaId.startsWith('folder:')) {
          final folder = parentMediaId.substring(7);
          final rows = await _db.getTracksForFolder(folder);
          final items = rows.map(_rowToMediaItem).toList();
          _lastBrowsedLeaves = items;
          return items;
        }
        if (parentMediaId.startsWith('artist:')) {
          final artist = parentMediaId.substring(7);
          final rows = await _db.getTracksForArtist(artist);
          final items = rows.map(_rowToMediaItem).toList();
          _lastBrowsedLeaves = items;
          return items;
        }
        if (parentMediaId.startsWith('album:')) {
          final album = parentMediaId.substring(6);
          final rows = await _db.getTracksForAlbum(album);
          final items = rows.map(_rowToMediaItem).toList();
          _lastBrowsedLeaves = items;
          return items;
        }
        if (parentMediaId.startsWith('playlist:')) {
          final playlistId = parentMediaId.substring(9);
          final trackRows = await _db.getPlaylistTracks(playlistId);
          final paths = trackRows
              .map((r) => r['track_path'] as String)
              .map((p) => p.startsWith('nas://') ? p.substring(6) : p)
              .toList();
          final known = await _db.getTracksByPaths(paths);
          final byPath = {
            for (final row in known) row['file_path'] as String: row,
            for (final row in known)
              if (row['nas_path'] != null) row['nas_path'] as String: row,
          };
          final items = <MediaItem>[];
          for (final p in paths) {
            final row = byPath[p];
            if (row != null) {
              items.add(_rowToMediaItem(row));
            }
          }
          _lastBrowsedLeaves = items;
          return items;
        }
        return [];
    }
  }

  @override
  Future<void> playFromMediaId(String mediaId,
      [Map<String, dynamic>? extras]) async {
    await ensureNasContext();
    // Playing a whole playlist node.
    if (mediaId.startsWith('playlist:')) {
      final items = await getChildren(mediaId);
      if (items.isEmpty) return;
      await _playMediaItems(items, 0);
      return;
    }

    // A leaf track: play it within its browsed sibling list when possible.
    final browseIndex =
        _lastBrowsedLeaves.indexWhere((item) => item.id == mediaId);
    if (browseIndex >= 0) {
      await _playMediaItems(_lastBrowsedLeaves, browseIndex);
      return;
    }

    // Fallback: single track from the library DB.
    final rows = await _db.getTracksByPaths([mediaId]);
    if (rows.isEmpty) return;
    await loadTracks([_rowToTrack(rows.first)], autoPlay: true);
  }

  Future<void> _playMediaItems(List<MediaItem> items, int startIndex) async {
    final paths = items.map((i) => i.id).toList();
    final rows = await _db.getTracksByPaths(paths);
    final byPath = {for (final row in rows) row['file_path'] as String: row};

    // Build a track for EVERY item (falling back to the MediaItem itself for
    // NAS tracks and unindexed files) so the tapped index stays aligned.
    final tracks = <Track>[];
    for (final item in items) {
      final row = byPath[item.id];
      if (row != null) {
        tracks.add(_rowToTrack(row));
      } else {
        tracks.add(_mediaItemToTrack(item));
      }
    }
    if (tracks.isEmpty) return;
    final safeStart = startIndex.clamp(0, tracks.length - 1);
    await loadTracks(tracks, initialIndex: safeStart, autoPlay: true);
  }

  /// Children of a NAS folder from the locally cached index (browsed or
  /// fully indexed on the phone). Folders first, then playable audio files
  /// with freshly resolved stream URLs.
  Future<List<MediaItem>> _nasIndexChildren(String parentPath) async {
    await ensureNasContext();
    final nasId = _activeNasId;
    if (nasId == null) return [];

    final rows = await _db.getNasIndexForParent(nasId, parentPath);
    final items = <MediaItem>[];
    final leaves = <MediaItem>[];

    for (final row in rows) {
      final name = row['name'] as String? ?? '';
      final path = row['path'] as String? ?? '';
      if (name.isEmpty || path.isEmpty) continue;

      if ((row['is_directory'] as int?) == 1) {
        items.add(MediaItem(
          id: 'naspath:$path',
          title: name,
          playable: false,
        ));
        continue;
      }

      final dot = name.lastIndexOf('.');
      final ext = dot > 0 ? name.substring(dot + 1).toLowerCase() : '';
      if (!nasAudioExtensions.contains(ext)) continue;

      final parsed =
          parseTrackFilename(dot > 0 ? name.substring(0, dot) : name);
      final parent = parentPath == '/'
          ? 'NAS'
          : parentPath.split('/').where((s) => s.isNotEmpty).last;
      final streamUrl = nasUrlResolver?.call(path) ?? path;

      leaves.add(MediaItem(
        id: streamUrl,
        title: parsed.title,
        artist: parsed.artist ?? 'Unknown Artist',
        album: parent,
        playable: true,
        extras: {
          'source': TrackSource.nas.name,
          'nasPath': path,
          'format': ext,
        },
      ));
    }

    if (leaves.isNotEmpty) _lastBrowsedLeaves = leaves;
    return [...items, ...leaves];
  }

  /// Readable label for a folder path in the car UI.
  String _folderLabel(String folderPath) {
    if (folderPath.startsWith('content://')) return 'Cloud folder';
    var p = folderPath;
    while (p.endsWith('/') || p.endsWith(r'\')) {
      p = p.substring(0, p.length - 1);
    }
    final segments = p.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty);
    return segments.isEmpty ? folderPath : segments.last;
  }

  Track _mediaItemToTrack(MediaItem item) {
    final extras = item.extras ?? const {};
    final isNas = extras['source'] == TrackSource.nas.name;
    final nasPath = extras['nasPath'] as String?;
    // NAS: always resolve a fresh authenticated stream URL — a stored one
    // may carry an expired session token, which stalls queue advancement.
    final filePath = isNas && nasPath != null && nasUrlResolver != null
        ? nasUrlResolver!(nasPath)
        : item.id;
    return Track(
      id: extras['trackId']?.toString() ?? item.id,
      title: item.title,
      artist: item.artist ?? 'Unknown Artist',
      album: item.album ?? 'Unknown Album',
      duration: item.duration ?? Duration.zero,
      filePath: filePath,
      nasPath: nasPath,
      httpHeaders: isNas ? nasHeaderProvider?.call() : null,
      source: isNas ? TrackSource.nas : TrackSource.local,
      format: extras['format']?.toString() ?? '',
    );
  }

  // ── Play history ───────────────────────────────────────────────────────────

  void _recordHistory(int index, MediaItem item) {
    if (_lastHistoryIndex == index) return;
    _lastHistoryIndex = index;
    final extras = item.extras ?? const {};
    _db.insertPlayEvent({
      'track_id': extras['trackId']?.toString() ?? item.id,
      'title': item.title,
      'artist': item.artist ?? '',
      'album': item.album ?? '',
      'file_path': item.id,
      'nas_path': extras['nasPath']?.toString(),
      'source': extras['source']?.toString() ?? 'local',
      'played_at': DateTime.now().millisecondsSinceEpoch,
    }).catchError((_) {});
  }

  // ── Resume state (design 4.1: resume from last position) ──────────────────

  void _startResumeSaver() {
    _resumeSaveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_player.playing) return;
      final index = _player.currentIndex;
      if (index == null) return;
      _settings.saveResumePosition(index, _player.position.inMilliseconds);
    });
  }

  /// Serialize the CURRENT queue for resume-on-launch. Runs debounced on
  /// every queue mutation so the persisted queue can never drift from the
  /// live one (adds/removes/reorders/voice-initiated playback included).
  Future<void> _persistQueueSnapshot() async {
    final q = queue.value;
    if (q.isEmpty) return;
    final serialized = q.map((item) {
      final extras = item.extras ?? const {};
      final artUri = item.artUri;
      return <String, dynamic>{
        'id': extras['trackId']?.toString() ?? item.id,
        'title': item.title,
        'artist': item.artist ?? 'Unknown Artist',
        'album': item.album ?? 'Unknown Album',
        'durationMs': item.duration?.inMilliseconds ?? 0,
        'filePath': item.id,
        if (extras['nasPath'] != null) 'nasPath': extras['nasPath'],
        'source': extras['source']?.toString() ?? 'local',
        'format': extras['format']?.toString() ?? '',
        if (artUri != null && artUri.scheme == 'file')
          'artworkPath': artUri.toFilePath(),
      };
    }).toList();
    final index = _player.currentIndex ?? 0;
    await _settings.saveResumeQueue(
        serialized, index, _player.position.inMilliseconds);
  }

  // ── Error resilience (design section 7) ────────────────────────────────────

  void _onPlayerError(Object error, [StackTrace? stack]) {
    final message = error is PlayerException
        ? (error.message ?? 'Playback error')
        : 'Playback error: stream interrupted';
    _errorController.add(message);

    // Skip unplayable/missing tracks instead of halting the session — but
    // never loop: repeat-one would re-seek the SAME failing item, and
    // repeat-all wraps forever when every track fails (dead NAS session).
    _consecutiveErrorSkips++;
    final queueLength = queue.value.length;
    if (_player.loopMode == LoopMode.one ||
        _consecutiveErrorSkips >= queueLength ||
        _consecutiveErrorSkips >= 20) {
      _player.pause();
      return;
    }
    if (_player.hasNext) {
      _player.seekToNext();
      _player.play();
    } else {
      _player.pause();
    }
  }

  // ── State broadcast ────────────────────────────────────────────────────────

  void _broadcastState(PlaybackEvent event) {
    final playing = _player.playing;
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.stop,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
        MediaAction.setShuffleMode,
        MediaAction.setRepeatMode,
        MediaAction.playFromSearch,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_player.processingState]!,
      playing: playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: event.currentIndex,
    ));
  }

  // ── Row converters ─────────────────────────────────────────────────────────

  Track _rowToTrack(Map<String, Object?> row) => Track(
        id: row['id'] as String? ?? row['file_path'] as String,
        title: row['title'] as String? ?? 'Unknown',
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
        httpHeaders: (row['source'] as String?) == 'nas'
            ? nasHeaderProvider?.call()
            : null,
      );

  MediaItem _rowToMediaItem(Map<String, Object?> row) =>
      _rowToTrack(row).toMediaItem();

  // ── Player streams ─────────────────────────────────────────────────────────

  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  Stream<bool> get playingStream => _player.playingStream;
  Stream<int?> get currentIndexStream => _player.currentIndexStream;
  bool get playing => _player.playing;
  Duration get position => _player.position;
  Duration? get duration => _player.duration;
  int? get currentIndex => _player.currentIndex;

  Future<void> dispose() async {
    _resumeSaveTimer?.cancel();
    _queuePersistDebounce?.cancel();
    await _errorController.close();
    await _player.dispose();
  }
}
