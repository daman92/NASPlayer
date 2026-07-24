import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../models/track.dart';
import '../../providers/audio_provider.dart';
import '../../providers/equalizer_provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/nas_provider.dart';
import '../widgets/mini_player.dart';
import 'library_screen.dart';
import 'nas_browser_screen.dart';
import 'playlist_list_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _selectedIndex = 0;

  static const _screens = [
    LibraryScreen(),
    NasBrowserScreen(),
    PlaylistListScreen(),
    SearchScreen(),
    SettingsScreen(),
  ];

  @override
  void initState() {
    super.initState();
    // Startup restoration: last folder, NAS session, then playback resume.
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreOnLaunch());
  }

  Future<void> _restoreOnLaunch() async {
    final settings = ref.read(settingsServiceProvider);

    // Android 13+: the media notification needs POST_NOTIFICATIONS.
    await Permission.notification.request();

    // Instantiate the EQ notifier so persisted settings apply immediately.
    ref.read(equalizerProvider);

    // 1. Last local folder → the cached SQLite index is immediately visible.
    final lastFolder = await settings.getLastLocalFolder();
    if (lastFolder != null && ref.read(currentFolderProvider) == null) {
      ref.read(currentFolderProvider.notifier).state = lastFolder;
    }

    // 2. NAS session from stored cookies (design 8.2).
    await ref.read(nasSessionRestoreProvider.future);

    // 3. Resume last queue + position, paused (design 4.1, recommended).
    if (!await settings.getResumeEnabled()) return;
    final resume = await settings.getResumeState();
    if (resume == null || ref.read(queueNotifierProvider).isNotEmpty) return;
    // The handler may have already restored (Android Auto connected first).
    if (ref.read(audioHandlerProvider).queue.value.isNotEmpty) return;

    final adapter = ref.read(authenticatedNasProvider);
    final tracks = <Track>[];
    for (final t in resume.queue) {
      final source =
          t['source'] == 'nas' ? TrackSource.nas : TrackSource.local;
      final nasPath = t['nasPath'] as String?;

      // Re-resolve NAS stream URLs with the restored session; skip NAS
      // tracks when no session is available.
      String filePath = t['filePath'] as String? ?? '';
      Map<String, String>? headers;
      if (source == TrackSource.nas) {
        if (adapter == null || nasPath == null) continue;
        filePath = adapter.getStreamUrl(nasPath);
        headers = adapter.streamHeaders;
      }
      if (filePath.isEmpty) continue;

      tracks.add(Track(
        id: t['id'] as String? ?? filePath,
        title: t['title'] as String? ?? 'Unknown',
        artist: t['artist'] as String? ?? 'Unknown Artist',
        album: t['album'] as String? ?? 'Unknown Album',
        duration: Duration(milliseconds: (t['durationMs'] as int?) ?? 0),
        filePath: filePath,
        nasPath: nasPath,
        httpHeaders: headers,
        artworkPath: t['artworkPath'] as String?,
        source: source,
        format: t['format'] as String? ?? '',
      ));
    }
    if (tracks.isEmpty) return;

    final index = resume.index.clamp(0, tracks.length - 1);
    await ref.read(queueNotifierProvider.notifier).restoreTracks(
          tracks,
          startIndex: index,
          position: Duration(milliseconds: resume.positionMs),
        );
  }

  @override
  Widget build(BuildContext context) {
    // Gate the mini player on the HANDLER's queue: playback started from
    // Android Auto or voice search never touches queueNotifierProvider.
    final hasQueue = (ref.watch(queueProvider).value ?? []).isNotEmpty;

    // Surface playback errors (missing files, interrupted NAS streams).
    ref.listen(playbackErrorProvider, (_, next) {
      final message = next.value;
      if (message != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    });

    // Session-expiry prompt (design section 7).
    ref.listen(nasAuthExpiredProvider, (previous, expired) {
      if (expired && previous != true && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('NAS session expired'),
            action: SnackBarAction(
              label: 'Re-login',
              onPressed: () => setState(() => _selectedIndex = 1),
            ),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    });

    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: _screens,
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasQueue) const MiniPlayer(),
          NavigationBar(
            selectedIndex: _selectedIndex,
            onDestinationSelected: (i) => setState(() => _selectedIndex = i),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.folder_outlined),
                selectedIcon: Icon(Icons.folder),
                label: 'Library',
              ),
              NavigationDestination(
                icon: Icon(Icons.storage_outlined),
                selectedIcon: Icon(Icons.storage),
                label: 'NAS',
              ),
              NavigationDestination(
                icon: Icon(Icons.queue_music_outlined),
                selectedIcon: Icon(Icons.queue_music),
                label: 'Playlists',
              ),
              NavigationDestination(
                icon: Icon(Icons.search_outlined),
                selectedIcon: Icon(Icons.search),
                label: 'Search',
              ),
              NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: 'Settings',
              ),
            ],
          ),
        ],
      ),
    );
  }
}
