import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../models/track.dart';
import '../../providers/audio_provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/playlist_provider.dart';
import '../widgets/track_tile.dart';
import 'now_playing_screen.dart';

class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentFolder = ref.watch(currentFolderProvider);
    final scanState = ref.watch(scanNotifierProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          if (currentFolder != null)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Rescan folder',
              onPressed: () =>
                  ref.read(scanNotifierProvider.notifier).scanFolder(currentFolder),
            ),
          IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: 'Open folder',
            onPressed: () => _pickFolder(context, ref),
          ),
        ],
      ),
      body: currentFolder == null
          ? _EmptyState(onPickFolder: () => _pickFolder(context, ref))
          : _FolderView(
              folderPath: currentFolder,
              scanState: scanState,
            ),
    );
  }

  Future<void> _pickFolder(BuildContext context, WidgetRef ref) async {
    final status = await Permission.audio.request();
    if (!status.isGranted) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Storage permission required to browse music')),
        );
      }
      return;
    }

    final result = await FilePicker.platform.getDirectoryPath();
    if (result == null) return;

    ref.read(currentFolderProvider.notifier).state = result;
    await ref.read(scanNotifierProvider.notifier).scanFolder(result);
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onPickFolder;

  const _EmptyState({required this.onPickFolder});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.music_note, size: 80, color: Colors.grey),
          const SizedBox(height: 16),
          Text(
            'No folder selected',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'Tap the folder icon to browse your music',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.grey,
                ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            icon: const Icon(Icons.folder_open),
            label: const Text('Open Folder'),
            onPressed: onPickFolder,
          ),
        ],
      ),
    );
  }
}

class _FolderView extends ConsumerWidget {
  final String folderPath;
  final ScanState scanState;

  const _FolderView({required this.folderPath, required this.scanState});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracksAsync = ref.watch(folderTracksProvider(folderPath));
    final selected = ref.watch(selectionProvider);
    final isSelecting = selected.isNotEmpty;

    if (scanState.scanning) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text('Scanning... ${scanState.found} tracks found'),
          const SizedBox(height: 8),
          if (scanState.currentPath != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                scanState.currentPath!,
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      );
    }

    return tracksAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (tracks) {
        if (tracks.isEmpty) {
          return const Center(child: Text('No audio files found'));
        }

        return Column(
          children: [
            if (isSelecting)
              _SelectionToolbar(
                selectedCount: selected.length,
                allTracks: tracks,
                onClear: () => ref.read(selectionProvider.notifier).clear(),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Text(
                    '${tracks.length} tracks',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const Spacer(),
                  TextButton.icon(
                    icon: const Icon(Icons.shuffle, size: 16),
                    label: const Text('Shuffle All'),
                    onPressed: () => _playAll(context, ref, tracks, shuffle: true),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.play_arrow, size: 16),
                    label: const Text('Play All'),
                    onPressed: () => _playAll(context, ref, tracks),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: tracks.length,
                itemBuilder: (context, index) {
                  final track = tracks[index];
                  return TrackTile(
                    track: track,
                    isSelected: selected.contains(track.filePath),
                    isSelecting: isSelecting,
                    position: index + 1,
                    total: tracks.length,
                    onTap: () {
                      if (isSelecting) {
                        ref
                            .read(selectionProvider.notifier)
                            .toggle(track.filePath);
                      } else {
                        _playFrom(context, ref, tracks, index);
                      }
                    },
                    onLongPress: () =>
                        ref.read(selectionProvider.notifier).toggle(track.filePath),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  void _playAll(BuildContext context, WidgetRef ref, List<Track> tracks,
      {bool shuffle = false}) async {
    final list = shuffle ? (List<Track>.from(tracks)..shuffle()) : tracks;
    await ref.read(queueNotifierProvider.notifier).playTracks(list);
    if (context.mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const NowPlayingScreen()),
      );
    }
  }

  void _playFrom(BuildContext context, WidgetRef ref, List<Track> tracks,
      int index) async {
    await ref
        .read(queueNotifierProvider.notifier)
        .playTracks(tracks, startIndex: index);
    if (context.mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const NowPlayingScreen()),
      );
    }
  }
}

class _SelectionToolbar extends ConsumerWidget {
  final int selectedCount;
  final List<Track> allTracks;
  final VoidCallback onClear;

  const _SelectionToolbar({
    required this.selectedCount,
    required this.allTracks,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      color: Theme.of(context).colorScheme.primary.withOpacity(0.12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          IconButton(icon: const Icon(Icons.close), onPressed: onClear),
          Text('$selectedCount selected',
              style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          TextButton.icon(
            icon: const Icon(Icons.playlist_add),
            label: const Text('Add to Playlist'),
            onPressed: () => _addToPlaylist(context, ref),
          ),
        ],
      ),
    );
  }

  void _addToPlaylist(BuildContext context, WidgetRef ref) {
    final selected = ref.read(selectionProvider);
    final tracks = allTracks.where((t) => selected.contains(t.filePath)).toList();
    showModalBottomSheet(
      context: context,
      builder: (_) => _AddToPlaylistSheet(tracks: tracks, onDone: onClear),
    );
  }
}

class _AddToPlaylistSheet extends ConsumerWidget {
  final List<Track> tracks;
  final VoidCallback onDone;

  const _AddToPlaylistSheet({required this.tracks, required this.onDone});

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
            Text('Add ${tracks.length} tracks to...',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.add_circle_outline),
              title: const Text('New Playlist'),
              onTap: () async {
                Navigator.pop(context);
                final name = await _promptName(context);
                if (name != null && name.isNotEmpty) {
                  await ref
                      .read(playlistNotifierProvider.notifier)
                      .createPlaylist(name, tracks);
                  onDone();
                }
              },
            ),
            const Divider(),
            playlistsAsync.when(
              loading: () => const CircularProgressIndicator(),
              error: (e, _) => Text('Error: $e'),
              data: (playlists) => Column(
                children: playlists
                    .map((p) => ListTile(
                          leading: const Icon(Icons.queue_music),
                          title: Text(p.name),
                          subtitle: Text('${p.trackCount} tracks'),
                          onTap: () async {
                            Navigator.pop(context);
                            await ref
                                .read(playlistNotifierProvider.notifier)
                                .addTracksToPlaylist(p.id, tracks);
                            onDone();
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                    content: Text(
                                        'Added ${tracks.length} tracks to ${p.name}')),
                              );
                            }
                          },
                        ))
                    .toList(),
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
