import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/track.dart';
import '../../providers/playlist_provider.dart';

/// Bottom sheet offering "new playlist" or any existing playlist as the
/// destination for [tracks] (design 5.1: add selection to a new or existing
/// playlist — reachable from every browse screen).
class AddToPlaylistSheet extends ConsumerWidget {
  final List<Track> tracks;
  final VoidCallback? onDone;

  const AddToPlaylistSheet({super.key, required this.tracks, this.onDone});

  static Future<void> show(
    BuildContext context,
    List<Track> tracks, {
    VoidCallback? onDone,
  }) {
    return showModalBottomSheet(
      context: context,
      builder: (_) => AddToPlaylistSheet(tracks: tracks, onDone: onDone),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlistsAsync = ref.watch(playlistNotifierProvider);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Add ${tracks.length} track${tracks.length == 1 ? '' : 's'} to...',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.add_circle_outline),
              title: const Text('New Playlist'),
              onTap: () async {
                // Capture everything that outlives this sheet BEFORE popping:
                // after pop the ConsumerWidget's ref is disposed and any use
                // of it throws.
                final notifier = ref.read(playlistNotifierProvider.notifier);
                final rootContext = Navigator.of(context).context;
                Navigator.pop(context);
                final name = await _promptName(rootContext);
                if (name != null && name.isNotEmpty) {
                  await notifier.createPlaylist(name, tracks);
                  onDone?.call();
                }
              },
            ),
            const Divider(),
            Flexible(
              child: playlistsAsync.when(
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (e, _) => Text('Error: $e'),
                data: (playlists) => ListView(
                  shrinkWrap: true,
                  children: playlists
                      .map((p) => ListTile(
                            leading: const Icon(Icons.queue_music),
                            title: Text(p.name),
                            subtitle: Text('${p.trackCount} tracks'),
                            onTap: () async {
                              // Capture before pop — ref and this context are
                              // unusable once the sheet route is disposed.
                              final notifier = ref
                                  .read(playlistNotifierProvider.notifier);
                              final messenger =
                                  ScaffoldMessenger.of(context);
                              Navigator.pop(context);
                              await notifier.addTracksToPlaylist(p.id, tracks);
                              onDone?.call();
                              messenger.showSnackBar(
                                SnackBar(
                                    content: Text(
                                        'Added ${tracks.length} tracks to ${p.name}')),
                              );
                            },
                          ))
                      .toList(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _promptName(BuildContext context) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Playlist name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }
}
