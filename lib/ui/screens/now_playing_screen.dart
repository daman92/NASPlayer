import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/track.dart';
import '../../providers/audio_provider.dart';
import '../../providers/sleep_timer_provider.dart';
import '../../utils/format_utils.dart';
import '../widgets/add_to_playlist_sheet.dart';
import '../widgets/album_art.dart';
import '../widgets/playback_controls.dart';
import 'equalizer_screen.dart';

class NowPlayingScreen extends ConsumerWidget {
  const NowPlayingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mediaItem = ref.watch(currentMediaItemProvider).value;
    final queue = ref.watch(queueProvider).value ?? [];
    final currentIndex = ref.watch(currentIndexProvider).value ?? 0;
    final sleepTimer = ref.watch(sleepTimerProvider);
    final isPlaying = ref.watch(isPlayingProvider);

    if (mediaItem == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Now Playing')),
        body: const Center(child: Text('No track playing')),
      );
    }

    final extras = mediaItem.extras ?? const {};
    final formatLabel = _formatLabel(extras);

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
            icon: const Icon(Icons.playlist_add),
            tooltip: 'Add to playlist',
            onPressed: () => AddToPlaylistSheet.show(
              context,
              [_mediaItemToTrack(mediaItem)],
            ),
          ),
          IconButton(
            icon: Icon(
              sleepTimer.isActive ? Icons.bedtime : Icons.bedtime_outlined,
              color: sleepTimer.isActive
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            tooltip: 'Sleep timer',
            onPressed: () => _showSleepTimerSheet(context, ref),
          ),
          IconButton(
            icon: const Icon(Icons.equalizer),
            tooltip: 'Equalizer',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const EqualizerScreen()),
            ),
          ),
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
              const SizedBox(height: 8),
              // Album art (animated sound bars when untagged & playing)
              Expanded(
                flex: 5,
                child: Center(
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: AlbumArt(
                      artUri: mediaItem.artUri,
                      size: double.infinity,
                      borderRadius: 16,
                      animate: isPlaying,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
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
                              .withValues(alpha: 0.6),
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
                  Row(
                    children: [
                      if (queue.isNotEmpty)
                        Text(
                          'Track ${currentIndex + 1} of ${queue.length}',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color:
                                        Theme.of(context).colorScheme.primary,
                                  ),
                        ),
                      const Spacer(),
                      if (formatLabel.isNotEmpty)
                        Text(
                          formatLabel,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .secondary,
                                  ),
                        ),
                      if (sleepTimer.remaining != null) ...[
                        const SizedBox(width: 8),
                        Icon(Icons.bedtime,
                            size: 14,
                            color: Theme.of(context).colorScheme.primary),
                        Text(
                          ' ${FormatUtils.formatDuration(sleepTimer.remaining!)}',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color:
                                        Theme.of(context).colorScheme.primary,
                                  ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const _SeekBar(),
              const SizedBox(height: 4),
              const PlaybackControls(large: true),
              const SizedBox(height: 8),
              const _VolumeBar(),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  /// Rebuild a Track from the playing MediaItem so it can be added to a
  /// playlist (NAS tracks keep their raw path for durable storage).
  Track _mediaItemToTrack(MediaItem item) {
    final extras = item.extras ?? const {};
    final isNas = extras['source'] == TrackSource.nas.name;
    final artUri = item.artUri;
    return Track(
      id: extras['trackId']?.toString() ?? item.id,
      title: item.title,
      artist: item.artist ?? 'Unknown Artist',
      album: item.album ?? 'Unknown Album',
      duration: item.duration ?? Duration.zero,
      filePath: item.id,
      nasPath: extras['nasPath'] as String?,
      source: isNas ? TrackSource.nas : TrackSource.local,
      format: extras['format']?.toString() ?? '',
      artworkPath:
          artUri != null && artUri.scheme == 'file' ? artUri.toFilePath() : null,
    );
  }

  String _formatLabel(Map<String, dynamic> extras) {
    final parts = <String>[];
    final format = extras['format'];
    if (format is String && format.isNotEmpty) {
      parts.add(format.toUpperCase());
    }
    final bitDepth = extras['bitDepth'];
    if (bitDepth is int) parts.add('$bitDepth-bit');
    final sampleRate = extras['sampleRate'];
    if (sampleRate is int) {
      final khz = sampleRate / 1000;
      parts.add('${khz % 1 == 0 ? khz.toInt() : khz.toStringAsFixed(1)}kHz');
    }
    return parts.join(' / ');
  }

  void _showSleepTimerSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      builder: (_) => const _SleepTimerSheet(),
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

class _SleepTimerSheet extends ConsumerWidget {
  const _SleepTimerSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sleepTimerProvider);
    final notifier = ref.read(sleepTimerProvider.notifier);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Sleep Timer', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (state.remaining != null)
              ListTile(
                leading: const Icon(Icons.bedtime),
                title: Text(
                    'Stopping in ${FormatUtils.formatDuration(state.remaining!)}'),
                trailing: TextButton(
                  onPressed: () {
                    notifier.cancel();
                    Navigator.pop(context);
                  },
                  child: const Text('Cancel timer'),
                ),
              )
            else if (state.stopAtEndOfTrack)
              ListTile(
                leading: const Icon(Icons.bedtime),
                title: const Text('Stopping at end of current track'),
                trailing: TextButton(
                  onPressed: () {
                    notifier.cancel();
                    Navigator.pop(context);
                  },
                  child: const Text('Cancel timer'),
                ),
              ),
            Wrap(
              spacing: 8,
              children: [
                for (final minutes in [15, 30, 45, 60, 90])
                  ActionChip(
                    label: Text('$minutes min'),
                    onPressed: () {
                      notifier.start(Duration(minutes: minutes));
                      Navigator.pop(context);
                    },
                  ),
                ActionChip(
                  label: const Text('End of track'),
                  onPressed: () {
                    notifier.stopAtEndOfTrack();
                    Navigator.pop(context);
                  },
                ),
              ],
            ),
          ],
        ),
      ),
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
    final posMs =
        position.inMilliseconds.toDouble().clamp(0, maxMs > 0 ? maxMs : 1);

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

/// In-app volume control (design 4.1).
class _VolumeBar extends ConsumerWidget {
  const _VolumeBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final handler = ref.read(audioHandlerProvider);
    final volume = ref.watch(volumeProvider).value ?? handler.volume;

    return Row(
      children: [
        const Icon(Icons.volume_down, size: 20),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              trackHeight: 2,
            ),
            child: Slider(
              value: volume.clamp(0.0, 1.0),
              onChanged: (v) => handler.setVolume(v),
            ),
          ),
        ),
        const Icon(Icons.volume_up, size: 20),
      ],
    );
  }
}

