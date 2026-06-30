import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/track.dart';
import '../services/audio_handler.dart';

final audioHandlerProvider = Provider<NasPlayerAudioHandler>((ref) {
  throw UnimplementedError('Must be overridden in main()');
});

// ── Playback state streams ─────────────────────────────────────────────────

final playbackStateProvider = StreamProvider<PlaybackState>((ref) {
  return ref.watch(audioHandlerProvider).playbackState;
});

final currentMediaItemProvider = StreamProvider<MediaItem?>((ref) {
  return ref.watch(audioHandlerProvider).mediaItem;
});

final positionProvider = StreamProvider<Duration>((ref) {
  return ref.watch(audioHandlerProvider).positionStream;
});

final durationProvider = StreamProvider<Duration?>((ref) {
  return ref.watch(audioHandlerProvider).durationStream;
});

final queueProvider = StreamProvider<List<MediaItem>>((ref) {
  return ref.watch(audioHandlerProvider).queue;
});

final currentIndexProvider = StreamProvider<int?>((ref) {
  return ref.watch(audioHandlerProvider).currentIndexStream;
});

// ── Derived state ──────────────────────────────────────────────────────────

final isPlayingProvider = Provider<bool>((ref) {
  final state = ref.watch(playbackStateProvider);
  return state.whenData((s) => s.playing).value ?? false;
});

final shuffleModeProvider = Provider<AudioServiceShuffleMode>((ref) {
  final state = ref.watch(playbackStateProvider);
  return state
          .whenData((s) => s.shuffleMode)
          .value ?? AudioServiceShuffleMode.none;
});

final repeatModeProvider = Provider<AudioServiceRepeatMode>((ref) {
  final state = ref.watch(playbackStateProvider);
  return state
          .whenData((s) => s.repeatMode)
          .value ?? AudioServiceRepeatMode.none;
});

// ── Queue controller ───────────────────────────────────────────────────────

class QueueNotifier extends StateNotifier<List<Track>> {
  final NasPlayerAudioHandler _handler;

  QueueNotifier(this._handler) : super([]);

  Future<void> playTracks(List<Track> tracks, {int startIndex = 0}) async {
    state = tracks;
    await _handler.loadTracks(tracks, initialIndex: startIndex);
    await _handler.play();
  }

  Future<void> playSingle(Track track) async {
    state = [track];
    await _handler.loadSingleTrack(track);
    await _handler.play();
  }

  Future<void> addToQueue(Track track) async {
    state = [...state, track];
    await _handler.addQueueItem(track.toMediaItem());
  }

  Future<void> removeFromQueue(int index) async {
    final newState = List<Track>.from(state)..removeAt(index);
    state = newState;
    await _handler.removeQueueItemAt(index);
  }

  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    final list = List<Track>.from(state);
    final track = list.removeAt(oldIndex);
    list.insert(newIndex < oldIndex ? newIndex : newIndex - 1, track);
    state = list;
    await _handler.loadTracks(list, initialIndex: newIndex < oldIndex ? newIndex : newIndex - 1);
  }

  void clear() {
    state = [];
  }
}

final queueNotifierProvider =
    StateNotifierProvider<QueueNotifier, List<Track>>((ref) {
  return QueueNotifier(ref.watch(audioHandlerProvider));
});
