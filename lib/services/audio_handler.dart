import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import '../models/track.dart';

class NasPlayerAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  final AudioPlayer _player = AudioPlayer();

  NasPlayerAudioHandler() {
    _player.playbackEventStream.listen(_broadcastState);
    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        skipToNext();
      }
    });
  }

  // ── Queue loading ──────────────────────────────────────────────────────────

  Future<void> loadTracks(List<Track> tracks, {int initialIndex = 0}) async {
    final items = tracks.map((t) => t.toMediaItem()).toList();
    queue.add(items);

    final sources = tracks.map<AudioSource>((t) {
      if (t.source == TrackSource.local) {
        return AudioSource.uri(Uri.file(t.filePath), tag: t.toMediaItem());
      } else {
        return AudioSource.uri(Uri.parse(t.filePath), tag: t.toMediaItem());
      }
    }).toList();

    await _player.setAudioSource(
      ConcatenatingAudioSource(children: sources),
      initialIndex: initialIndex,
      initialPosition: Duration.zero,
    );

    if (items.isNotEmpty) {
      mediaItem.add(items[initialIndex]);
    }
  }

  Future<void> loadSingleTrack(Track track) async {
    final item = track.toMediaItem();
    queue.add([item]);
    mediaItem.add(item);

    final source = track.source == TrackSource.local
        ? AudioSource.uri(Uri.file(track.filePath), tag: item)
        : AudioSource.uri(Uri.parse(track.filePath), tag: item);

    await _player.setAudioSource(source);
  }

  // ── Playback controls ──────────────────────────────────────────────────────

  @override
  Future<void> play() => _player.play();

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
    if (_player.hasNext) {
      await _player.seekToNext();
      final idx = _player.currentIndex ?? 0;
      final q = queue.value;
      if (idx < q.length) mediaItem.add(q[idx]);
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (_player.position > const Duration(seconds: 3)) {
      await _player.seek(Duration.zero);
    } else if (_player.hasPrevious) {
      await _player.seekToPrevious();
      final idx = _player.currentIndex ?? 0;
      final q = queue.value;
      if (idx < q.length) mediaItem.add(q[idx]);
    }
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    await _player.seek(Duration.zero, index: index);
    final q = queue.value;
    if (index < q.length) mediaItem.add(q[index]);
    await _player.play();
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    await _player
        .setShuffleModeEnabled(shuffleMode == AudioServiceShuffleMode.all);
    super.setShuffleMode(shuffleMode);
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
    super.setRepeatMode(repeatMode);
  }

  // ── Android Auto: media browser ────────────────────────────────────────────

  @override
  Future<List<MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) async {
    switch (parentMediaId) {
      case AudioService.browsableRootId:
        return [
          const MediaItem(
            id: 'recent',
            title: 'Recently Played',
            playable: false,
            extras: {'isLeaf': false},
          ),
          const MediaItem(
            id: 'playlists',
            title: 'Playlists',
            playable: false,
            extras: {'isLeaf': false},
          ),
          const MediaItem(
            id: 'queue',
            title: 'Current Queue',
            playable: false,
            extras: {'isLeaf': false},
          ),
        ];
      case 'queue':
        return queue.value;
      default:
        return [];
    }
  }

  // ── Stream broadcasts ──────────────────────────────────────────────────────

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

  // ── Expose player streams ──────────────────────────────────────────────────

  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  Stream<bool> get playingStream => _player.playingStream;
  Stream<int?> get currentIndexStream => _player.currentIndexStream;
  bool get playing => _player.playing;
  Duration get position => _player.position;
  Duration? get duration => _player.duration;
  int? get currentIndex => _player.currentIndex;

  @override
  Future<void> customAction(String name, [Map<String, dynamic>? extras]) async {
    switch (name) {
      case 'setHttpHeaders':
        final headers = Map<String, String>.from(extras?['headers'] ?? {});
        await _player.setAudioSource(
          _player.audioSource!,
          initialIndex: _player.currentIndex,
          initialPosition: _player.position,
        );
    }
  }

  Future<void> dispose() => _player.dispose();
}
