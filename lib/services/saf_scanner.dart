import 'dart:io';

import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../models/track.dart';
import '../utils/filename_parser.dart';

const _audioExtensions = {
  'mp3', 'flac', 'aac', 'ogg', 'wav', 'm4a', 'alac', 'aiff', 'aif', 'opus',
};

/// Scans a Storage Access Framework document tree (Google Drive, USB, or any
/// other DocumentsProvider) via the platform channel. Files are addressed by
/// `content://` URIs, which ExoPlayer streams natively.
///
/// ID3 metadata cannot be read through a DocumentsProvider without
/// downloading each file, so titles come from filenames and the parent
/// folder name is used as the album (the usual folder-per-album convention).
class SafScanner {
  static const _channel = MethodChannel('nasplayer/saf');
  static const _uuid = Uuid();

  /// Open the system folder picker (shows Drive and other cloud providers).
  /// Returns the granted tree URI, or null if cancelled.
  Future<String?> pickTree() async {
    return _channel.invokeMethod<String>('pickTree');
  }

  /// For trees on device storage, resolve the SAF URI to a real filesystem
  /// path so the metadata-rich dart:io scanner can be used instead.
  String? resolveToFilesystemPath(String treeUri) {
    final uri = Uri.tryParse(treeUri);
    if (uri == null || uri.authority != 'com.android.externalstorage.documents') {
      return null;
    }
    // content://com.android.externalstorage.documents/tree/primary%3AMusic
    // → pathSegments ['tree', 'primary:Music']
    if (uri.pathSegments.length < 2) return null;
    final docId = uri.pathSegments[1];
    final colon = docId.indexOf(':');
    if (colon < 0) return null;
    final volume = docId.substring(0, colon);
    final relative = docId.substring(colon + 1);
    final base =
        volume == 'primary' ? '/storage/emulated/0' : '/storage/$volume';
    final path = relative.isEmpty ? base : '$base/$relative';
    return Directory(path).existsSync() ? path : null;
  }

  /// Recursively list the tree and convert audio files to Tracks.
  Future<List<Track>> scanTree(String treeUri) async {
    final raw =
        await _channel.invokeMethod<List<dynamic>>('listTree', {'uri': treeUri});
    if (raw == null) return [];

    final tracks = <Track>[];
    for (final item in raw) {
      final entry = Map<Object?, Object?>.from(item as Map);
      final name = entry['name'] as String? ?? '';
      final uri = entry['uri'] as String? ?? '';
      if (name.isEmpty || uri.isEmpty) continue;

      final dot = name.lastIndexOf('.');
      final ext = dot > 0 ? name.substring(dot + 1).toLowerCase() : '';
      if (!_audioExtensions.contains(ext)) continue;

      final baseName = dot > 0 ? name.substring(0, dot) : name;
      final parsed = parseTrackFilename(baseName);
      final relativePath = entry['relativePath'] as String? ?? name;
      final relParts = relativePath.split('/');
      final album =
          relParts.length > 1 ? relParts[relParts.length - 2] : 'Unknown Album';
      final modified = entry['modified'] as int?;

      tracks.add(Track(
        id: _uuid.v5(Namespace.url.value, uri),
        title: parsed.title,
        artist: parsed.artist ?? 'Unknown Artist',
        album: album,
        duration: Duration.zero,
        filePath: uri,
        source: TrackSource.local,
        format: ext,
        dateModified: modified != null
            ? DateTime.fromMillisecondsSinceEpoch(modified)
            : null,
      ));
    }

    tracks.sort((a, b) => a.filePath.compareTo(b.filePath));
    return tracks;
  }
}
