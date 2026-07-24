import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'audio_provider.dart';

class SleepTimerState {
  final Duration? remaining;
  final bool stopAtEndOfTrack;

  const SleepTimerState({this.remaining, this.stopAtEndOfTrack = false});

  bool get isActive => remaining != null || stopAtEndOfTrack;
}

class SleepTimerNotifier extends StateNotifier<SleepTimerState> {
  final Ref _ref;
  Timer? _ticker;
  StreamSubscription<int?>? _trackSub;

  SleepTimerNotifier(this._ref) : super(const SleepTimerState());

  void start(Duration duration) {
    cancel();
    state = SleepTimerState(remaining: duration);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final rem = state.remaining;
      if (rem == null) return;
      final next = rem - const Duration(seconds: 1);
      if (next <= Duration.zero) {
        _ref.read(audioHandlerProvider).pause();
        cancel();
      } else {
        state = SleepTimerState(remaining: next);
      }
    });
  }

  StreamSubscription<Duration>? _positionSub;

  /// Pause when the current track finishes. Detects the transition both by
  /// index change AND by a position wrap-around, which covers repeat-one
  /// (the index never changes when the same track loops).
  void stopAtEndOfTrack() {
    cancel();
    state = const SleepTimerState(stopAtEndOfTrack: true);
    final handler = _ref.read(audioHandlerProvider);
    final startIndex = handler.currentIndex;

    _trackSub = handler.currentIndexStream.listen((index) {
      if (index != null && index != startIndex) {
        handler.pause();
        cancel();
      }
    });

    var lastPosition = handler.position;
    _positionSub = handler.positionStream.listen((position) {
      // A jump backwards of >2s means the track restarted (loop-one).
      if (position < lastPosition - const Duration(seconds: 2)) {
        handler.pause();
        cancel();
        return;
      }
      lastPosition = position;
    });
  }

  void cancel() {
    _ticker?.cancel();
    _ticker = null;
    _trackSub?.cancel();
    _trackSub = null;
    _positionSub?.cancel();
    _positionSub = null;
    if (mounted) state = const SleepTimerState();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _trackSub?.cancel();
    _positionSub?.cancel();
    super.dispose();
  }
}

final sleepTimerProvider =
    StateNotifierProvider<SleepTimerNotifier, SleepTimerState>((ref) {
  return SleepTimerNotifier(ref);
});
