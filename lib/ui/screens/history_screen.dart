import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/track.dart';
import '../../providers/audio_provider.dart';
import '../../providers/history_provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/nas_provider.dart';

/// Play history & stats (design Phase 2).
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Play History'),
          bottom: const TabBar(tabs: [
            Tab(text: 'Recent'),
            Tab(text: 'Most Played'),
          ]),
          actions: [
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: 'Clear history',
              onPressed: () => _clearHistory(context, ref),
            ),
          ],
        ),
        body: const TabBarView(
          children: [
            _RecentTab(),
            _MostPlayedTab(),
          ],
        ),
      ),
    );
  }

  void _clearHistory(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear History'),
        content: const Text('Delete all play history? This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(databaseProvider).clearHistory();
      ref.read(historyRefreshProvider.notifier).state++;
    }
  }
}

class _RecentTab extends ConsumerWidget {
  const _RecentTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recentAsync = ref.watch(recentPlaysProvider);
    return recentAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (entries) {
        if (entries.isEmpty) {
          return const Center(child: Text('Nothing played yet'));
        }
        return ListView.builder(
          itemCount: entries.length,
          itemBuilder: (_, i) {
            final e = entries[i];
            return ListTile(
              leading: Icon(
                e.source == 'nas' ? Icons.storage : Icons.music_note,
                size: 20,
              ),
              title: Text(e.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '${e.artist.isNotEmpty ? e.artist : 'Unknown Artist'} · ${_timeAgo(e.playedAt)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => _replay(context, ref, e),
            );
          },
        );
      },
    );
  }
}

class _MostPlayedTab extends ConsumerWidget {
  const _MostPlayedTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mostAsync = ref.watch(mostPlayedProvider);
    return mostAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (entries) {
        if (entries.isEmpty) {
          return const Center(child: Text('Nothing played yet'));
        }
        return ListView.builder(
          itemCount: entries.length,
          itemBuilder: (_, i) {
            final e = entries[i];
            return ListTile(
              leading: CircleAvatar(
                radius: 16,
                child: Text('${i + 1}',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
              title: Text(e.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                e.artist.isNotEmpty ? e.artist : 'Unknown Artist',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Text('${e.playCount}×',
                  style: Theme.of(context).textTheme.bodyMedium),
              onTap: () => _replay(context, ref, e),
            );
          },
        );
      },
    );
  }
}

Future<void> _replay(
    BuildContext context, WidgetRef ref, PlayHistoryEntry entry) async {
  // NAS history entries store a (possibly stale) stream URL as filePath —
  // re-resolve through the active adapter with fresh cookies instead.
  if (entry.source == 'nas') {
    final adapter = ref.read(authenticatedNasProvider);
    final nasPath = entry.nasPath;
    if (adapter == null || nasPath == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Log in to your NAS to replay this track')),
        );
      }
      return;
    }
    final track = Track(
      id: entry.trackId,
      title: entry.title,
      artist: entry.artist.isNotEmpty ? entry.artist : 'Unknown Artist',
      album: entry.album.isNotEmpty ? entry.album : 'Unknown Album',
      duration: Duration.zero,
      filePath: adapter.getStreamUrl(nasPath),
      nasPath: nasPath,
      httpHeaders: adapter.streamHeaders,
      source: TrackSource.nas,
      format: nasPath.contains('.')
          ? nasPath.split('.').last.toLowerCase()
          : '',
    );
    await ref.read(queueNotifierProvider.notifier).playSingle(track);
    return;
  }

  final db = ref.read(databaseProvider);
  final rows = await db.getTracksByPaths([entry.filePath]);
  if (rows.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Track is no longer in the library index')),
      );
    }
    return;
  }
  final track = rowToTrack(rows.first);
  await ref.read(queueNotifierProvider.notifier).playSingle(track);
}

String _timeAgo(DateTime time) {
  final diff = DateTime.now().difference(time);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inHours < 1) return '${diff.inMinutes}m ago';
  if (diff.inDays < 1) return '${diff.inHours}h ago';
  if (diff.inDays < 30) return '${diff.inDays}d ago';
  return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';
}
