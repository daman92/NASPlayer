import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/audio_provider.dart';
import '../../utils/format_utils.dart';
import '../widgets/album_art.dart';
import '../widgets/playback_controls.dart';

class NowPlayingScreen extends ConsumerWidget {
  const NowPlayingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mediaItem = ref.watch(currentMediaItemProvider).value;
    final queue = ref.watch(queueProvider).value ?? [];
    final currentIndex = ref.watch(currentIndexProvider).value ?? 0;

    if (mediaItem == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Now Playing')),
        body: const Center(child: Text('No track playing')),
      );
    }

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.keyboard_arrow_down),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          'Now Playing',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.queue_music),
            onPressed: () => _showQueue(context, ref),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const SizedBox(height: 16),
              // Album art
              Expanded(
                flex: 5,
                child: Center(
                  child: AlbumArt(
                    artUri: mediaItem.artUri,
                    size: double.infinity,
                    borderRadius: 16,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              // Track info
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    mediaItem.title,
                    style: Theme.of(context).textTheme.headlineMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    mediaItem.artist ?? 'Unknown Artist',
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withOpacity(0.6),
                        ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    mediaItem.album ?? '',
                    style: Theme.of(context).textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  if (queue.isNotEmpty)
                    Text(
                      'Track ${currentIndex + 1} of ${queue.length}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                          ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              // Seek bar
              const _SeekBar(),
              const SizedBox(height: 8),
              // Controls
              const PlaybackControls(large: true),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  void _showQueue(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _QueueSheet(),
    );
  }
}

class _SeekBar extends ConsumerWidget {
  const _SeekBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = ref.watch(positionProvider).value ?? Duration.zero;
    final duration = ref.watch(durationProvider).value ?? Duration.zero;
    final handler = ref.read(audioHandlerProvider);

    final maxMs = duration.inMilliseconds.toDouble();
    final posMs = position.inMilliseconds
        .toDouble()
        .clamp(0, maxMs > 0 ? maxMs : 1);

    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          ),
          child: Slider(
            value: maxMs > 0 ? posMs / maxMs : 0,
            onChanged: maxMs > 0
                ? (v) => handler.seek(
                      Duration(milliseconds: (v * maxMs).round()),
                    )
                : null,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(FormatUtils.formatDuration(position),
                  style: Theme.of(context).textTheme.bodySmall),
              Text(FormatUtils.formatDuration(duration),
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}

class _QueueSheet extends ConsumerWidget {
  const _QueueSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(queueNotifierProvider);
    final currentIndex = ref.watch(currentIndexProvider).value ?? 0;
    final handler = ref.read(audioHandlerProvider);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      builder: (_, scrollController) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Text('Queue (${queue.length} tracks)',
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    ref.read(queueNotifierProvider.notifier).clear();
                    Navigator.pop(context);
                  },
                  child: const Text('Clear'),
                ),
              ],
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              scrollController: scrollController,
              itemCount: queue.length,
              onReorder: (oldIndex, newIndex) {
                ref.read(queueNotifierProvider.notifier).reorderQueue(
                    oldIndex, newIndex);
              },
              itemBuilder: (_, index) {
                final track = queue[index];
                final isCurrent = index == currentIndex;
                return ListTile(
                  key: ValueKey(track.filePath),
                  leading: isCurrent
                      ? Icon(Icons.equalizer,
                          color: Theme.of(context).colorScheme.primary)
                      : Text('${index + 1}',
                          style: Theme.of(context).textTheme.bodySmall),
                  title: Text(
                    track.title,
                    style: isCurrent
                        ? TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.bold)
                        : null,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(FormatUtils.formatDuration(track.duration),
                          style: Theme.of(context).textTheme.bodySmall),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.remove_circle_outline, size: 20),
                        onPressed: () =>
                            ref.read(queueNotifierProvider.notifier).removeFromQueue(index),
                      ),
                    ],
                  ),
                  onTap: () => handler.skipToQueueItem(index),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
