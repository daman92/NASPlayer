import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../models/track.dart';
import '../../providers/audio_provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/playlist_provider.dart';
import '../widgets/add_to_playlist_sheet.dart';
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
          if (currentFolder != null) ...[
            IconButton(
              icon: const Icon(Icons.sort),
              tooltip: 'Sort & filter',
              onPressed: () => _showSortFilterSheet(context, ref),
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Rescan folder',
              onPressed: () => ref
                  .read(scanNotifierProvider.notifier)
                  .scanFolder(currentFolder),
            ),
          ],
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
    // Needed for direct-path reads of on-device audio files.
    await Permission.audio.request();

    // System tree picker: shows device storage AND cloud providers
    // (Google Drive, etc.) and persists the access grant.
    final saf = ref.read(safScannerProvider);
    final treeUri = await saf.pickTree();
    if (treeUri == null) return;

    // Device-storage trees resolve to a real path → full ID3 metadata scan.
    // Cloud trees (no filesystem path) scan through the DocumentsProvider.
    final folder = saf.resolveToFilesystemPath(treeUri) ?? treeUri;

    ref.read(currentFolderProvider.notifier).state = folder;
    await ref.read(scanNotifierProvider.notifier).scanFolder(folder);
  }

  void _showSortFilterSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      builder: (_) => const _SortFilterSheet(),
    );
  }
}

class _SortFilterSheet extends ConsumerWidget {
  const _SortFilterSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sort = ref.watch(librarySortProvider);
    final format = ref.watch(libraryFormatFilterProvider);
    final groupByAlbum = ref.watch(libraryGroupByAlbumProvider);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Sort by', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: LibrarySort.values
                  .map((s) => ChoiceChip(
                        label: Text(_sortLabel(s)),
                        selected: sort == s,
                        onSelected: (_) => ref
                            .read(librarySortProvider.notifier)
                            .state = s,
                      ))
                  .toList(),
            ),
            const SizedBox(height: 16),
            Text('Format', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                '', 'mp3', 'flac', 'aac', 'ogg', 'wav', 'm4a', 'alac',
                'aiff', 'opus'
              ]
                  .map((f) => ChoiceChip(
                        label: Text(f.isEmpty ? 'All' : f.toUpperCase()),
                        selected: format == f,
                        onSelected: (_) => ref
                            .read(libraryFormatFilterProvider.notifier)
                            .state = f,
                      ))
                  .toList(),
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Group by album'),
              value: groupByAlbum,
              onChanged: (v) =>
                  ref.read(libraryGroupByAlbumProvider.notifier).state = v,
            ),
          ],
        ),
      ),
    );
  }

  String _sortLabel(LibrarySort s) => switch (s) {
        LibrarySort.name => 'NAME',
        LibrarySort.artist => 'ARTIST',
        LibrarySort.album => 'ALBUM',
        LibrarySort.dateModified => 'DATE',
        LibrarySort.duration => 'LENGTH',
      };
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
    final sort = ref.watch(librarySortProvider);
    final format = ref.watch(libraryFormatFilterProvider);
    final groupByAlbum = ref.watch(libraryGroupByAlbumProvider);
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
      data: (allTracks) {
        if (allTracks.isEmpty) {
          return const Center(child: Text('No audio files found'));
        }

        var tracks = allTracks;
        if (format.isNotEmpty) {
          tracks = tracks
              .where((t) => t.format.toLowerCase() == format)
              .toList();
        }
        tracks = _applySort(tracks, sort);

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
                    format.isEmpty
                        ? '${tracks.length} tracks'
                        : '${tracks.length} ${format.toUpperCase()} tracks',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const Spacer(),
                  TextButton.icon(
                    icon: const Icon(Icons.shuffle, size: 16),
                    label: const Text('Shuffle All'),
                    onPressed: () =>
                        _playAll(context, ref, tracks, shuffle: true),
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
              child: groupByAlbum
                  ? _AlbumGroupedList(
                      tracks: tracks,
                      isSelecting: isSelecting,
                      selected: selected,
                    )
                  : ListView.builder(
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
                          onLongPress: () => ref
                              .read(selectionProvider.notifier)
                              .toggle(track.filePath),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  List<Track> _applySort(List<Track> tracks, LibrarySort sort) {
    final list = List<Track>.from(tracks);
    switch (sort) {
      case LibrarySort.name:
        list.sort((a, b) =>
            a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      case LibrarySort.artist:
        list.sort((a, b) =>
            a.artist.toLowerCase().compareTo(b.artist.toLowerCase()));
      case LibrarySort.album:
        list.sort(
            (a, b) => a.album.toLowerCase().compareTo(b.album.toLowerCase()));
      case LibrarySort.dateModified:
        list.sort((a, b) => (b.dateModified ?? DateTime(0))
            .compareTo(a.dateModified ?? DateTime(0)));
      case LibrarySort.duration:
        list.sort((a, b) => a.duration.compareTo(b.duration));
    }
    return list;
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

/// Album-grouped library view (design 6.1: album used for grouping).
class _AlbumGroupedList extends ConsumerWidget {
  final List<Track> tracks;
  final bool isSelecting;
  final Set<String> selected;

  const _AlbumGroupedList({
    required this.tracks,
    required this.isSelecting,
    required this.selected,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = groupBy(tracks, (Track t) => t.album);
    final albums = groups.keys.sorted(
        (a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    return ListView.builder(
      itemCount: albums.length,
      itemBuilder: (context, index) {
        final album = albums[index];
        final albumTracks = groups[album]!;
        return ExpansionTile(
          leading: const Icon(Icons.album),
          title: Text(album, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
              '${albumTracks.first.artist} — ${albumTracks.length} tracks',
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          children: albumTracks
              .mapIndexed((i, track) => TrackTile(
                    track: track,
                    isSelected: selected.contains(track.filePath),
                    isSelecting: isSelecting,
                    position: i + 1,
                    onTap: () {
                      if (isSelecting) {
                        ref
                            .read(selectionProvider.notifier)
                            .toggle(track.filePath);
                      } else {
                        ref
                            .read(queueNotifierProvider.notifier)
                            .playTracks(albumTracks, startIndex: i);
                        Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => const NowPlayingScreen()));
                      }
                    },
                    onLongPress: () => ref
                        .read(selectionProvider.notifier)
                        .toggle(track.filePath),
                  ))
              .toList(),
        );
      },
    );
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
      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
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
    final tracks =
        allTracks.where((t) => selected.contains(t.filePath)).toList();
    AddToPlaylistSheet.show(context, tracks, onDone: onClear);
  }
}
