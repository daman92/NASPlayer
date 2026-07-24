import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/download_service.dart';
import 'library_provider.dart';
import 'nas_provider.dart';

final downloadServiceProvider = Provider<DownloadService>((ref) {
  return DownloadService(ref.watch(databaseProvider));
});

class DownloadProgress {
  final String nasPath;
  final String title;
  final double progress; // 0..1, -1 = indeterminate
  final String status; // queued | downloading | done | failed

  const DownloadProgress({
    required this.nasPath,
    required this.title,
    required this.progress,
    required this.status,
  });
}

class DownloadQueueNotifier
    extends StateNotifier<Map<String, DownloadProgress>> {
  final Ref _ref;
  final _cancelTokens = <String, CancelToken>{};
  bool _running = false;
  final List<({String nasPath, String title})> _pending = [];

  DownloadQueueNotifier(this._ref) : super({});

  /// Queue a set of NAS files (a pinned folder, playlist, or selection).
  void enqueue(List<({String nasPath, String title})> items) {
    for (final item in items) {
      if (state.containsKey(item.nasPath) &&
          state[item.nasPath]!.status != 'failed') {
        continue;
      }
      _pending.add(item);
      state = {
        ...state,
        item.nasPath: DownloadProgress(
          nasPath: item.nasPath,
          title: item.title,
          progress: 0,
          status: 'queued',
        ),
      };
    }
    _pump();
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (_pending.isNotEmpty) {
        final item = _pending.removeAt(0);
        await _downloadOne(item.nasPath, item.title);
      }
    } finally {
      _running = false;
      _ref.read(downloadsRefreshProvider.notifier).state++;
    }
  }

  Future<void> _downloadOne(String nasPath, String title) async {
    final adapter = _ref.read(authenticatedNasProvider);
    final nasId = _ref
        .read(nasConfigNotifierProvider.notifier)
        .activeConfig
        ?.id;
    if (adapter == null || nasId == null) {
      _update(nasPath, title, 0, 'failed');
      return;
    }

    final service = _ref.read(downloadServiceProvider);
    final token = CancelToken();
    _cancelTokens[nasPath] = token;
    _update(nasPath, title, 0, 'downloading');

    try {
      await service.downloadTrack(
        adapter,
        nasPath,
        nasId,
        cancelToken: token,
        onProgress: (received, total) {
          final progress = total > 0 ? received / total : -1.0;
          _update(nasPath, title, progress, 'downloading');
        },
      );
      _update(nasPath, title, 1, 'done');
    } on DioException catch (e) {
      // A user-initiated cancel is not a failure — the entry was already
      // removed from state by cancel(); don't resurrect it.
      if (!CancelToken.isCancel(e)) {
        _update(nasPath, title, 0, 'failed');
      }
    } catch (_) {
      _update(nasPath, title, 0, 'failed');
    } finally {
      _cancelTokens.remove(nasPath);
    }
  }

  void _update(String nasPath, String title, double progress, String status) {
    if (!mounted) return;
    state = {
      ...state,
      nasPath: DownloadProgress(
        nasPath: nasPath,
        title: title,
        progress: progress,
        status: status,
      ),
    };
  }

  void cancel(String nasPath) {
    _cancelTokens[nasPath]?.cancel();
    _pending.removeWhere((i) => i.nasPath == nasPath);
    final next = Map<String, DownloadProgress>.from(state)..remove(nasPath);
    state = next;
  }

  /// Number of downloads still queued or in flight.
  int get activeCount => state.values
      .where((d) => d.status == 'queued' || d.status == 'downloading')
      .length;

  /// Cancel everything: the pending queue and all in-flight transfers.
  void cancelAll() {
    _pending.clear();
    for (final token in _cancelTokens.values) {
      token.cancel();
    }
    state = {
      for (final e in state.entries)
        if (e.value.status != 'queued' && e.value.status != 'downloading')
          e.key: e.value,
    };
  }

  void clearFinished() {
    state = {
      for (final e in state.entries)
        if (e.value.status == 'downloading' || e.value.status == 'queued')
          e.key: e.value,
    };
  }
}

final downloadQueueProvider =
    StateNotifierProvider<DownloadQueueNotifier, Map<String, DownloadProgress>>(
        (ref) {
  return DownloadQueueNotifier(ref);
});

/// Completed downloads stored in the DB.
final completedDownloadsProvider =
    FutureProvider<List<Map<String, Object?>>>((ref) async {
  ref.watch(downloadsRefreshProvider);
  final db = ref.watch(databaseProvider);
  return db.getAllDownloads();
});

final downloadsRefreshProvider = StateProvider<int>((ref) => 0);
