import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:metadata_god/metadata_god.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/track.dart';
import '../utils/filename_parser.dart';

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
  static Directory? _artCacheDir;

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
      // Untagged files often carry "Artist - Title" info in the name.
      final parsed = parseTrackFilename(filename);
      final title =
          meta?.title?.isNotEmpty == true ? meta!.title! : parsed.title;
      final artist = meta?.artist?.isNotEmpty == true
          ? meta!.artist!
          : parsed.artist ?? 'Unknown Artist';
      final album = meta?.album?.isNotEmpty == true
          ? meta!.album!
          : p.basename(p.dirname(file.path));
      final durationMs = meta?.duration?.inMilliseconds ?? 0;

      final artworkPath = await _cacheArtwork(meta?.picture, album, artist);
      final spec = await _sniffAudioSpec(file, ext);

      DateTime? modified;
      try {
        modified = file.lastModifiedSync();
      } catch (_) {}

      return Track(
        id: _uuid.v5(Namespace.url.value, file.path),
        title: title,
        artist: artist,
        album: album,
        duration: Duration(milliseconds: durationMs),
        filePath: file.path,
        source: TrackSource.local,
        format: ext,
        artworkPath: artworkPath,
        bitDepth: spec?.bitDepth,
        sampleRate: spec?.sampleRate,
        dateModified: modified,
      );
    } catch (_) {
      return null;
    }
  }

  // ── Album art extraction ────────────────────────────────────────────────────

  /// Write embedded artwork to a content-addressed cache file (one file per
  /// unique image, so a whole album shares a single cached cover).
  Future<String?> _cacheArtwork(
      Picture? picture, String album, String artist) async {
    final data = picture?.data;
    if (data == null || data.isEmpty) return null;

    try {
      _artCacheDir ??= await _initArtCache();
      final digest = crypto.md5.convert(data).toString();
      final ext = _extForMime(picture!.mimeType);
      final file = File(p.join(_artCacheDir!.path, '$digest$ext'));
      if (!file.existsSync()) {
        await file.writeAsBytes(data, flush: true);
      }
      return file.path;
    } catch (_) {
      return null;
    }
  }

  Future<Directory> _initArtCache() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'artwork'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  String _extForMime(String? mime) {
    switch (mime) {
      case 'image/png':
        return '.png';
      case 'image/webp':
        return '.webp';
      default:
        return '.jpg';
    }
  }

  // ── Audio spec sniffing (bit depth / sample rate) ───────────────────────────

  /// metadata_god does not expose bit depth / sample rate, but the design doc
  /// requires "FLAC 24-bit / 96kHz" style labels — parse the headers directly
  /// for the two formats where it is trivial and lossless-relevant.
  Future<({int? bitDepth, int? sampleRate})?> _sniffAudioSpec(
      File file, String ext) async {
    try {
      if (ext == 'flac') return _sniffFlac(file);
      if (ext == 'wav') return _sniffWav(file);
    } catch (_) {}
    return null;
  }

  Future<({int? bitDepth, int? sampleRate})?> _sniffFlac(File file) async {
    final raf = await file.open();
    try {
      final header = await raf.read(4);
      if (String.fromCharCodes(header) != 'fLaC') return null;
      // First metadata block is STREAMINFO: 4-byte block header + 34 bytes.
      final block = await raf.read(4 + 34);
      if (block.length < 38) return null;
      final d = Uint8List.fromList(block);
      // STREAMINFO bytes 10-12 (after block header): sample rate (20 bits),
      // channels (3 bits), bits-per-sample minus 1 (5 bits).
      final sampleRate = (d[14] << 12) | (d[15] << 4) | (d[16] >> 4);
      final bitsPerSample = (((d[16] & 0x01) << 4) | (d[17] >> 4)) + 1;
      if (sampleRate == 0) return null;
      return (bitDepth: bitsPerSample, sampleRate: sampleRate);
    } finally {
      await raf.close();
    }
  }

  Future<({int? bitDepth, int? sampleRate})?> _sniffWav(File file) async {
    final raf = await file.open();
    try {
      final header = await raf.read(12);
      if (header.length < 12) return null;
      final h = Uint8List.fromList(header);
      if (String.fromCharCodes(h.sublist(0, 4)) != 'RIFF' ||
          String.fromCharCodes(h.sublist(8, 12)) != 'WAVE') {
        return null;
      }

      // Walk RIFF chunks to find 'fmt ' — BWF/DAW exports often place
      // 'bext'/'JUNK' chunks before it, so a fixed offset is wrong.
      var offset = 12;
      final fileLength = await raf.length();
      for (var i = 0; i < 64 && offset + 8 <= fileLength; i++) {
        await raf.setPosition(offset);
        final chunkHeader = Uint8List.fromList(await raf.read(8));
        if (chunkHeader.length < 8) return null;
        final chunkId = String.fromCharCodes(chunkHeader.sublist(0, 4));
        final chunkSize =
            ByteData.sublistView(chunkHeader).getUint32(4, Endian.little);

        if (chunkId == 'fmt ') {
          final body = Uint8List.fromList(await raf.read(16));
          if (body.length < 16) return null;
          final bd = ByteData.sublistView(body);
          final sampleRate = bd.getUint32(4, Endian.little);
          final bitDepth = bd.getUint16(14, Endian.little);
          if (sampleRate == 0) return null;
          return (bitDepth: bitDepth, sampleRate: sampleRate);
        }
        // Chunks are word-aligned (odd sizes are padded by one byte).
        offset += 8 + chunkSize + (chunkSize.isOdd ? 1 : 0);
      }
      return null;
    } finally {
      await raf.close();
    }
  }
}
