import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/nas_config.dart';
import '../../providers/library_provider.dart';
import '../../providers/nas_provider.dart';
import '../../utils/format_utils.dart';
import '../widgets/nas_config_dialog.dart';
import 'downloads_screen.dart';
import 'equalizer_screen.dart';
import 'history_screen.dart';

/// Resume-on-launch toggle backed by secure storage.
final resumeEnabledProvider = FutureProvider<bool>((ref) {
  return ref.watch(settingsServiceProvider).getResumeEnabled();
});

final nasAutoRefreshProvider = FutureProvider<bool>((ref) {
  return ref.watch(settingsServiceProvider).getNasAutoRefresh();
});

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentFolder = ref.watch(currentFolderProvider);
    final nasConfigs = ref.watch(nasConfigNotifierProvider);
    final resumeEnabled = ref.watch(resumeEnabledProvider).value ?? true;
    final nasAutoRefresh = ref.watch(nasAutoRefreshProvider).value ?? true;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const _SectionHeader('Library'),
          ListTile(
            leading: const Icon(Icons.folder),
            title: const Text('Music Folder'),
            subtitle: Text(
              currentFolder != null
                  ? FormatUtils.displayFolder(currentFolder)
                  : 'Not set',
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: currentFolder != null
                ? IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Rescan',
                    onPressed: () => ref
                        .read(scanNotifierProvider.notifier)
                        .scanFolder(currentFolder),
                  )
                : null,
          ),
          ListTile(
            leading: const Icon(Icons.history),
            title: const Text('Play History'),
            subtitle: const Text('Recently played and most played tracks'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const HistoryScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.download_for_offline),
            title: const Text('Offline Downloads'),
            subtitle: const Text('Manage pinned NAS tracks'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const DownloadsScreen()),
            ),
          ),
          const Divider(),
          const _SectionHeader('NAS Connections'),
          ...nasConfigs.map((c) => _NasConfigTile(config: c)),
          SwitchListTile(
            secondary: const Icon(Icons.sync),
            title: const Text('Refresh NAS index on launch'),
            subtitle:
                const Text('Re-cache browsed NAS folders when the app starts'),
            value: nasAutoRefresh,
            onChanged: (v) async {
              await ref.read(settingsServiceProvider).setNasAutoRefresh(v);
              ref.invalidate(nasAutoRefreshProvider);
            },
          ),
          const Divider(),
          const _SectionHeader('Playback'),
          SwitchListTile(
            secondary: const Icon(Icons.play_circle_outline),
            title: const Text('Resume on launch'),
            subtitle: const Text('Restore the last queue and position'),
            value: resumeEnabled,
            onChanged: (v) async {
              await ref.read(settingsServiceProvider).setResumeEnabled(v);
              ref.invalidate(resumeEnabledProvider);
            },
          ),
          ListTile(
            leading: const Icon(Icons.equalizer),
            title: const Text('Equalizer'),
            subtitle: const Text('EQ bands and loudness enhancement'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const EqualizerScreen()),
            ),
          ),
          const ListTile(
            leading: Icon(Icons.skip_previous),
            title: Text('Previous track threshold'),
            subtitle: Text(
                'Tapping "previous" after 3 seconds restarts the current track'),
          ),
          const Divider(),
          const _SectionHeader('About'),
          const ListTile(
            leading: Icon(Icons.info),
            title: Text('NASPlayer'),
            subtitle: Text('Version 1.0.0 — NAS & Local Music Player'),
          ),
          const ListTile(
            leading: Icon(Icons.android),
            title: Text('Android Auto'),
            subtitle: Text(
                'Enabled — connect to Android Auto to use in-car controls'),
          ),
        ],
      ),
    );
  }
}

class _NasConfigTile extends ConsumerWidget {
  final NasConfig config;

  const _NasConfigTile({required this.config});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: Icon(
        Icons.storage,
        color: config.isActive ? Theme.of(context).colorScheme.primary : null,
      ),
      title: Text(config.displayName),
      subtitle: Text('${config.baseUrl} — ${config.vendor.name}'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (config.isActive)
            Chip(
              label: const Text('Active'),
              labelStyle: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.primary,
              ),
              side: BorderSide(color: Theme.of(context).colorScheme.primary),
              backgroundColor:
                  Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
              padding: EdgeInsets.zero,
            )
          else
            TextButton(
              onPressed: () => ref
                  .read(nasConfigNotifierProvider.notifier)
                  .setActive(config.id),
              child: const Text('Select'),
            ),
          PopupMenuButton<String>(
            onSelected: (action) {
              switch (action) {
                case 'edit':
                  _editConfig(context, ref);
                case 'vendor':
                  _pickVendor(context, ref);
                case 'delete':
                  _confirmDelete(context, ref);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'edit',
                child: ListTile(
                  leading: Icon(Icons.edit),
                  title: Text('Edit name / URL'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'vendor',
                child: ListTile(
                  leading: Icon(Icons.dns),
                  title: Text('Set vendor'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'delete',
                child: ListTile(
                  leading: Icon(Icons.delete_outline),
                  title: Text('Remove'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _editConfig(BuildContext context, WidgetRef ref) async {
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

  /// Manual vendor override (design 8.2: "Users can override detection
  /// manually in settings").
  void _pickVendor(BuildContext context, WidgetRef ref) async {
    final vendor = await showDialog<NasVendor>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('NAS vendor for ${config.displayName}'),
        children: [
          for (final v in const [
            NasVendor.synology,
            NasVendor.qnap,
            NasVendor.nextcloud,
            NasVendor.truenas,
            NasVendor.generic,
          ])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, v),
              child: Row(
                children: [
                  Icon(
                    config.vendor == v
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Text(v.name),
                ],
              ),
            ),
        ],
      ),
    );

    if (vendor != null) {
      await ref
          .read(nasConfigNotifierProvider.notifier)
          .updateVendor(config.id, vendor);
      // Rebuild the live adapter if this config is active.
      if (config.isActive) {
        await ref
            .read(authenticatedNasProvider.notifier)
            .rebuildForVendor(config.id, config.baseUrl, vendor);
      }
    }
  }

  void _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove NAS'),
        content: Text('Remove "${config.displayName}"?'),
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
      ref.read(nasConfigNotifierProvider.notifier).remove(config.id);
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
