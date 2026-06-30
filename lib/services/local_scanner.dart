import 'dart:io';

import 'package:metadata_god/metadata_god.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/track.dart';

const _audioExtensions = {
  'mp3', 'flac', 'aac', 'ogg', 'wav', 'm4a', 'alac', 'aiff', 'aif', 'opus',
};

class ScanProgress {
  final int scanned;
  final int found;
  final String currentPath;

  const ScanProgress(this.scanned, this.found, this.currentPath);
}

class LocalScanner {
  static const _uuid = Uuid();

  Stream<ScanProgress> scan(
    String folderPath, {
    void Function(Track)? onTrackFound,
  }) async* {
    final dir = Directory(folderPath);
    if (!dir.existsSync()) return;

    final files = await _collectAudioFiles(dir);
    int scanned = 0;
    int found = 0;

    for (final file in files) {
      scanned++;
      yield ScanProgress(scanned, found, file.path);

      final track = await _readTrack(file);
      if (track != null) {
        found++;
        onTrackFound?.call(track);
      }
    }
  }

  Future<List<Track>> scanSync(String folderPath) async {
    final dir = Directory(folderPath);
    if (!dir.existsSync()) return [];

    final files = await _collectAudioFiles(dir);
    final tracks = <Track>[];

    for (final file in files) {
      final track = await _readTrack(file);
      if (track != null) tracks.add(track);
    }

    return tracks;
  }

  Future<List<File>> _collectAudioFiles(Directory dir) async {
    final files = <File>[];
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        final ext = p.extension(entity.path).replaceFirst('.', '').toLowerCase();
        if (_audioExtensions.contains(ext)) {
          files.add(entity);
        }
      }
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  Future<Track?> _readTrack(File file) async {
    try {
      final ext = p.extension(file.path).replaceFirst('.', '').toLowerCase();
      Metadata? meta;

      try {
        meta = await MetadataGod.readMetadata(file: file.path);
      } catch (_) {
        // fallback: no metadata
      }

      final filename = p.basenameWithoutExtension(file.path);
      final title = meta?.title?.isNotEmpty == true ? meta!.title! : filename;
      final artist = meta?.artist ?? 'Unknown Artist';
      final album = meta?.album ?? 'Unknown Album';
      final durationMs = meta?.durationMs?.toInt() ?? 0;

      return Track(
        id: _uuid.v5(Uuid.NAMESPACE_URL, file.path),
        title: title,
        artist: artist,
        album: album,
        duration: Duration(milliseconds: durationMs),
        filePath: file.path,
        source: TrackSource.local,
        format: ext,
        sampleRate: meta?.sampleRate,
        bitrate: meta?.bitrate?.toInt(),
      );
    } catch (_) {
      return null;
    }
  }
}
