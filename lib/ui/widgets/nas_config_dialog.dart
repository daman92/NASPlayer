import 'package:flutter/material.dart';

/// Add/edit dialog for a NAS device's name and URL.
///
/// Returns `(name: ..., url: ...)` on save, or null on cancel.
class NasConfigDialog extends StatefulWidget {
  final String? initialName;
  final String? initialUrl;

  const NasConfigDialog({super.key, this.initialName, this.initialUrl});

  bool get isEdit => initialUrl != null;

  static Future<({String name, String url})?> show(
    BuildContext context, {
    String? initialName,
    String? initialUrl,
  }) {
    return showDialog<({String name, String url})>(
      context: context,
      builder: (_) => NasConfigDialog(
        initialName: initialName,
        initialUrl: initialUrl,
      ),
    );
  }

  @override
  State<NasConfigDialog> createState() => _NasConfigDialogState();
}

class _NasConfigDialogState extends State<NasConfigDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _urlController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName ?? '');
    _urlController =
        TextEditingController(text: widget.initialUrl ?? 'http://');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.isEdit ? 'Edit NAS Device' : 'Add NAS Device'),
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
            var url = _urlController.text.trim();
            if (url.isEmpty || url == 'http://' || url == 'https://') return;
            // Normalize: scheme required, no trailing slash.
            if (!url.startsWith('http://') && !url.startsWith('https://')) {
              url = 'http://$url';
            }
            while (url.endsWith('/')) {
              url = url.substring(0, url.length - 1);
            }
            Navigator.pop(context, (
              name: _nameController.text.trim(),
              url: url,
            ));
          },
          child: Text(widget.isEdit ? 'Save' : 'Add'),
        ),
      ],
    );
  }
}
