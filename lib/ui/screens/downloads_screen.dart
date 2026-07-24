import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/track.dart';
import '../../providers/audio_provider.dart';
import '../../providers/download_provider.dart';
import '../../utils/format_utils.dart';

/// Offline downloads manager (design Phase 2: pin folders/playlists).
class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(downloadQueueProvider);
    final completedAsync = ref.watch(completedDownloadsProvider);

    final inFlight = active.values
        .where((d) => d.status == 'downloading' || d.status == 'queued')
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Offline Downloads')),
      body: completedAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (completed) {
          final done =
              completed.where((r) => r['status'] == 'done').toList();
          if (inFlight.isEmpty && done.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No downloads yet.\n\nBrowse your NAS and use the pin '
                  'button to download folders or selected tracks for '
                  'offline playback.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          return ListView(
            children: [
              if (inFlight.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text('In progress (${inFlight.length})',
                      style: Theme.of(context).textTheme.bodySmall),
                ),
                ...inFlight.map((d) => ListTile(
                      leading: const Icon(Icons.downloading),
                      title: Text(d.title,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: LinearProgressIndicator(
                        value: d.progress >= 0 ? d.progress : null,
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => ref
                            .read(downloadQueueProvider.notifier)
                            .cancel(d.nasPath),
                      ),
                    )),
                const Divider(),
              ],
              if (done.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(
                    children: [
                      Text('Downloaded (${done.length})',
                          style: Theme.of(context).textTheme.bodySmall),
                      const Spacer(),
                      TextButton.icon(
                        icon: const Icon(Icons.play_arrow, size: 16),
                        label: const Text('Play All'),
                        onPressed: () => _playAll(context, ref, done),
                      ),
                    ],
                  ),
                ),
                ...done.map((row) => ListTile(
                      leading: const Icon(Icons.offline_pin),
                      title: Text(
                        (row['title'] as String?) ??
                            (row['nas_path'] as String),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        row['size_bytes'] != null
                            ? FormatUtils.formatFileSize(
                                row['size_bytes'] as int)
                            : '',
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          await ref
                              .read(downloadServiceProvider)
                              .deleteDownload(row['nas_path'] as String);
                          ref
                              .read(downloadsRefreshProvider.notifier)
                              .state++;
                        },
                      ),
                      onTap: () => _playOne(context, ref, row),
                    )),
              ],
            ],
          );
        },
      ),
    );
  }

  Track _rowToLocalTrack(Map<String, Object?> row) {
    final title = (row['title'] as String?) ?? 'Downloaded track';
    final dot = title.lastIndexOf('.');
    return Track(
      id: 'dl:${row['nas_path']}',
      title: dot > 0 ? title.substring(0, dot) : title,
      artist: 'Unknown Artist',
      album: 'Offline Downloads',
      duration: Duration.zero,
      filePath: row['local_path'] as String,
      source: TrackSource.local,
      format: dot > 0 ? title.substring(dot + 1).toLowerCase() : '',
    );
  }

  void _playAll(BuildContext context, WidgetRef ref,
      List<Map<String, Object?>> rows) async {
    final tracks = rows.map(_rowToLocalTrack).toList();
    if (tracks.isEmpty) return;
    await ref.read(queueNotifierProvider.notifier).playTracks(tracks);
  }

  void _playOne(BuildContext context, WidgetRef ref,
      Map<String, Object?> row) async {
    await ref
        .read(queueNotifierProvider.notifier)
        .playSingle(_rowToLocalTrack(row));
  }
}
