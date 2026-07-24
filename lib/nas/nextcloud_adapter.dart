import 'package:dio/dio.dart';

import '../models/nas_config.dart';
import 'http_nas_adapter.dart';
import 'nas_adapter.dart';

/// Nextcloud / ownCloud adapter (Phase 2 vendor).
///
/// Browses via WebDAV PROPFIND on `/remote.php/dav/files/<user>/` and streams
/// via authenticated GET on the same endpoint. When authenticating with
/// session cookies (instead of an app password), Nextcloud requires the CSRF
/// `requesttoken` header, which the login screen extracts from the page and
/// passes through [extraHeaders].
class NextcloudAdapter extends HttpNasAdapter {
  String? _username;

  NextcloudAdapter(super.baseUrl, {required super.cookies, super.extraHeaders});

  @override
  NasVendor get vendor => NasVendor.nextcloud;

  /// Resolve the username eagerly so stream URLs built before the first
  /// browse (resume-on-launch, playlist playback) are valid.
  @override
  Future<void> prepare() async {
    try {
      await _resolveUser();
    } catch (_) {
      // Best effort; listDirectory resolves lazily as a fallback.
    }
  }

  @override
  Future<NasVendor?> detect() async {
    try {
      final resp = await dio.get('/status.php');
      final data = resp.data;
      if (resp.statusCode == 200 && data is Map<String, dynamic>) {
        final product = (data['productname'] ?? '').toString().toLowerCase();
        if (data['installed'] == true &&
            (product.contains('nextcloud') ||
                product.contains('owncloud') ||
                data.containsKey('versionstring'))) {
          return NasVendor.nextcloud;
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<String> _resolveUser() async {
    if (_username != null) return _username!;
    final resp = await dio.get(
      '/ocs/v2.php/cloud/user',
      queryParameters: {'format': 'json'},
      options: Options(headers: {'OCS-APIRequest': 'true'}),
    );
    if (resp.statusCode == 401) {
      throw const NasAuthException('Nextcloud session expired');
    }
    final data = resp.data;
    String? id;
    if (data is Map<String, dynamic>) {
      final ocs = data['ocs'];
      if (ocs is Map<String, dynamic>) {
        final userData = ocs['data'];
        if (userData is Map<String, dynamic>) {
          id = userData['id'] as String?;
        }
      }
    }
    if (id == null || id.isEmpty) {
      throw const NasApiException('Could not resolve Nextcloud username');
    }
    _username = id;
    return id;
  }

  @override
  Future<List<NasFileEntry>> listDirectory(String path) async {
    final user = await _resolveUser();
    final davRoot = '/remote.php/dav/files/$user';
    final target = path.isEmpty ? '/' : path;
    final url = '$davRoot${HttpNasAdapter.encodePath(target)}';

    final resp = await dio.request(
      url,
      options: Options(
        method: 'PROPFIND',
        headers: {
          'Depth': '1',
          'Content-Type': 'application/xml',
        },
        responseType: ResponseType.plain,
      ),
      data: '''<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:resourcetype/>
    <d:getcontentlength/>
    <d:getlastmodified/>
  </d:prop>
</d:propfind>''',
    );

    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw const NasAuthException('Nextcloud session expired');
    }
    if (resp.statusCode != 207) {
      throw NasApiException(
          'Nextcloud PROPFIND failed (${resp.statusCode}) for $target');
    }

    return _parseMultistatus(resp.data.toString(), davRoot, target);
  }

  List<NasFileEntry> _parseMultistatus(
      String xml, String davRoot, String requestedPath) {
    final entries = <NasFileEntry>[];
    final responseRe = RegExp(
        r'<d:response[\s\S]*?</d:response>',
        caseSensitive: false);
    final hrefRe =
        RegExp(r'<d:href>([\s\S]*?)</d:href>', caseSensitive: false);
    final lengthRe = RegExp(
        r'<d:getcontentlength[^>]*>(\d+)</d:getcontentlength>',
        caseSensitive: false);
    final modifiedRe = RegExp(
        r'<d:getlastmodified[^>]*>([\s\S]*?)</d:getlastmodified>',
        caseSensitive: false);
    final collectionRe = RegExp(r'<d:collection\s*/?>', caseSensitive: false);

    for (final m in responseRe.allMatches(xml)) {
      final block = m.group(0)!;
      final hrefMatch = hrefRe.firstMatch(block);
      if (hrefMatch == null) continue;

      // sabre/dav XML-escapes hrefs (a literal '&' becomes '&amp;'), so
      // XML-unescape BEFORE percent-decoding.
      var href = Uri.decodeFull(_xmlUnescape(hrefMatch.group(1)!.trim()));
      // Strip host prefix if present and the DAV root.
      final rootIdx = href.indexOf(davRoot);
      if (rootIdx < 0) continue;
      var entryPath = href.substring(rootIdx + davRoot.length);
      if (entryPath.endsWith('/')) {
        entryPath = entryPath.substring(0, entryPath.length - 1);
      }
      if (entryPath.isEmpty) entryPath = '/';

      // Skip the entry for the requested directory itself.
      final normalizedRequest = requestedPath.endsWith('/') &&
              requestedPath != '/'
          ? requestedPath.substring(0, requestedPath.length - 1)
          : requestedPath;
      if (entryPath == normalizedRequest || entryPath == '/') continue;

      final isDir = collectionRe.hasMatch(block);
      final sizeMatch = lengthRe.firstMatch(block);
      final modMatch = modifiedRe.firstMatch(block);

      entries.add(NasFileEntry(
        name: entryPath.split('/').last,
        path: entryPath,
        isDirectory: isDir,
        size: sizeMatch != null ? int.tryParse(sizeMatch.group(1)!) : null,
        modified: modMatch != null
            ? _parseHttpDate(_xmlUnescape(modMatch.group(1)!.trim()))
            : null,
      ));
    }

    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  @override
  String getStreamUrl(String filePath) {
    final user = _username ?? '';
    return '$baseUrl/remote.php/dav/files/$user'
        '${HttpNasAdapter.encodePath(filePath)}';
  }

  DateTime? _parseHttpDate(String value) {
    try {
      return HttpDate.parse(value);
    } catch (_) {
      return null;
    }
  }

  static String _xmlUnescape(String value) => value
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&');
}

/// Minimal RFC 1123 date parser (avoids importing dart:io HttpDate in a
/// file that may be used in tests without a full IO environment).
class HttpDate {
  static const _months = {
    'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
    'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
  };

  static DateTime parse(String value) {
    // e.g. "Mon, 15 Jul 2026 20:31:00 GMT"
    final parts = value.replaceAll(',', '').split(RegExp(r'\s+'));
    if (parts.length < 5) throw FormatException('Bad HTTP date: $value');
    final day = int.parse(parts[1]);
    final month = _months[parts[2]] ?? 1;
    final year = int.parse(parts[3]);
    final time = parts[4].split(':').map(int.parse).toList();
    return DateTime.utc(year, month, day, time[0], time[1], time[2]);
  }
}
