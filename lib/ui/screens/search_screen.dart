import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/track.dart';
import '../../providers/audio_provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/nas_provider.dart';
import '../../utils/format_utils.dart';
import '../widgets/track_tile.dart';
import 'now_playing_screen.dart';

enum SortOption { name, artist, album, dateModified, duration }

enum SearchScope { all, library, folder, nas }

final searchScopeProvider =
    StateProvider<SearchScope>((ref) => SearchScope.all);

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
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(searchQueryProvider);
    final scope = ref.watch(searchScopeProvider);
    final currentFolder = ref.watch(currentFolderProvider);
    final adapter = ref.watch(authenticatedNasProvider);
    final crawl = ref.watch(nasIndexCrawlProvider);

    final searchesLocal = scope == SearchScope.all ||
        scope == SearchScope.library ||
        scope == SearchScope.folder;
    final searchesNas =
        (scope == SearchScope.all || scope == SearchScope.nas) &&
            adapter != null;
    final folderScope =
        scope == SearchScope.folder ? currentFolder : null;

    // Local results: query search, or full-library browse when only a
    // format filter is set (design 6.3: "show only FLAC files").
    final AsyncValue<List<Track>> localAsync = !searchesLocal
        ? const AsyncData([])
        : query.isNotEmpty
            ? ref.watch(
                searchResultsProvider((query: query, folder: folderScope)))
            : _filterFormat.isNotEmpty
                ? ref.watch(allTracksProvider)
                : const AsyncData([]);

    final AsyncValue<List<Track>> nasAsync = searchesNas && query.isNotEmpty
        ? ref.watch(nasSearchResultsProvider(query))
        : const AsyncData([]);

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: false,
          decoration: const InputDecoration(
            hintText: 'Search by title, artist, album...',
            border: InputBorder.none,
          ),
          onChanged: (v) => ref.read(searchQueryProvider.notifier).state = v,
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
      body: Column(
        children: [
          // Scope selector: what to search.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _scopeChip(SearchScope.all, 'Everything'),
                  const SizedBox(width: 8),
                  _scopeChip(SearchScope.library, 'Library'),
                  if (currentFolder != null) ...[
                    const SizedBox(width: 8),
                    _scopeChip(
                        SearchScope.folder,
                        'Folder (${FormatUtils.displayFolder(currentFolder).split(RegExp(r'[\\/]')).last})'),
                  ],
                  if (adapter != null) ...[
                    const SizedBox(width: 8),
                    _scopeChip(SearchScope.nas, 'NAS'),
                  ],
                ],
              ),
            ),
          ),
          // NAS index coverage banner.
          if (searchesNas) _NasIndexBanner(crawl: crawl),
          Expanded(
            child: query.isEmpty && _filterFormat.isEmpty
                ? _SearchHint()
                : _buildResults(context, query, localAsync, nasAsync),
          ),
        ],
      ),
    );
  }

  Widget _scopeChip(SearchScope scope, String label) {
    final selected = ref.watch(searchScopeProvider) == scope;
    return ChoiceChip(
      label: Text(label, overflow: TextOverflow.ellipsis),
      selected: selected,
      onSelected: (_) =>
          ref.read(searchScopeProvider.notifier).state = scope,
    );
  }

  Widget _buildResults(
    BuildContext context,
    String query,
    AsyncValue<List<Track>> localAsync,
    AsyncValue<List<Track>> nasAsync,
  ) {
    if (localAsync.isLoading || nasAsync.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (localAsync.hasError) {
      return Center(child: Text('Error: ${localAsync.error}'));
    }

    final local = localAsync.value ?? [];
    // NAS errors shouldn't kill local results — show what we have.
    final nas = nasAsync.value ?? [];

    // Merge, avoiding duplicates for downloaded tracks indexed both ways.
    final seen = <String>{};
    final combined = <Track>[];
    for (final t in [...local, ...nas]) {
      final key = t.nasPath ?? t.filePath;
      if (seen.add(key)) combined.add(t);
    }

    final filtered = _applyFilter(combined);
    final sorted = _applySort(filtered);

    if (sorted.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.search_off, size: 64, color: Colors.grey),
            const SizedBox(height: 12),
            Text(query.isNotEmpty
                ? 'No results for "$query"'
                : 'No ${_filterFormat.toUpperCase()} tracks in the library'),
          ],
        ),
      );
    }

    final nasCount = sorted.where((t) => t.source == TrackSource.nas).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            '${sorted.length} result${sorted.length == 1 ? '' : 's'}'
            '${nasCount > 0 ? ' ($nasCount from NAS)' : ''}'
            '${_filterFormat.isNotEmpty ? ' · ${_filterFormat.toUpperCase()} only' : ''}',
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
        list.sort((a, b) =>
            a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      case SortOption.artist:
        list.sort((a, b) =>
            a.artist.toLowerCase().compareTo(b.artist.toLowerCase()));
      case SortOption.album:
        list.sort(
            (a, b) => a.album.toLowerCase().compareTo(b.album.toLowerCase()));
      case SortOption.dateModified:
        list.sort((a, b) => (b.dateModified ?? DateTime(0))
            .compareTo(a.dateModified ?? DateTime(0)));
      case SortOption.duration:
        list.sort((a, b) => a.duration.compareTo(b.duration));
    }
    return list;
  }

  String _sortLabel(SortOption s) => switch (s) {
        SortOption.name => 'NAME',
        SortOption.artist => 'ARTIST',
        SortOption.album => 'ALBUM',
        SortOption.dateModified => 'DATE',
        SortOption.duration => 'LENGTH',
      };

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
                          label: Text(_sortLabel(s)),
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
                children: [
                  '', 'mp3', 'flac', 'aac', 'ogg', 'wav', 'm4a', 'alac',
                  'aiff', 'opus'
                ]
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

/// Explains NAS search coverage and offers/controls a full index crawl.
class _NasIndexBanner extends ConsumerWidget {
  final NasCrawlState crawl;

  const _NasIndexBanner({required this.crawl});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(nasIndexCrawlProvider.notifier);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: crawl.crawling
          ? Row(
              children: [
                const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Indexing NAS... ${crawl.folders} folders, ${crawl.files} tracks',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                TextButton(
                  onPressed: notifier.cancel,
                  child: const Text('Stop'),
                ),
              ],
            )
          : Row(
              children: [
                Expanded(
                  child: Text(
                    crawl.lastCompleted != null
                        ? 'NAS fully indexed (${crawl.files} tracks)'
                        : 'NAS search covers browsed/indexed folders only',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.sync, size: 16),
                  label: Text(
                      crawl.lastCompleted != null ? 'Re-index' : 'Index NAS'),
                  onPressed: notifier.crawl,
                ),
              ],
            ),
    );
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              'Search by track title, artist, or album — use the chips above '
              'to choose what gets searched, or pick a format filter to '
              'browse by file type',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }
}
