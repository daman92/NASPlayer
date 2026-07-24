import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../models/nas_config.dart';
import '../models/track.dart';
import '../utils/filename_parser.dart';
import 'nas_adapter.dart';

const nasAudioExtensions = {
  'mp3', 'flac', 'aac', 'ogg', 'wav', 'm4a', 'alac', 'aiff', 'aif', 'opus',
};

/// Shared base for cookie-authenticated HTTP NAS adapters.
///
/// Owns the Dio client with the session cookies extracted from the login
/// WebView, and exposes [streamHeaders] so the audio player can attach the
/// same authenticated session to streaming requests (which bypass Dio).
abstract class HttpNasAdapter implements NasAdapter {
  @override
  final String baseUrl;

  final String cookies;
  final Map<String, String> extraHeaders;
  late final Dio dio;

  static const uuidGen = Uuid();

  HttpNasAdapter(
    this.baseUrl, {
    required this.cookies,
    this.extraHeaders = const {},
  }) {
    dio = Dio(BaseOptions(
      baseUrl: baseUrl,
      headers: {
        if (cookies.isNotEmpty) 'Cookie': cookies,
        ...extraHeaders,
      },
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
      validateStatus: (s) => s != null && s < 500,
    ));
  }

  @override
  Map<String, String> get streamHeaders => {
        if (cookies.isNotEmpty) 'Cookie': cookies,
        ...extraHeaders,
      };

  @override
  Future<void> prepare() async {}

  @override
  Future<List<Track>> listAudioFiles(String path) async {
    final entries = await listDirectory(path);
    final tracks = <Track>[];
    for (final entry in entries) {
      if (entry.isDirectory) {
        tracks.addAll(await listAudioFiles(entry.path));
      } else if (entry.isAudio) {
        tracks.add(entryToTrack(entry));
      }
    }
    return tracks;
  }

  @override
  Track entryToTrack(NasFileEntry entry) {
    final dot = entry.name.lastIndexOf('.');
    final ext = dot > 0 ? entry.name.substring(dot + 1).toLowerCase() : '';
    final baseName = dot > 0 ? entry.name.substring(0, dot) : entry.name;
    // NAS listings expose no tags — mine "Artist - Title" from the filename
    // and use the parent folder as the album.
    final parsed = parseTrackFilename(baseName);
    final parentSlash = entry.path.lastIndexOf('/');
    final parent = parentSlash > 0
        ? entry.path.substring(0, parentSlash).split('/').last
        : '';

    return Track(
      id: uuidGen.v5(Namespace.url.value, '$baseUrl${entry.path}'),
      title: parsed.title,
      artist: parsed.artist ?? 'Unknown Artist',
      album: parent.isNotEmpty ? parent : 'Unknown Album',
      duration: Duration.zero,
      filePath: getStreamUrl(entry.path),
      nasPath: entry.path,
      httpHeaders: streamHeaders,
      source: TrackSource.nas,
      format: ext,
      nasVendor: vendor.name,
      dateModified: entry.modified,
    );
  }

  /// URL-encode a NAS path segment-by-segment, preserving `/` separators.
  static String encodePath(String path) =>
      path.split('/').map(Uri.encodeComponent).join('/');
}
