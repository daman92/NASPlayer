import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/nas_config.dart';
import '../../models/track.dart';
import '../../providers/audio_provider.dart';
import '../../providers/nas_provider.dart';
import '../../providers/playlist_provider.dart';
import '../widgets/track_tile.dart';
import 'nas_login_screen.dart';
import 'now_playing_screen.dart';

class NasBrowserScreen extends ConsumerStatefulWidget {
  const NasBrowserScreen({super.key});

  @override
  ConsumerState<NasBrowserScreen> createState() => _NasBrowserScreenState();
}

class _NasBrowserScreenState extends ConsumerState<NasBrowserScreen> {
  final List<String> _pathStack = ['/'];

  String get _currentPath => _pathStack.last;

  @override
  Widget build(BuildContext context) {
    final configs = ref.watch(nasConfigNotifierProvider);
    final adapter = ref.watch(authenticatedNasProvider);

    if (configs.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('NAS')),
        body: _NoNasState(onAdd: () => _addNas(context, ref)),
      );
    }

    final activeConfig = ref.read(nasConfigNotifierProvider.notifier).activeConfig
        ?? configs.first;

    return Scaffold(
      appBar: AppBar(
        title: Text(activeConfig.displayName),
        leading: _pathStack.length > 1
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() => _pathStack.removeLast()),
              )
            : null,
        actions: [
          IconButton(
            icon: const Icon(Icons.storage),
            tooltip: 'Manage NAS',
            onPressed: () => _showNasManager(context, ref),
          ),
          if (adapter == null)
            TextButton.icon(
              icon: const Icon(Icons.login),
              label: const Text('Login'),
              onPressed: () => _login(context, ref, activeConfig),
            ),
        ],
      ),
      body: adapter == null
          ? _LoginPrompt(
              nasName: activeConfig.displayName,
              onLogin: () => _login(context, ref, activeConfig),
            )
          : _NasFolderView(
              path: _currentPath,
              onFolderTap: (path) =>
                  setState(() => _pathStack.add(path)),
            ),
    );
  }

  Future<void> _login(
      BuildContext context, WidgetRef ref, NasConfig config) async {
    final loggedIn = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => NasLoginScreen(
          nasId: config.id,
          baseUrl: config.baseUrl,
          nasName: config.displayName,
        ),
      ),
    );
    if (loggedIn == true) {
      setState(() => _pathStack
        ..clear()
        ..add('/'));
    }
  }

  Future<void> _addNas(BuildContext context, WidgetRef ref) async {
    final result = await showDialog<({String name, String url})>(
      context: context,
      builder: (_) => const _AddNasDialog(),
    );
    if (result != null) {
      final config =
          await ref.read(nasConfigNotifierProvider.notifier).addConfig(
                result.name,
                result.url,
              );
      await ref.read(nasConfigNotifierProvider.notifier).setActive(config.id);
    }
  }

  void _showNasManager(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      builder: (_) => _NasManagerSheet(onAdd: () => _addNas(context, ref)),
    );
  }
}

class _NoNasState extends StatelessWidget {
  final VoidCallback onAdd;

  const _NoNasState({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.storage, size: 80, color: Colors.grey),
          const SizedBox(height: 16),
          Text('No NAS configured',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text('Add your NAS device to start browsing'),
          const SizedBox(height: 24),
          FilledButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('Add NAS Device'),
            onPressed: onAdd,
          ),
        ],
      ),
    );
  }
}

class _LoginPrompt extends StatelessWidget {
  final String nasName;
  final VoidCallback onLogin;

  const _LoginPrompt({required this.nasName, required this.onLogin});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.lock_outline, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          Text('Not logged in to $nasName',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 24),
          FilledButton.icon(
            icon: const Icon(Icons.login),
            label: const Text('Log In'),
            onPressed: onLogin,
          ),
        ],
      ),
    );
  }
}

class _NasFolderView extends ConsumerWidget {
  final String path;
  final void Function(String) onFolderTap;

