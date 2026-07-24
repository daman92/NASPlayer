import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/playlist.dart';
import '../../providers/audio_provider.dart';
import '../../providers/playlist_provider.dart';
import '../widgets/album_art.dart';
import 'now_playing_screen.dart';

class PlaylistListScreen extends ConsumerWidget {
  const PlaylistListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlistsAsync = ref.watch(playlistNotifierProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Playlists')),
      body: playlistsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (playlists) {
          if (playlists.isEmpty) {
            return const _EmptyPlaylists();
          }
          return ListView.builder(
            itemCount: playlists.length,
            itemBuilder: (_, index) => _PlaylistTile(
              playlist: playlists[index],
            ),
          );
        },
      ),
    );
  }
}

class _EmptyPlaylists extends StatelessWidget {
  const _EmptyPlaylists();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.queue_music, size: 80, color: Colors.grey),
          const SizedBox(height: 16),
          Text('No playlists yet',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            'Long-press tracks in your library to add them to a playlist',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: Colors.grey),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _PlaylistTile extends ConsumerWidget {
  final Playlist playlist;

  const _PlaylistTile({required this.playlist});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: SizedBox(
        width: 48,
        height: 48,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: const AlbumArt(artUri: null, size: 48),
        ),
      ),
      title: Text(playlist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${playlist.trackCount} tracks'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PlaylistDetailScreen(playlist: playlist),
          ),
        );
      },
    );
  }
}

class PlaylistDetailScreen extends ConsumerWidget {
  final Playlist playlist;

  const PlaylistDetailScreen({super.key, required this.playlist});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlistsAsync = ref.watch(playlistNotifierProvider);
    final p = playlistsAsync.value?.firstWhere(
          (pl) => pl.id == playlist.id,
          orElse: () => playlist,
        ) ??
        playlist;

    return Scaffold(
      appBar: AppBar(
        title: Text(p.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            tooltip: 'Rename',
            onPressed: () => _rename(context, ref, p),
          ),
          PopupMenuButton<String>(
            onSelected: (action) {
              switch (action) {
                case 'clear':
                  _clear(context, ref, p);
                case 'delete':
                  _delete(context, ref, p);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'clear',
                child: ListTile(
                  leading: Icon(Icons.clear_all),
                  title: Text('Clear all tracks'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'delete',
                child: ListTile(
                  leading: Icon(Icons.delete_outline),
                  title: Text('Delete playlist'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: p.trackPaths.isEmpty
          ? const Center(child: Text('No tracks in this playlist'))
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(
                    children: [
                      Text('${p.trackCount} tracks',
                          style: Theme.of(context).textTheme.bodySmall),
                      const Spacer(),
                      TextButton.icon(
                        icon: const Icon(Icons.shuffle, size: 16),
                        label: const Text('Shuffle'),
                        onPressed: () =>
                            _playPlaylist(context, ref, p, shuffle: true),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.play_arrow, size: 16),
                        label: const Text('Play All'),
                        onPressed: () => _playPlaylist(context, ref, p),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ReorderableListView.builder(
                    itemCount: p.trackPaths.length,
                    onReorderItem: (oldIndex, newIndex) {
                      ref
                          .read(playlistNotifierProvider.notifier)
                          .moveTrack(p.id, oldIndex, newIndex);
                    },
                    itemBuilder: (_, index) {
                      final path = p.trackPaths[index];
                      final isNas = path.startsWith(nasPathPrefix);
                      final displayPath =
                          isNas ? path.substring(nasPathPrefix.length) : path;
                      final name = displayPath.split(RegExp(r'[\\/]')).last;
                      final title = name.contains('.')
                          ? name.substring(0, name.lastIndexOf('.'))
                          : name;

                      return Dismissible(
                        // Keyed on updatedAt too: after a removal, a duplicate
                        // of the dismissed track shifting into this index must
                        // get a FRESH key or Flutter reuses the dismissed
                        // state and throws.
                        key: ValueKey(
                            'pl-${p.id}-${p.updatedAt.millisecondsSinceEpoch}-$index-$path'),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          color: Colors.red,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 16),
                          child: const Icon(Icons.delete, color: Colors.white),
                        ),
                        onDismissed: (_) {
                          ref
                              .read(playlistNotifierProvider.notifier)
                              .removeTrack(p.id, index);
                        },
                        child: ListTile(
                          leading: Text('${index + 1}',
                              style: Theme.of(context).textTheme.bodySmall),
                          title: Text(title,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: isNas
                              ? const Text('NAS',
                                  style: TextStyle(fontSize: 11))
                              : null,
                          trailing: const Icon(Icons.drag_handle),
                          onTap: () => _playPlaylist(context, ref, p,
                              startIndex: index),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }

  /// Resolve paths to playable tracks; missing/unavailable files are skipped
  /// with a notification (design 5.3 / section 7).
  Future<void> _playPlaylist(BuildContext context, WidgetRef ref, Playlist p,
      {bool shuffle = false, int startIndex = 0}) async {
    final resolved = await resolvePlaylistTracks(ref, p.trackPaths);

    if (context.mounted && resolved.skipped.isNotEmpty) {
      final names = resolved.skipped.take(3).join(', ');
      final more = resolved.skipped.length > 3
          ? ' and ${resolved.skipped.length - 3} more'
          : '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Skipped ${resolved.skipped.length} unavailable track${resolved.skipped.length == 1 ? '' : 's'}: $names$more'),
          duration: const Duration(seconds: 5),
        ),
      );
    }

    var tracks = resolved.tracks;
    if (tracks.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No playable tracks in this playlist')),
        );
      }
      return;
    }

    // Remap the tapped row's ORIGINAL index onto the resolved list, which
    // may be shorter when unavailable entries were skipped.
    var effectiveStart = resolved.resolveStartIndex(startIndex);
    if (shuffle) {
      tracks = List.from(tracks)..shuffle();
      effectiveStart = 0;
    }

    await ref
        .read(queueNotifierProvider.notifier)
        .playTracks(tracks, startIndex: effectiveStart);
    if (context.mounted) {
      Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const NowPlayingScreen()));
    }
  }

  void _rename(BuildContext context, WidgetRef ref, Playlist p) async {
    final controller = TextEditingController(text: p.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename Playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    if (newName != null && newName.isNotEmpty) {
      await ref
          .read(playlistNotifierProvider.notifier)
          .renamePlaylist(p.id, newName);
    }
  }

  /// Design 5.2: clear entire playlist in one action, with confirmation.
  void _clear(BuildContext context, WidgetRef ref, Playlist p) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear Playlist'),
        content: Text(
            'Remove all ${p.trackCount} tracks from "${p.name}"? The playlist itself is kept.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(playlistNotifierProvider.notifier).clearPlaylist(p.id);
    }
  }

  void _delete(BuildContext context, WidgetRef ref, Playlist p) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Playlist'),
        content: Text('Delete "${p.name}"? This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(playlistNotifierProvider.notifier).deletePlaylist(p.id);
      if (context.mounted) Navigator.of(context).pop();
    }
  }
}
