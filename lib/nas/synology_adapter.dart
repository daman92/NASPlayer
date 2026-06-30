import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../models/nas_config.dart';
import '../models/track.dart';
import 'nas_adapter.dart';

const _audioExtensions = {
  'mp3', 'flac', 'aac', 'ogg', 'wav', 'm4a', 'alac', 'aiff', 'opus',
};

class SynologyAdapter implements NasAdapter {
  @override
  final String baseUrl;

  final Dio _dio;
  static const _uuid = Uuid();

  SynologyAdapter(this.baseUrl, {required String cookies})
      : _dio = Dio(BaseOptions(
          baseUrl: baseUrl,
          headers: {'Cookie': cookies},
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 30),
        ));

  @override
  NasVendor get vendor => NasVendor.synology;

  // ── Synology FileStation REST API ──────────────────────────────────────────

  @override
  Future<NasVendor?> detect() async {
    try {
      final resp = await _dio.get(
        '/webapi/entry.cgi',
        queryParameters: {
          'api': 'SYNO.API.Info',
          'version': '1',
          'method': 'query',
          'query': 'SYNO.FileStation.List',
        },
      );
      final data = resp.data as Map<String, dynamic>?;
      return data?['success'] == true ? NasVendor.synology : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<NasFileEntry>> listDirectory(String path) async {
    try {
      final resp = await _dio.get(
        '/webapi/entry.cgi',
        queryParameters: {
          'api': 'SYNO.FileStation.List',
          'version': '2',
          'method': 'list',
          'folder_path': path,
          'additional': '["real_path","size","time","type"]',
          'sort_by': 'name',
          'sort_direction': 'ASC',
          'limit': 5000,
        },
      );

      final data = resp.data as Map<String, dynamic>;
      if (data['success'] != true) return [];

      final files = data['data']?['files'] as List? ?? [];
      return files.map((f) {
        final info = f as Map<String, dynamic>;
        final additional = info['additional'] as Map<String, dynamic>? ?? {};
        return NasFileEntry(
          name: info['name'] as String? ?? '',
          path: info['path'] as String? ?? '',
          isDirectory: info['isdir'] as bool? ?? false,
          size: additional['size'] as int?,
          modified: _parseTime(additional['time']?['mtime']),
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<List<Track>> listAudioFiles(String folderPath) async {
    final entries = await listDirectory(folderPath);
    final tracks = <Track>[];

    for (final entry in entries) {
      if (entry.isDirectory) {
        final subTracks = await listAudioFiles(entry.path);
        tracks.addAll(subTracks);
      } else if (entry.isAudio) {
        tracks.add(_entryToTrack(entry));
      }
    }

    return tracks;
  }

  @override
  String getStreamUrl(String filePath) {
    final encoded = Uri.encodeComponent(filePath);
    return '$baseUrl/webapi/entry.cgi?api=SYNO.FileStation.Download'
        '&version=2&method=download&path=$encoded&mode=open';
  }

  // ── Internal helpers ───────────────────────────────────────────────────────

  Track _entryToTrack(NasFileEntry entry) {
    final nameParts = entry.name.split('.');
    final ext = nameParts.length > 1 ? nameParts.last.toLowerCase() : '';
    final title = nameParts.length > 1
        ? nameParts.sublist(0, nameParts.length - 1).join('.')
        : entry.name;

    return Track(
      id: _uuid.v5(Uuid.NAMESPACE_URL, entry.path),
      title: title,
      artist: 'Unknown Artist',
      album: 'Unknown Album',
      duration: Duration.zero,
      filePath: getStreamUrl(entry.path),
      source: TrackSource.nas,
      format: ext,
      nasVendor: 'synology',
    );
  }

  DateTime? _parseTime(dynamic value) {
    if (value == null) return null;
    try {
      return DateTime.fromMillisecondsSinceEpoch((value as int) * 1000);
    } catch (_) {
      return null;
    }
  }
}
