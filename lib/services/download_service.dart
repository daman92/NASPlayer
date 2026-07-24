import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../database/app_database.dart';
import '../nas/nas_adapter.dart';

/// Downloads NAS tracks to app-local storage for offline playback
/// (design doc: "Offline download — pin folders/playlists", Phase 2).
class DownloadService {
  final AppDatabase _db;
  final Dio _dio = Dio();

  DownloadService(this._db);

  static Directory? _downloadDir;

  Future<Directory> _dir() async {
    if (_downloadDir != null) return _downloadDir!;
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'offline'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _downloadDir = dir;
    return dir;
  }

  /// Local file path a NAS path downloads to (deterministic, collision-safe).
  Future<String> localPathFor(String nasPath) async {
    final dir = await _dir();
    final sanitized = nasPath
        .replaceAll(RegExp(r'^/+'), '')
        .replaceAll(RegExp(r'[<>:"|?*]'), '_')
        .replaceAll('/', p.separator);
    return p.join(dir.path, sanitized);
  }

  /// Download one NAS file. Returns the local path on success.
  ///
  /// Streams to a `.part` temp file and renames on success, so a failed or
  /// cancelled retry can never destroy an existing good offline copy.
  Future<String> downloadTrack(
    NasAdapter adapter,
    String nasPath,
    String nasId, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final url = adapter.getStreamUrl(nasPath);
    final target = await localPathFor(nasPath);
    final targetFile = File(target);
    final partFile = File('$target.part');
    if (!targetFile.parent.existsSync()) {
      targetFile.parent.createSync(recursive: true);
    }

    // Already downloaded and intact? Don't touch it.
    final existing = await _db.getDownloadForNasPath(nasPath);
    if (existing != null &&
        existing['status'] == 'done' &&
        targetFile.existsSync()) {
      return target;
    }

    await _db.upsertDownload({
      'nas_path': nasPath,
      'nas_id': nasId,
      'local_path': target,
      'title': p.basename(nasPath),
      'status': 'downloading',
    });

    try {
      await _dio.download(
        url,
        partFile.path,
        options: Options(headers: adapter.streamHeaders),
        onReceiveProgress: onProgress,
        cancelToken: cancelToken,
      );

      // An HTML/JSON error page instead of audio means the session was
      // rejected — check the leading bytes regardless of file size (DSM
      // login pages are several KB).
      final size = partFile.existsSync() ? partFile.lengthSync() : 0;
      if (size == 0) {
        throw const NasApiException('Download produced an empty file');
      }
      final head =
          await partFile.openRead(0, size < 512 ? size : 512).first;
      final text = String.fromCharCodes(head).toLowerCase();
      if (text.contains('<html') ||
          text.contains('<!doctype') ||
          text.contains('"success":false')) {
        partFile.deleteSync();
        throw const NasAuthException('Download rejected — please re-login');
      }

      if (targetFile.existsSync()) targetFile.deleteSync();
      partFile.renameSync(target);

      await _db.upsertDownload({
        'nas_path': nasPath,
        'nas_id': nasId,
        'local_path': target,
        'title': p.basename(nasPath),
        'size_bytes': size,
        'status': 'done',
        'downloaded_at': DateTime.now().millisecondsSinceEpoch,
      });
      return target;
    } catch (e) {
      try {
        if (partFile.existsSync()) partFile.deleteSync();
      } catch (_) {}

      if (e is DioException && CancelToken.isCancel(e)) {
        // User-initiated cancel: restore the previous row (or remove it),
        // never mark it 'failed'.
        if (existing != null && existing['status'] == 'done') {
          await _db.upsertDownload(existing);
        } else {
          await _db.deleteDownload(nasPath);
        }
        rethrow;
      }

      if (existing != null && existing['status'] == 'done' &&
          targetFile.existsSync()) {
        // The old copy survived — keep its 'done' row.
        await _db.upsertDownload(existing);
      } else {
        await _db.upsertDownload({
          'nas_path': nasPath,
          'nas_id': nasId,
          'local_path': target,
          'title': p.basename(nasPath),
          'status': 'failed',
        });
      }
      rethrow;
    }
  }

  /// Returns the local copy of a NAS track if it was downloaded, else null.
  Future<String?> localCopyFor(String nasPath) async {
    final row = await _db.getDownloadForNasPath(nasPath);
    if (row == null || row['status'] != 'done') return null;
    final path = row['local_path'] as String;
    return File(path).existsSync() ? path : null;
  }

  Future<void> deleteDownload(String nasPath) async {
    final row = await _db.getDownloadForNasPath(nasPath);
    if (row != null) {
      final f = File(row['local_path'] as String);
      if (f.existsSync()) f.deleteSync();
    }
    await _db.deleteDownload(nasPath);
  }
}
