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

  static String formatAudioSpec(String format, int? bitDepth, int? sampleRate) {
    final parts = <String>[];
    if (format.isNotEmpty) parts.add(format.toUpperCase());
    if (bitDepth != null) parts.add('${bitDepth}-bit');
    if (sampleRate != null) {
      final khz = sampleRate / 1000;
      parts.add('${khz % 1 == 0 ? khz.toInt() : khz.toStringAsFixed(1)}kHz');
    }
    return parts.join(' / ');
  }
}
