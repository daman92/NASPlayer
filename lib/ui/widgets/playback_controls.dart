import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/audio_provider.dart';

class PlaybackControls extends ConsumerWidget {
  final bool large;

  const PlaybackControls({super.key, this.large = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playbackState = ref.watch(playbackStateProvider).value;
    final isPlaying = playbackState?.playing ?? false;
    final shuffleMode = ref.watch(shuffleModeProvider);
    final repeatMode = ref.watch(repeatModeProvider);
    final handler = ref.read(audioHandlerProvider);

    final iconSize = large ? 32.0 : 24.0;
    final playSize = large ? 56.0 : 40.0;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        // Shuffle
        IconButton(
          iconSize: iconSize,
          icon: Icon(
            Icons.shuffle,
            color: shuffleMode == AudioServiceShuffleMode.all
                ? Theme.of(context).colorScheme.primary
                : null,
          ),
          onPressed: () => handler.setShuffleMode(
            shuffleMode == AudioServiceShuffleMode.none
                ? AudioServiceShuffleMode.all
                : AudioServiceShuffleMode.none,
          ),
        ),
        // Previous
        IconButton(
          iconSize: iconSize,
          icon: const Icon(Icons.skip_previous),
          onPressed: () => handler.skipToPrevious(),
        ),
        // Play/Pause
        Material(
          shape: const CircleBorder(),
          color: Theme.of(context).colorScheme.primary,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: isPlaying ? handler.pause : handler.play,
            child: SizedBox(
              width: playSize,
              height: playSize,
              child: Icon(
                isPlaying ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
                size: iconSize + 4,
              ),
            ),
          ),
        ),
        // Next
        IconButton(
          iconSize: iconSize,
          icon: const Icon(Icons.skip_next),
          onPressed: () => handler.skipToNext(),
        ),
        // Repeat
        IconButton(
          iconSize: iconSize,
          icon: Icon(
            repeatMode == AudioServiceRepeatMode.one
                ? Icons.repeat_one
                : Icons.repeat,
            color: repeatMode != AudioServiceRepeatMode.none
                ? Theme.of(context).colorScheme.primary
                : null,
          ),
          onPressed: () => handler.setRepeatMode(
            switch (repeatMode) {
              AudioServiceRepeatMode.none => AudioServiceRepeatMode.all,
              AudioServiceRepeatMode.all => AudioServiceRepeatMode.one,
              _ => AudioServiceRepeatMode.none,
            },
          ),
        ),
      ],
    );
  }
}
