import 'package:dio/dio.dart';

import '../models/nas_config.dart';
import 'http_nas_adapter.dart';
import 'nas_adapter.dart';

/// Synology DSM FileStation adapter (Phase 1 priority vendor).
class SynologyAdapter extends HttpNasAdapter {
  SynologyAdapter(super.baseUrl, {required super.cookies, super.extraHeaders});

  @override
  NasVendor get vendor => NasVendor.synology;

  static const _pageSize = 1000;

  // Synology session-related error codes (invalid/expired session).
  static const _authErrorCodes = {105, 106, 107, 119};

  /// DSM 7 CSRF token. With "Improve protection against cross-site request
  /// forgery" enabled (the DSM 7 default), cookie-authenticated /webapi
  /// calls MUST also send X-SYNO-TOKEN or DSM answers error 119 even though
  /// the session cookie is perfectly valid.
  String? _synoToken;

  @override
  Future<void> prepare() => _fetchSynoToken();

  /// Ask DSM for the SynoToken belonging to the existing session cookie.
  Future<void> _fetchSynoToken() async {
    if (_synoToken != null) return;
    try {
      final resp = await dio.get(
        '/webman/login.cgi',
        queryParameters: {'enable_syno_token': 'yes'},
        options: Options(responseType: ResponseType.plain),
      );
      final body = resp.data.toString();
      final match =
          RegExp(r'"SynoToken"\s*:\s*"([^"]+)"').firstMatch(body);
      final token = match?.group(1);
      // DSM returns "--------" when the session is not authenticated.
      if (token != null && token.isNotEmpty && !token.startsWith('---')) {
        _synoToken = token;
        dio.options.headers['X-SYNO-TOKEN'] = token;
      }
    } catch (_) {
      // Older DSM without CSRF protection works fine without the token.
    }
  }

  @override
  Map<String, String> get streamHeaders => {
        if (cookies.isNotEmpty) 'Cookie': cookies,
        ...extraHeaders,
        if (_synoToken != null) 'X-SYNO-TOKEN': _synoToken!,
      };

  /// GET a /webapi endpoint; on an auth error, try once to (re)acquire the
  /// SynoToken and retry — covers DSM 7 CSRF rejections of otherwise valid
  /// sessions.
  Future<Map<String, dynamic>> _apiGet(
      Map<String, Object?> params, String context) async {
    Future<Map<String, dynamic>> call() async {
      final resp =
          await dio.get('/webapi/entry.cgi', queryParameters: params);
      return _checkResponse(resp.data, context);
    }

    try {
      return await call();
    } on NasAuthException {
      if (_synoToken != null) rethrow;
      await _fetchSynoToken();
      if (_synoToken == null) rethrow;
      return call();
    }
  }

  @override
  Future<NasVendor?> detect() async {
    try {
      final resp = await dio.get(
        '/webapi/entry.cgi',
        queryParameters: {
          'api': 'SYNO.API.Info',
          'version': '1',
          'method': 'query',
          'query': 'SYNO.FileStation.List',
        },
      );
      final data = _asJson(resp.data);
      return data?['success'] == true ? NasVendor.synology : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<NasFileEntry>> listDirectory(String path) async {
    if (path.isEmpty || path == '/') {
      return _listShares();
    }

    final entries = <NasFileEntry>[];
    var offset = 0;
    while (true) {
      final data = await _apiGet({
        'api': 'SYNO.FileStation.List',
        'version': '2',
        'method': 'list',
        'folder_path': _escapePath(path),
        'additional': '["size","time"]',
        'sort_by': 'name',
        'sort_direction': 'ASC',
        'offset': offset,
        'limit': _pageSize,
      }, 'list $path');
      final files = data['data']?['files'] as List? ?? [];
      entries.addAll(files.map(_parseFileEntry));

      final total = data['data']?['total'] as int? ?? entries.length;
      offset += files.length;
      if (files.isEmpty || offset >= total) break;
    }
    return entries;
  }

  /// The FileStation API rejects `method=list` on `/`; top-level shared
  /// folders must be enumerated with `method=list_share`.
  Future<List<NasFileEntry>> _listShares() async {
    final entries = <NasFileEntry>[];
    var offset = 0;
    while (true) {
      final data = await _apiGet({
        'api': 'SYNO.FileStation.List',
        'version': '2',
        'method': 'list_share',
        'additional': '["time"]',
        'sort_by': 'name',
        'sort_direction': 'ASC',
        'offset': offset,
        'limit': _pageSize,
      }, 'list shares');
      final shares = data['data']?['shares'] as List? ?? [];
      entries.addAll(shares.map(_parseFileEntry));

      final total = data['data']?['total'] as int? ?? entries.length;
      offset += shares.length;
      if (shares.isEmpty || offset >= total) break;
    }
    return entries;
  }

  @override
  String getStreamUrl(String filePath) {
    final encoded = Uri.encodeComponent(_escapePath(filePath));
    final tokenPart = _synoToken != null ? '&SynoToken=$_synoToken' : '';
    return '$baseUrl/webapi/entry.cgi?api=SYNO.FileStation.Download'
        '&version=2&method=download&path=$encoded&mode=open$tokenPart';
  }

  // ── Internal helpers ───────────────────────────────────────────────────────

  /// FileStation splits path parameters on commas (multi-path syntax);
  /// literal commas in names must be backslash-escaped.
  static String _escapePath(String path) => path.replaceAll(',', r'\,');

  NasFileEntry _parseFileEntry(dynamic f) {
    final info = f as Map<String, dynamic>;
    final additional = info['additional'] as Map<String, dynamic>? ?? {};
    return NasFileEntry(
      name: info['name'] as String? ?? '',
      path: info['path'] as String? ?? '',
      // list_share entries have no isdir field — shares are always folders.
      isDirectory: info['isdir'] as bool? ?? true,
      size: (additional['size'] as num?)?.toInt(),
      modified: _parseTime(additional['time']?['mtime']),
    );
  }

  Map<String, dynamic>? _asJson(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    return null;
  }

  Map<String, dynamic> _checkResponse(dynamic raw, String context) {
    final data = _asJson(raw);
    if (data == null) {
      throw NasApiException('Unexpected NAS response for $context '
          '(not JSON — possibly a login redirect)');
    }
    if (data['success'] != true) {
      final code = data['error']?['code'] as int?;
      if (code != null && _authErrorCodes.contains(code)) {
        throw const NasAuthException();
      }
      throw NasApiException('NAS error ${code ?? 'unknown'} for $context');
    }
    return data;
  }

  DateTime? _parseTime(dynamic value) {
    if (value == null) return null;
    try {
      return DateTime.fromMillisecondsSinceEpoch((value as num).toInt() * 1000);
    } catch (_) {
      return null;
    }
  }
}
