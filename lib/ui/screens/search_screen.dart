import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/track.dart';
import '../../providers/audio_provider.dart';
import '../../providers/library_provider.dart';
import '../widgets/track_tile.dart';
import 'now_playing_screen.dart';

enum SortOption { name, artist, album, duration }

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  SortOption _sortBy = SortOption.name;
  String _filterFormat = '';

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(searchQueryProvider);
    final resultsAsync = ref.watch(searchResultsProvider(query));

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: false,
          decoration: const InputDecoration(
            hintText: 'Search by title, artist, album...',
            border: InputBorder.none,
          ),
          onChanged: (v) =>
              ref.read(searchQueryProvider.notifier).state = v,
        ),
        actions: [
          if (_controller.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () {
                _controller.clear();
                ref.read(searchQueryProvider.notifier).state = '';
              },
            ),
          IconButton(
            icon: const Icon(Icons.tune),
            onPressed: () => _showFilterSheet(context),
          ),
        ],
      ),
      body: query.isEmpty
          ? _SearchHint()
          : resultsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Error: $e')),
              data: (tracks) {
                final filtered = _applyFilter(tracks);
                final sorted = _applySort(filtered);

                if (sorted.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.search_off, size: 64, color: Colors.grey),
                        const SizedBox(height: 12),
                        Text('No results for "$query"'),
                      ],
                    ),
                  );
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Text(
                        '${sorted.length} result${sorted.length == 1 ? '' : 's'}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: sorted.length,
                        itemBuilder: (_, i) => TrackTile(
                          track: sorted[i],
                          onTap: () => _playFrom(context, ref, sorted, i),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }

  List<Track> _applyFilter(List<Track> tracks) {
    if (_filterFormat.isEmpty) return tracks;
    return tracks
        .where((t) => t.format.toLowerCase() == _filterFormat.toLowerCase())
        .toList();
  }

  List<Track> _applySort(List<Track> tracks) {
    final list = List<Track>.from(tracks);
    switch (_sortBy) {
      case SortOption.name:
        list.sort((a, b) => a.title.compareTo(b.title));
      case SortOption.artist:
        list.sort((a, b) => a.artist.compareTo(b.artist));
      case SortOption.album:
        list.sort((a, b) => a.album.compareTo(b.album));
      case SortOption.duration:
        list.sort((a, b) => a.duration.compareTo(b.duration));
    }
    return list;
  }

  void _showFilterSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setModalState) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Sort by', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: SortOption.values
                    .map((s) => ChoiceChip(
                          label: Text(s.name.toUpperCase()),
                          selected: _sortBy == s,
                          onSelected: (_) {
                            setModalState(() => _sortBy = s);
                            setState(() => _sortBy = s);
                          },
                        ))
                    .toList(),
              ),
              const SizedBox(height: 16),
              Text('Format', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: ['', 'mp3', 'flac', 'aac', 'ogg', 'wav']
                    .map((f) => ChoiceChip(
                          label: Text(f.isEmpty ? 'All' : f.toUpperCase()),
                          selected: _filterFormat == f,
                          onSelected: (_) {
                            setModalState(() => _filterFormat = f);
                            setState(() => _filterFormat = f);
                          },
                        ))
                    .toList(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _playFrom(
      BuildContext context, WidgetRef ref, List<Track> tracks, int index) async {
    await ref
        .read(queueNotifierProvider.notifier)
        .playTracks(tracks, startIndex: index);
    if (context.mounted) {
      Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const NowPlayingScreen()));
    }
  }
}

class _SearchHint extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.search, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          Text('Search your library',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Search by track title, artist, or album',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
