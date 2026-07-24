class FormatUtils {
  static String formatDuration(Duration duration) {
    final h = duration.inHours;
    final m = duration.inMinutes.remainder(60);
    final s = duration.inSeconds.remainder(60);

    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  static String formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// Human-readable label for a library folder: real paths pass through,
  /// SAF content URIs (Google Drive etc.) get a friendly name instead of
  /// the opaque URI.
  static String displayFolder(String path) {
    if (!path.startsWith('content://')) return path;
    final uri = Uri.tryParse(path);
    if (uri == null) return 'Cloud folder';

    final authority = uri.authority;
    final provider = authority.contains('google') && authority.contains('docs')
        ? 'Google Drive'
        : authority == 'com.android.externalstorage.documents'
            ? 'Device storage'
            : 'Cloud folder';

    if (uri.pathSegments.length >= 2) {
      final docId = uri.pathSegments[1];
      final colon = docId.indexOf(':');
      final label = colon >= 0 ? docId.substring(colon + 1) : docId;
      // Opaque provider ids (Drive) aren't meaningful — show just the
      // provider name; readable ones (primary:Music) show the folder.
      final readable = label.isNotEmpty &&
          label.length < 40 &&
          !RegExp(r'^[A-Za-z0-9_=-]{16,}$').hasMatch(label);
      if (readable) return '$provider: $label';
    }
    return provider;
  }

  static String formatAudioSpec(String format, int? bitDepth, int? sampleRate) {
    final parts = <String>[];
    if (format.isNotEmpty) parts.add(format.toUpperCase());
    if (bitDepth != null) parts.add('$bitDepth-bit');
    if (sampleRate != null) {
      final khz = sampleRate / 1000;
      parts.add('${khz % 1 == 0 ? khz.toInt() : khz.toStringAsFixed(1)}kHz');
    }
    return parts.join(' / ');
  }
}