  const _NasFolderView({required this.path, required this.onFolderTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entriesAsync = ref.watch(nasBrowseProvider(path));
    final selected = ref.watch(selectionProvider);
    final isSelecting = selected.isNotEmpty;

    return entriesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 8),
            Text('Error: $e', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => ref.invalidate(nasBrowseProvider(path)),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
      data: (entries) {
        if (entries.isEmpty) {
          return const Center(child: Text('Empty folder'));
        }

        final dirs = entries.where((e) => e.isDirectory).toList();
        final audioFiles = entries.where((e) => e.isAudio).toList();

        return Column(
          children: [
            if (isSelecting && audioFiles.isNotEmpty)
              _NasSelectionToolbar(
                selectedCount: selected.length,
                onClear: () => ref.read(selectionProvider.notifier).clear(),
              ),
            Expanded(
              child: ListView(
                children: [
                  if (dirs.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text('Folders',
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                    ...dirs.map((dir) => ListTile(
                          leading: const Icon(Icons.folder),
                          title: Text(dir.name),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => onFolderTap(dir.path),
                        )),
                  ],
                  if (audioFiles.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Row(
                        children: [
                          Text('${audioFiles.length} tracks',
                              style: Theme.of(context).textTheme.bodySmall),
                          const Spacer(),
                          TextButton.icon(
                            icon: const Icon(Icons.play_arrow, size: 16),
                            label: const Text('Play All'),
                            onPressed: () => _playAll(context, ref, audioFiles),
                          ),
                        ],
                      ),
                    ),
                    ...audioFiles.asMap().entries.map((e) {
                      final entry = e.value;
                      final track = _entryToTrack(entry);
                      return TrackTile(
                        track: track,
                        isSelected: selected.contains(entry.path),
                        isSelecting: isSelecting,
                        onTap: () {
                          if (isSelecting) {
                            ref.read(selectionProvider.notifier).toggle(entry.path);
                          } else {
                            _playFrom(context, ref, audioFiles, e.key);
                          }
                        },
                        onLongPress: () =>
                            ref.read(selectionProvider.notifier).toggle(entry.path),
                      );
                    }),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Track _entryToTrack(dynamic entry) {
    return Track(
      id: entry.path,
      title: entry.name.split('.').first,
      artist: 'Unknown Artist',
      album: 'Unknown Album',
      duration: Duration.zero,
      filePath: entry.path,
      source: TrackSource.nas,
      format: entry.name.split('.').last.toLowerCase(),
    );
  }

  void _playAll(BuildContext context, WidgetRef ref, List<dynamic> entries) async {
    final adapter = ref.read(authenticatedNasProvider);
    if (adapter == null) return;

    final tracks = entries.map<Track>((e) => Track(
          id: e.path,
          title: e.name.split('.').first,
          artist: 'Unknown Artist',
          album: 'Unknown Album',
          duration: Duration.zero,
          filePath: adapter.getStreamUrl(e.path),
          source: TrackSource.nas,
          format: e.name.split('.').last.toLowerCase(),
        )).toList();

    await ref.read(queueNotifierProvider.notifier).playTracks(tracks);
    if (context.mounted) {
      Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const NowPlayingScreen()));
    }
  }

  void _playFrom(
      BuildContext context, WidgetRef ref, List<dynamic> entries, int index) async {
    final adapter = ref.read(authenticatedNasProvider);
    if (adapter == null) return;

    final tracks = entries.map<Track>((e) => Track(
          id: e.path,
          title: e.name.split('.').first,
          artist: 'Unknown Artist',
          album: 'Unknown Album',
          duration: Duration.zero,
          filePath: adapter.getStreamUrl(e.path),
          source: TrackSource.nas,
          format: e.name.split('.').last.toLowerCase(),
        )).toList();

    await ref
        .read(queueNotifierProvider.notifier)
        .playTracks(tracks, startIndex: index);
    if (context.mounted) {
      Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const NowPlayingScreen()));
    }
  }
}

class _NasSelectionToolbar extends ConsumerWidget {
  final int selectedCount;
  final VoidCallback onClear;

  const _NasSelectionToolbar(
      {required this.selectedCount, required this.onClear});

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
            onPressed: () {},
          ),
        ],
      ),
    );
  }
}

class _NasManagerSheet extends ConsumerWidget {
  final VoidCallback onAdd;

  const _NasManagerSheet({required this.onAdd});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configs = ref.watch(nasConfigNotifierProvider);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text('NAS Devices',
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('Add'),
                  onPressed: () {
                    Navigator.pop(context);
                    onAdd();
                  },
                ),
              ],
            ),
            const Divider(),
            ...configs.map((c) => ListTile(
                  leading: Icon(
                    Icons.storage,
                    color: c.isActive
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                  title: Text(c.displayName),
                  subtitle: Text(c.baseUrl),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!c.isActive)
                        TextButton(
                          onPressed: () {
                            ref
                                .read(nasConfigNotifierProvider.notifier)
                                .setActive(c.id);
                            Navigator.pop(context);
                          },
                          child: const Text('Select'),
                        ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () {
                          ref
                              .read(nasConfigNotifierProvider.notifier)
                              .remove(c.id);
                        },
                      ),
                    ],
                  ),
                )),
          ],
        ),
      ),
    );
  }
}

class _AddNasDialog extends StatefulWidget {
  const _AddNasDialog();

  @override
  State<_AddNasDialog> createState() => _AddNasDialogState();
}

class _AddNasDialogState extends State<_AddNasDialog> {
  final _nameController = TextEditingController();
  final _urlController = TextEditingController(text: 'http://');

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add NAS Device'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: 'Name (optional)',
              hintText: 'My Synology',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _urlController,
            decoration: const InputDecoration(
              labelText: 'URL',
              hintText: 'http://192.168.1.100:5000',
            ),
            keyboardType: TextInputType.url,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final url = _urlController.text.trim();
            if (url.isEmpty || url == 'http://') return;
            Navigator.pop(context, (
              name: _nameController.text.trim(),
              url: url,
            ));
          },
          child: const Text('Add'),
        ),
      ],
    );
  }
}
