import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/nas_config.dart';
import '../../models/track.dart';
import '../../nas/nas_adapter.dart';
import '../../providers/audio_provider.dart';
import '../../providers/download_provider.dart';
import '../../providers/nas_provider.dart';
import '../../providers/playlist_provider.dart';
import '../widgets/add_to_playlist_sheet.dart';
import '../widgets/nas_config_dialog.dart';
import '../widgets/track_tile.dart';
import 'nas_login_screen.dart';
import 'now_playing_screen.dart';

/// Selection keys: plain entry path for tracks, 'dir:<path>' for folders,
/// so entire folders can be selected alongside individual tracks (design 5.1).
String dirSelectionKey(String path) => 'dir:$path';

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
    final authExpired = ref.watch(nasAuthExpiredProvider);

    if (configs.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('NAS')),
        body: _NoNasState(onAdd: () => _addNas(context, ref)),
      );
    }

    final activeConfig =
        ref.read(nasConfigNotifierProvider.notifier).activeConfig ??
            configs.first;

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
          if (adapter != null)
            _DownloadAction(
              onPin: () => _pinFolder(context, _currentPath),
            ),
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
      body: Column(
        children: [
          if (authExpired && adapter != null)
            MaterialBanner(
              content: const Text('NAS session expired — please log in again'),
              leading: const Icon(Icons.lock_clock),
              actions: [
                TextButton(
                  onPressed: () => _login(context, ref, activeConfig),
                  child: const Text('Re-login'),
                ),
              ],
            ),
          Expanded(
            child: adapter == null
                ? _LoginPrompt(
                    nasName: activeConfig.displayName,
                    onLogin: () => _login(context, ref, activeConfig),
                  )
                : _NasFolderView(
                    path: _currentPath,
                    onFolderTap: (path) =>
                        setState(() => _pathStack.add(path)),
                    onReLogin: () => _login(context, ref, activeConfig),
                  ),
          ),
        ],
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
      ref.invalidate(nasBrowseProvider);
      setState(() => _pathStack
        ..clear()
        ..add('/'));
    }
  }

  /// Pin an entire folder (recursively) for offline playback (Phase 2).
  Future<void> _pinFolder(BuildContext context, String path) async {
    final adapter = ref.read(authenticatedNasProvider);
    if (adapter == null) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('Collecting tracks to download...')),
    );

    List<Track> tracks;
    try {
      tracks = await adapter.listAudioFiles(path);
    } catch (_) {
      tracks = [];
    }
    final items = tracks
        .where((t) => t.nasPath != null)
        .map((t) => (nasPath: t.nasPath!, title: t.title))
        .toList();

    if (items.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No audio files found to download')),
      );
      return;
    }
    ref.read(downloadQueueProvider.notifier).enqueue(items);
    messenger.showSnackBar(
      SnackBar(content: Text('Queued ${items.length} tracks for offline')),
    );
  }

  Future<void> _addNas(BuildContext context, WidgetRef ref) async {
    final result = await NasConfigDialog.show(context);
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

/// Pin-folder app-bar button. While downloads are running it shows an
/// animated state and tapping it prompts to cancel them instead of piling
/// on another batch.
class _DownloadAction extends ConsumerWidget {
  final VoidCallback onPin;

  const _DownloadAction({required this.onPin});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloads = ref.watch(downloadQueueProvider);
    final active = downloads.values
        .where((d) => d.status == 'queued' || d.status == 'downloading')
        .length;

    if (active == 0) {
      return IconButton(
        icon: const Icon(Icons.download_for_offline_outlined),
        tooltip: 'Pin this folder for offline',
        onPressed: onPin,
      );
    }

    return IconButton(
      icon: Badge(
        label: Text('$active'),
        child: const Icon(Icons.downloading),
      ),
      tooltip: 'Downloads in progress — tap to cancel',
      onPressed: () async {
        final cancel = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Downloads in progress'),
            content: Text(
                '$active track${active == 1 ? ' is' : 's are'} still '
                'downloading. Cancel the remaining downloads?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Keep downloading'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Cancel downloads'),
              ),
            ],
          ),
        );
        if (cancel == true) {
          ref.read(downloadQueueProvider.notifier).cancelAll();
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Downloads cancelled')),
            );
          }
        }
      },
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
  final VoidCallback onReLogin;

  const _NasFolderView({
    required this.path,
    required this.onFolderTap,
    required this.onReLogin,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entriesAsync = ref.watch(nasBrowseProvider(path));
    final selected = ref.watch(nasSelectionProvider);
    final isSelecting = selected.isNotEmpty;

    return entriesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) {
        final isAuth = e is NasAuthException;
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(isAuth ? Icons.lock_clock : Icons.error_outline,
                  size: 48, color: isAuth ? Colors.amber : Colors.red),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  isAuth ? 'Your NAS session has expired.' : 'Error: $e',
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 16),
              if (isAuth)
                FilledButton.icon(
                  icon: const Icon(Icons.login),
                  label: const Text('Log in again'),
                  onPressed: onReLogin,
                )
              else
                ElevatedButton(
                  onPressed: () => ref.invalidate(nasBrowseProvider(path)),
                  child: const Text('Retry'),
                ),
            ],
          ),
        );
      },
      data: (entries) {
        if (entries.isEmpty) {
          return const Center(child: Text('Empty folder'));
        }

        final dirs = entries.where((e) => e.isDirectory).toList();
        final audioFiles = entries.where((e) => e.isAudio).toList();

        return Column(
          children: [
            if (isSelecting)
              _NasSelectionToolbar(
                selectedCount: selected.length,
                currentEntries: entries,
                onClear: () => ref.read(nasSelectionProvider.notifier).clear(),
              ),
            Expanded(
              child: ListView(
                children: [
                  if (dirs.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Row(
                        children: [
                          Text('Folders',
                              style: Theme.of(context).textTheme.bodySmall),
                          const Spacer(),
                          if (audioFiles.isEmpty)
                            TextButton.icon(
                              icon: const Icon(Icons.playlist_play, size: 16),
                              label: const Text('Play All'),
                              onPressed: () =>
                                  _playAllRecursive(context, ref, path),
                            ),
                        ],
                      ),
                    ),
                    ...dirs.map((dir) => _NasDirTile(
                          dir: dir,
                          depth: 0,
                          isSelecting: isSelecting,
                          onNavigate: onFolderTap,
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
                            onPressed: () =>
                                _playAllRecursive(context, ref, path),
                          ),
                        ],
                      ),
                    ),
                    ...audioFiles.asMap().entries.map((e) {
                      final entry = e.value;
                      return _NasTrackTile(
                        entry: entry,
                        isSelected: selected.contains(entry.path),
                        isSelecting: isSelecting,
                        onPlay: () =>
                            _playFrom(context, ref, audioFiles, e.key),
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

  /// Design 4.5: selecting a folder queues its audio AND all subfolders.
  Future<void> _playAllRecursive(
      BuildContext context, WidgetRef ref, String folderPath) async {
    final adapter = ref.read(authenticatedNasProvider);
    if (adapter == null) return;

    final navigator = Navigator.of(context);
    var dialogOpen = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 20),
            Expanded(child: Text('Collecting tracks from subfolders...')),
          ],
        ),
      ),
    ).then((_) => dialogOpen = false);

    List<Track> tracks;
    try {
      tracks = await adapter.listAudioFiles(folderPath);
    } on NasAuthException {
      ref.read(nasAuthExpiredProvider.notifier).state = true;
      tracks = [];
    } catch (_) {
      tracks = [];
    }

    if (dialogOpen) navigator.pop();

    if (tracks.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No playable tracks found')),
        );
      }
      return;
    }

    await ref.read(queueNotifierProvider.notifier).playTracks(tracks);
    if (context.mounted) {
      Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const NowPlayingScreen()));
    }
  }

  void _playFrom(BuildContext context, WidgetRef ref,
      List<NasFileEntry> entries, int index) async {
    final adapter = ref.read(authenticatedNasProvider);
    if (adapter == null) return;

    final tracks = entries.map(adapter.entryToTrack).toList();
    await ref
        .read(queueNotifierProvider.notifier)
        .playTracks(tracks, startIndex: index);
    if (context.mounted) {
      Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const NowPlayingScreen()));
    }
  }
}

