import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/library_provider.dart';
import '../../providers/nas_provider.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentFolder = ref.watch(currentFolderProvider);
    final nasConfigs = ref.watch(nasConfigNotifierProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _SectionHeader('Library'),
          ListTile(
            leading: const Icon(Icons.folder),
            title: const Text('Music Folder'),
            subtitle: Text(
              currentFolder ?? 'Not set',
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: currentFolder != null
                ? IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: () => ref
                        .read(scanNotifierProvider.notifier)
                        .scanFolder(currentFolder),
                  )
                : null,
          ),
          const Divider(),
          _SectionHeader('NAS Connections'),
          ...nasConfigs.map((c) => ListTile(
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
                    if (c.isActive)
                      Chip(
                        label: const Text('Active'),
                        labelStyle: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        side: BorderSide(
                            color: Theme.of(context).colorScheme.primary),
                        backgroundColor: Theme.of(context)
                            .colorScheme
                            .primary
                            .withOpacity(0.1),
                        padding: EdgeInsets.zero,
                      )
                    else
                      TextButton(
                        onPressed: () => ref
                            .read(nasConfigNotifierProvider.notifier)
                            .setActive(c.id),
                        child: const Text('Select'),
                      ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _confirmDelete(context, ref, c.id, c.displayName),
                    ),
                  ],
                ),
              )),
          const Divider(),
          _SectionHeader('Playback'),
          ListTile(
            leading: const Icon(Icons.skip_previous),
            title: const Text('Previous track threshold'),
            subtitle: const Text(
                'Tap "previous" within 3 seconds to go to previous track'),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('Resume on launch'),
            subtitle: const Text('Continue from last position'),
            trailing: Switch(
              value: true,
              onChanged: (v) {},
            ),
          ),
          const Divider(),
          _SectionHeader('About'),
          ListTile(
            leading: const Icon(Icons.info),
            title: const Text('NASPlayer'),
            subtitle: const Text('Version 1.0.0 — NAS & Local Music Player'),
          ),
          ListTile(
            leading: const Icon(Icons.android),
            title: const Text('Android Auto'),
            subtitle: const Text(
                'Enabled — connect to Android Auto to use in-car controls'),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(
      BuildContext context, WidgetRef ref, String id, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove NAS'),
        content: Text('Remove "$name"?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      ref.read(nasConfigNotifierProvider.notifier).remove(id);
    }
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
            ),
      ),
    );
  }
}
