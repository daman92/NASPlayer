import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/track.dart';
import '../services/audio_handler.dart';
import 'history_provider.dart';

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
  final handler = ref.watch(audioHandlerProvider);
  // Bump history so 'Recently Played' views stay fresh as tracks change.
  return handler.currentIndexStream.map((index) {
    Future.microtask(() {
      try {
        ref.read(historyRefreshProvider.notifier).state++;
      } catch (_) {}
    });
    return index;
  });
});

final volumeProvider = StreamProvider<double>((ref) {
  return ref.watch(audioHandlerProvider).volumeStream;
});

/// Playback errors (stream interruptions, missing files) for UI snackbars.
final playbackErrorProvider = StreamProvider<String>((ref) {
  return ref.watch(audioHandlerProvider).errorStream;
});

// ── Derived state ──────────────────────────────────────────────────────────

final isPlayingProvider = Provider<bool>((ref) {
  final state = ref.watch(playbackStateProvider);
  return state.whenData((s) => s.playing).value ?? false;
});

final shuffleModeProvider = Provider<AudioServiceShuffleMode>((ref) {
  final state = ref.watch(playbackStateProvider);
  return state.whenData((s) => s.shuffleMode).value ??
      AudioServiceShuffleMode.none;
});

final repeatModeProvider = Provider<AudioServiceRepeatMode>((ref) {
  final state = ref.watch(playbackStateProvider);
  return state.whenData((s) => s.repeatMode).value ??
      AudioServiceRepeatMode.none;
});

// ── Queue controller ───────────────────────────────────────────────────────

class QueueNotifier extends StateNotifier<List<Track>> {
  final NasPlayerAudioHandler _handler;

  QueueNotifier(this._handler) : super([]);

  Future<void> playTracks(List<Track> tracks, {int startIndex = 0}) async {
    if (tracks.isEmpty) return;
    state = tracks;
    await _handler.loadTracks(tracks, initialIndex: startIndex);
    // Deliberately NOT awaited: just_audio's play() future only completes
    // when playback pauses/finishes, so awaiting it would defer everything
    // after playTracks (e.g. the Now Playing navigation) until pause —
    // replaying the screen's entrance animation at that moment.
    unawaited(_handler.play());
  }

  /// Load a queue without autoplay (used for resume-on-launch).
  Future<void> restoreTracks(
    List<Track> tracks, {
    int startIndex = 0,
    Duration position = Duration.zero,
  }) async {
    if (tracks.isEmpty) return;
    state = tracks;
    await _handler.loadTracks(
      tracks,
      initialIndex: startIndex,
      initialPosition: position,
    );
  }

  Future<void> playSingle(Track track) => playTracks([track]);

  Future<void> addToQueue(Track track) async {
    state = [...state, track];
    await _handler.addQueueItem(track.toMediaItem());
  }

  Future<void> removeFromQueue(int index) async {
    // The handler queue is authoritative (playback may have started via
    // Android Auto / voice, bypassing this notifier).
    if (index >= 0 && index < state.length) {
      state = List<Track>.from(state)..removeAt(index);
    }
    await _handler.removeQueueItemAt(index);
  }

  /// Reorder without interrupting playback. Accepts raw
  /// ReorderableListView onReorder indices (newIndex includes the removed
  /// slot when dragging down).
  Future<void> reorderQueue(int oldIndex, int newIndex) {
    var target = newIndex;
    if (target > oldIndex) target -= 1;
    return moveTrack(oldIndex, target);
  }

  /// Move with already-adjusted indices (onReorderItem semantics).
  Future<void> moveTrack(int oldIndex, int targetIndex) async {
    if (oldIndex == targetIndex) return;
    if (oldIndex >= 0 &&
        oldIndex < state.length &&
        targetIndex >= 0 &&
        targetIndex < state.length) {
      final list = List<Track>.from(state);
      final track = list.removeAt(oldIndex);
      list.insert(targetIndex, track);
      state = list;
    }
    // The handler validates against its own (authoritative) queue.
    await _handler.moveQueueItem(oldIndex, targetIndex);
  }

  Future<void> clear() async {
    state = [];
    await _handler.clearQueue();
  }
}

final queueNotifierProvider =
    StateNotifierProvider<QueueNotifier, List<Track>>((ref) {
  return QueueNotifier(ref.watch(audioHandlerProvider));
});