/// Folder row: tap to navigate, long-press (or checkbox while selecting) to
/// select the whole folder, expand icon to browse subfolder contents inline
/// without losing the current selection (design 5.1).
class _NasDirTile extends ConsumerStatefulWidget {
  final NasFileEntry dir;
  final int depth;
  final bool isSelecting;
  final void Function(String) onNavigate;

  const _NasDirTile({
    required this.dir,
    required this.depth,
    required this.isSelecting,
    required this.onNavigate,
  });

  @override
  ConsumerState<_NasDirTile> createState() => _NasDirTileState();
}

class _NasDirTileState extends ConsumerState<_NasDirTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final selected = ref.watch(nasSelectionProvider);
    final key = dirSelectionKey(widget.dir.path);
    final isSelected = selected.contains(key);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding:
              EdgeInsets.only(left: 16.0 + widget.depth * 20, right: 4),
          leading: widget.isSelecting
              ? Checkbox(
                  value: isSelected,
                  onChanged: (_) =>
                      ref.read(nasSelectionProvider.notifier).toggle(key),
                )
              : Icon(isSelected ? Icons.folder_special : Icons.folder),
          title: Text(widget.dir.name),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                tooltip: 'Expand inline',
                onPressed: () => setState(() => _expanded = !_expanded),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
          onTap: () {
            if (widget.isSelecting) {
              ref.read(nasSelectionProvider.notifier).toggle(key);
            } else {
              widget.onNavigate(widget.dir.path);
            }
          },
          onLongPress: () => ref.read(nasSelectionProvider.notifier).toggle(key),
        ),
        if (_expanded)
          _InlineFolderContents(
            path: widget.dir.path,
            depth: widget.depth + 1,
            onNavigate: widget.onNavigate,
          ),
      ],
    );
  }
}

