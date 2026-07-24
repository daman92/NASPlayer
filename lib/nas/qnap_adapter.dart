import 'dart:convert';

import '../models/nas_config.dart';
import 'http_nas_adapter.dart';
import 'nas_adapter.dart';

/// QNAP QTS File Station adapter (Phase 2 vendor).
///
/// Uses the File Station `utilRequest.cgi` API. QTS authenticates API calls
/// with a `sid` token; the web UI stores it in the `NAS_SID` cookie, which we
/// pick up from the WebView session and also pass as a query parameter.
class QnapAdapter extends HttpNasAdapter {
  final String? _sid;

  QnapAdapter(super.baseUrl, {required super.cookies, super.extraHeaders})
      : _sid = _sidFromCookies(cookies);

  @override
  NasVendor get vendor => NasVendor.qnap;

  static const _pageSize = 1000;

  static String? _sidFromCookies(String cookies) {
    for (final part in cookies.split(';')) {
      final kv = part.trim().split('=');
      if (kv.length == 2 &&
          {'nas_sid', 'nas_1_sid', 'qtoken'}.contains(kv[0].toLowerCase())) {
        return kv[1];
      }
    }
    return null;
  }

  @override
  Future<NasVendor?> detect() async {
    try {
      // authLogin.cgi returns firmware/model XML on QTS without auth.
      final resp = await dio.get('/cgi-bin/authLogin.cgi');
      final body = resp.data.toString();
      if (resp.statusCode == 200 &&
          (body.contains('QDocRoot') || body.contains('QTS'))) {
        return NasVendor.qnap;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<NasFileEntry>> listDirectory(String path) async {
    final target = path.isEmpty ? '/' : path;
    final entries = <NasFileEntry>[];
    var start = 0;

    while (true) {
      final resp = await dio.get(
        '/cgi-bin/filemanager/utilRequest.cgi',
        queryParameters: {
          'func': 'get_list',
          'is_iso': 0,
          'list_mode': 'all',
          'path': target,
          'dir': 'ASC',
          'sort': 'filename',
          'start': start,
          'limit': _pageSize,
          if (_sid != null) 'sid': _sid,
        },
      );

      if (resp.statusCode == 401 || resp.statusCode == 403) {
        throw const NasAuthException('QNAP session expired');
      }

      final data = _asJson(resp.data);
      if (data == null) {
        throw NasApiException('Unexpected QNAP response listing $target');
      }
      // QNAP WFM2 status codes: 1 (DONE) and 2 (SUCCESS) mean OK;
      // 4 = AUTH_FAIL, 5 = PERMISSION_DENY signal a dead session in-band.
      final status = data['status'];
      if (status is int && (status == 4 || status == 5)) {
        throw const NasAuthException('QNAP session expired');
      }
      if (!data.containsKey('datas') &&
          status is int &&
          status != 0 &&
          status != 1 &&
          status != 2) {
        throw NasApiException('QNAP error status $status listing $target');
      }

      final files = data['datas'] as List? ?? [];
      for (final f in files) {
        final info = f as Map<String, dynamic>;
        final name = info['filename'] as String? ?? '';
        if (name.isEmpty) continue;
        entries.add(NasFileEntry(
          name: name,
          path: target == '/' ? '/$name' : '$target/$name',
          isDirectory: (info['isfolder'] as num?) == 1,
          size: (info['filesize'] is String)
              ? int.tryParse(info['filesize'] as String)
              : (info['filesize'] as num?)?.toInt(),
          modified: _parseEpoch(info['epochmt']),
        ));
      }

      final total = (data['total'] as num?)?.toInt() ?? entries.length;
      start += files.length;
      if (files.isEmpty || start >= total) break;
    }
    return entries;
  }

  @override
  String getStreamUrl(String filePath) {
    final slash = filePath.lastIndexOf('/');
    final dir = slash <= 0 ? '/' : filePath.substring(0, slash);
    final name = filePath.substring(slash + 1);
    final sidPart = _sid != null ? '&sid=$_sid' : '';
    return '$baseUrl/cgi-bin/filemanager/utilRequest.cgi?func=download'
        '&isfolder=0&source_total=1'
        '&source_path=${Uri.encodeComponent(dir)}'
        '&source_file=${Uri.encodeComponent(name)}$sidPart';
  }

  Map<String, dynamic>? _asJson(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {}
    }
    return null;
  }

  DateTime? _parseEpoch(dynamic value) {
    if (value == null) return null;
    final secs = value is num ? value.toInt() : int.tryParse(value.toString());
    if (secs == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(secs * 1000);
  }
}
