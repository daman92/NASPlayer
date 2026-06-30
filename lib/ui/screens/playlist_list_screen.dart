import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/playlist.dart';
import '../../models/track.dart';
import '../../providers/audio_provider.dart';
import '../../providers/library_provider.dart';
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
            onPressed: () => _rename(context, ref, p),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _delete(context, ref, p),
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
                    onReorder: (oldIndex, newIndex) {
                      ref
                          .read(playlistNotifierProvider.notifier)
                          .reorderTrack(p.id, oldIndex, newIndex);
                    },
                    itemBuilder: (_, index) {
                      final path = p.trackPaths[index];
                      final name = path.split(RegExp(r'[\\/]')).last;
                      final title = name.contains('.')
                          ? name.substring(0, name.lastIndexOf('.'))
                          : name;

                      return Dismissible(
                        key: ValueKey('$index-$path'),
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
                          key: ValueKey(path),
                          leading: Text('${index + 1}',
                              style: Theme.of(context).textTheme.bodySmall),
                          title: Text(title,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: const Icon(Icons.drag_handle),
                          onTap: () => _playPlaylist(context, ref, p),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }

  Future<void> _playPlaylist(BuildContext context, WidgetRef ref, Playlist p,
      {bool shuffle = false}) async {
    final db = ref.read(databaseProvider);
    final tracks = <Track>[];

    for (final path in p.trackPaths) {
      final folderPath = path.contains('/')
          ? path.substring(0, path.lastIndexOf('/') + 1)
          : path.contains('\\')
              ? path.substring(0, path.lastIndexOf('\\') + 1)
              : '';

      final rows = await db.getTracksForFolder(folderPath);
      final row = rows.where((r) => r['file_path'] == path).firstOrNull;
      if (row != null) {
        tracks.add(Track(
          id: row['id'] as String,
          title: row['title'] as String,
          artist: row['artist'] as String? ?? 'Unknown Artist',
          album: row['album'] as String? ?? 'Unknown Album',
          duration: Duration(milliseconds: (row['duration_ms'] as int?) ?? 0),
          filePath: row['file_path'] as String,
          source: TrackSource.local,
          format: row['format'] as String? ?? '',
        ));
      } else {
        final name = path.split(RegExp(r'[\\/]')).last;
        tracks.add(Track(
          id: path,
          title: name.contains('.')
              ? name.substring(0, name.lastIndexOf('.'))
              : name,
          artist: 'Unknown Artist',
          album: 'Unknown Album',
          duration: Duration.zero,
          filePath: path,
          source: TrackSource.local,
        ));
      }
    }

    final list = shuffle ? (List<Track>.from(tracks)..shuffle()) : tracks;
    if (list.isEmpty) return;
    await ref.read(queueNotifierProvider.notifier).playTracks(list);
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