class _InlineFolderContents extends ConsumerWidget {
  final String path;
  final int depth;
  final void Function(String) onNavigate;

  const _InlineFolderContents({
    required this.path,
    required this.depth,
    required this.onNavigate,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entriesAsync = ref.watch(nasBrowseProvider(path));
    final selected = ref.watch(nasSelectionProvider);
    final isSelecting = selected.isNotEmpty;

    return entriesAsync.when(
      loading: () => Padding(
        padding: EdgeInsets.only(left: 32.0 + depth * 20, top: 8, bottom: 8),
        child: const Row(children: [
          SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 8),
          Text('Loading...'),
        ]),
      ),
      error: (e, _) => Padding(
        padding: EdgeInsets.only(left: 32.0 + depth * 20),
        child: Text('Error: $e',
            style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ),
      data: (entries) {
        final dirs = entries.where((e) => e.isDirectory).toList();
        final audio = entries.where((e) => e.isAudio).toList();
        if (dirs.isEmpty && audio.isEmpty) {
          return Padding(
            padding:
                EdgeInsets.only(left: 32.0 + depth * 20, top: 4, bottom: 4),
            child: const Align(
              alignment: Alignment.centerLeft,
              child: Text('Empty folder'),
            ),
          );
        }
        return Column(
          children: [
            ...dirs.map((d) => _NasDirTile(
                  dir: d,
                  depth: depth,
                  isSelecting: isSelecting,
                  onNavigate: onNavigate,
                )),
            ...audio.asMap().entries.map((e) => Padding(
                  padding: EdgeInsets.only(left: depth * 20.0),
                  child: _NasTrackTile(
                    entry: e.value,
                    isSelected: selected.contains(e.value.path),
                    isSelecting: isSelecting,
                    onPlay: () async {
                      final adapter = ref.read(authenticatedNasProvider);
                      if (adapter == null) return;
                      // Queue the whole subfolder so playback continues to
                      // the next song, starting at the tapped track.
                      await ref.read(queueNotifierProvider.notifier).playTracks(
                            audio.map(adapter.entryToTrack).toList(),
                            startIndex: e.key,
                          );
                    },
                  ),
                )),
          ],
        );
      },
    );
  }
}

class _NasTrackTile extends ConsumerWidget {
  final NasFileEntry entry;
  final bool isSelected;
  final bool isSelecting;
  final VoidCallback onPlay;