class _QueueSheet extends ConsumerStatefulWidget {
  const _QueueSheet();

  @override
  ConsumerState<_QueueSheet> createState() => _QueueSheetState();
}

class _QueueSheetState extends ConsumerState<_QueueSheet> {
  /// Fixed row height so the scroll-to-current math is exact in any queue.
  static const _rowExtent = 72.0;

  bool _jumpedToCurrent = false;

  /// Offset that centers row [index] in the viewport, clamped to bounds.
  double _targetOffset(ScrollController controller, int index) {
    final viewport = controller.position.viewportDimension;
    return (index * _rowExtent - viewport / 2 + _rowExtent / 2)
        .clamp(0.0, controller.position.maxScrollExtent);
  }

  /// On open, position the list so the playing track is visible (roughly
  /// centered) — no hunting through a large queue.
  void _scrollToCurrent(ScrollController controller, int index) {
    if (_jumpedToCurrent) return;
    _jumpedToCurrent = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !controller.hasClients) return;
      controller.jumpTo(_targetOffset(controller, index));
    });
  }

  @override
  Widget build(BuildContext context) {
    // Use the handler's queue stream (authoritative) so indices always match
    // the player, even after removals.
    final queue = ref.watch(queueProvider).value ?? [];
    final currentIndex = ref.watch(currentIndexProvider).value ?? 0;
    final handler = ref.read(audioHandlerProvider);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      builder: (_, scrollController) {
        _scrollToCurrent(scrollController, currentIndex);
        return Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Text('Queue (${queue.length} tracks)',
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.my_location, size: 20),
                  tooltip: 'Go to current track',
                  onPressed: () {
                    if (!scrollController.hasClients) return;
                    scrollController.animateTo(
                      _targetOffset(scrollController, currentIndex),
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOutCubic,
                    );
                  },
                ),
                TextButton(
                  onPressed: () {
                    // clear() stops playback and drops the handler queue too.
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
              itemExtent: _rowExtent,
              itemCount: queue.length,
              onReorderItem: (oldIndex, newIndex) {
                // Mutate via the handler — its queue is authoritative even
                // when playback started from Android Auto / voice search.
                handler.moveQueueItem(oldIndex, newIndex);
              },
              itemBuilder: (_, index) {
                final item = queue[index];
                final isCurrent = index == currentIndex;
                return ListTile(
                  // Index-qualified: the same track may appear twice.
                  key: ValueKey('q-$index-${item.id}'),
                  leading: isCurrent
                      ? Icon(Icons.equalizer,
                          color: Theme.of(context).colorScheme.primary)
                      : Text('${index + 1}',
                          style: Theme.of(context).textTheme.bodySmall),
                  title: Text(
                    item.title,
                    style: isCurrent
                        ? TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.bold)
                        : null,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    item.artist ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                          FormatUtils.formatDuration(
                              item.duration ?? Duration.zero),
                          style: Theme.of(context).textTheme.bodySmall),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.remove_circle_outline,
                            size: 20),
                        onPressed: () => handler.removeQueueItemAt(index),
                      ),
                      const Icon(Icons.drag_handle, size: 20),
                    ],
                  ),
                  onTap: () => handler.skipToQueueItem(index),
                );
              },
            ),
          ),
        ],
        );
      },
    );
  }
}
