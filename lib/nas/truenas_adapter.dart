import '../models/nas_config.dart';
import 'http_nas_adapter.dart';
import 'nas_adapter.dart';

/// TrueNAS adapter (Phase 3 vendor, best-effort).
///
/// Uses the REST v2.0 `filesystem/listdir` endpoint. TrueNAS's browser
/// session is cookie-backed; users who instead configure an API key can
/// paste `Bearer <key>` support via the generic header mechanism later.
/// Browsing starts at `/mnt`, where storage pools are mounted.
class TrueNasAdapter extends HttpNasAdapter {
  TrueNasAdapter(super.baseUrl, {required super.cookies, super.extraHeaders});

  @override
  NasVendor get vendor => NasVendor.truenas;

  @override
  Future<NasVendor?> detect() async {
    try {
      final resp = await dio.get('/api/v2.0/system/info');
      // 200 = authenticated; 401 = endpoint exists but session lacks REST
      // access — either way the API shape identifies TrueNAS.
      if (resp.statusCode == 200 && resp.data is Map<String, dynamic>) {
        return NasVendor.truenas;
      }
      if (resp.statusCode == 401 &&
          resp.headers.value('content-type')?.contains('json') == true) {
        return NasVendor.truenas;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<NasFileEntry>> listDirectory(String path) async {
    final target = (path.isEmpty || path == '/') ? '/mnt' : path;

    // REST v2.0 contract: options belong inside 'query-options'.
    final resp = await dio.post(
      '/api/v2.0/filesystem/listdir',
      data: {
        'path': target,
        'query-filters': [],
        'query-options': {
          'order_by': ['name'],
        },
      },
    );

    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw const NasAuthException('TrueNAS session expired');
    }
    final data = resp.data;
    if (resp.statusCode != 200 || data is! List) {
      throw NasApiException(
          'TrueNAS listdir failed (${resp.statusCode}) for $target');
    }

    return data.map((f) {
      final info = f as Map<String, dynamic>;
      return NasFileEntry(
        name: info['name'] as String? ?? '',
        path: info['path'] as String? ?? '',
        isDirectory: info['type'] == 'DIRECTORY',
        size: (info['size'] as num?)?.toInt(),
        modified: _parseMtime(info['mtime']),
      );
    }).toList();
  }

  @override
  String getStreamUrl(String filePath) {
    return '$baseUrl/api/v2.0/filesystem/get'
        '?path=${Uri.encodeComponent(filePath)}';
  }

  DateTime? _parseMtime(dynamic value) {
    if (value is num) {
      return DateTime.fromMillisecondsSinceEpoch((value * 1000).toInt());
    }
    if (value is Map<String, dynamic>) {
      final secs = value[r'$date'];
      if (secs is num) return DateTime.fromMillisecondsSinceEpoch(secs.toInt());
    }
    return null;
  }
}