  const _NasTrackTile({
    required this.entry,
    required this.isSelected,
    required this.isSelecting,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final adapter = ref.watch(authenticatedNasProvider);
    final track = adapter?.entryToTrack(entry) ??
        Track(
          id: entry.path,
          title: entry.name,
          artist: 'Unknown Artist',
          album: 'Unknown Album',
          duration: Duration.zero,
          filePath: entry.path,
          source: TrackSource.nas,
        );

    return TrackTile(
      track: track,
      isSelected: isSelected,
      isSelecting: isSelecting,
      onTap: () {
        if (isSelecting) {
          ref.read(nasSelectionProvider.notifier).toggle(entry.path);
        } else {
          onPlay();
        }
      },
      onLongPress: () =>
          ref.read(nasSelectionProvider.notifier).toggle(entry.path),
    );
  }
}

class _NasSelectionToolbar extends ConsumerWidget {
  final int selectedCount;
  final List<NasFileEntry> currentEntries;
  final VoidCallback onClear;

  const _NasSelectionToolbar({
    required this.selectedCount,
    required this.currentEntries,
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
            icon: const Icon(Icons.download_for_offline_outlined),
            label: const Text('Pin'),
            onPressed: () => _pinSelection(context, ref),
          ),
          TextButton.icon(
            icon: const Icon(Icons.playlist_add),
            label: const Text('Add to Playlist'),
            onPressed: () => _addToPlaylist(context, ref),
          ),
        ],
      ),
    );
  }

  /// Resolve the selection (tracks + entire folders, recursively) to Tracks.
  Future<List<Track>> _resolveSelection(WidgetRef ref) async {
    final adapter = ref.read(authenticatedNasProvider);
    if (adapter == null) return [];
    final selected = ref.read(nasSelectionProvider);

    final tracks = <Track>[];
    final seenPaths = <String>{};

    for (final key in selected) {
      if (key.startsWith('dir:')) {
        final folder = key.substring(4);
        try {
          for (final t in await adapter.listAudioFiles(folder)) {
            if (t.nasPath != null && seenPaths.add(t.nasPath!)) {
              tracks.add(t);
            }
          }
        } catch (_) {}
      }
    }

    final byPath = {for (final e in currentEntries) e.path: e};
    for (final key in selected) {
      if (key.startsWith('dir:')) continue;
      if (!seenPaths.add(key)) continue;
      final entry = byPath[key];
      if (entry != null) {
        tracks.add(adapter.entryToTrack(entry));
      } else {
        // Selected inside an inline-expanded subfolder: build from the path.
        tracks.add(adapter.entryToTrack(NasFileEntry(
          name: key.split('/').last,
          path: key,
          isDirectory: false,
        )));
      }
    }

    return tracks;
  }

  void _addToPlaylist(BuildContext context, WidgetRef ref) async {
    final tracks = await _resolveSelection(ref);
    if (tracks.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nothing selected to add')),
        );
      }
      return;
    }
    if (context.mounted) {
      await AddToPlaylistSheet.show(context, tracks, onDone: onClear);
    }
  }

  void _pinSelection(BuildContext context, WidgetRef ref) async {
    final tracks = await _resolveSelection(ref);
    final items = tracks
        .where((t) => t.nasPath != null)
        .map((t) => (nasPath: t.nasPath!, title: t.title))
        .toList();
    if (items.isEmpty) return;
    ref.read(downloadQueueProvider.notifier).enqueue(items);
    onClear();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Queued ${items.length} tracks for offline')),
      );
    }
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
                  subtitle: Text('${c.baseUrl} — ${c.vendor.name}'),
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
                        icon: const Icon(Icons.edit_outlined),
                        tooltip: 'Edit name / URL',
                        onPressed: () => _editConfig(context, ref, c),
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

  Future<void> _editConfig(
      BuildContext context, WidgetRef ref, NasConfig config) async {
    final result = await NasConfigDialog.show(
      context,
      initialName: config.name,
      initialUrl: config.baseUrl,
    );
    if (result == null) return;

    final urlChanged = await ref
        .read(nasConfigNotifierProvider.notifier)
        .updateConfig(config.id, name: result.name, baseUrl: result.url);

    // A changed address invalidates the stored session — force a re-login.
    if (urlChanged && config.isActive) {
      ref.read(authenticatedNasProvider.notifier).clear();
      ref.read(nasAuthExpiredProvider.notifier).state = false;
    }
  }
}

