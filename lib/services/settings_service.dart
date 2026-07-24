import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SettingsService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _keyLastFolder = 'last_local_folder';
  static const _keyNasCookies = 'nas_cookies_';
  static const _keyNasHeaders = 'nas_headers_';
  static const _keyResumeQueue = 'resume_queue';
  static const _keyResumeIndex = 'resume_index';
  static const _keyResumePosition = 'resume_position';
  static const _keyResumeEnabled = 'resume_enabled';
  static const _keyNasAutoRefresh = 'nas_auto_refresh';
  static const _keyEqSettings = 'eq_settings';
  static const _keyVolume = 'player_volume';

  // ── Local folder ────────────────────────────────────────────────────────────

  Future<String?> getLastLocalFolder() => _storage.read(key: _keyLastFolder);

  Future<void> setLastLocalFolder(String path) =>
      _storage.write(key: _keyLastFolder, value: path);

  // ── NAS session ─────────────────────────────────────────────────────────────

  Future<void> saveCookiesForNas(String nasId, String cookies) =>
      _storage.write(key: '$_keyNasCookies$nasId', value: cookies);

  Future<String?> getCookiesForNas(String nasId) =>
      _storage.read(key: '$_keyNasCookies$nasId');

  Future<void> deleteCookiesForNas(String nasId) async {
    await _storage.delete(key: '$_keyNasCookies$nasId');
    await _storage.delete(key: '$_keyNasHeaders$nasId');
  }

  /// Extra per-NAS headers (e.g. Nextcloud's CSRF requesttoken).
  Future<void> saveExtraHeadersForNas(
      String nasId, Map<String, String> headers) =>
      _storage.write(key: '$_keyNasHeaders$nasId', value: jsonEncode(headers));

  Future<Map<String, String>> getExtraHeadersForNas(String nasId) async {
    final json = await _storage.read(key: '$_keyNasHeaders$nasId');
    if (json == null) return {};
    try {
      return Map<String, String>.from(jsonDecode(json) as Map);
    } catch (_) {
      return {};
    }
  }

  // ── Resume state ────────────────────────────────────────────────────────────

  Future<bool> getResumeEnabled() async =>
      (await _storage.read(key: _keyResumeEnabled)) != 'false';

  Future<void> setResumeEnabled(bool enabled) =>
      _storage.write(key: _keyResumeEnabled, value: enabled.toString());

  /// Persist the queue as a list of track ids + paths so playback can be
  /// restored across launches (local paths and NAS raw paths only).
  Future<void> saveResumeQueue(
      List<Map<String, dynamic>> queue, int index, int positionMs) async {
    await _storage.write(key: _keyResumeQueue, value: jsonEncode(queue));
    await _storage.write(key: _keyResumeIndex, value: index.toString());
    await _storage.write(key: _keyResumePosition, value: positionMs.toString());
  }

  Future<void> saveResumePosition(int index, int positionMs) async {
    await _storage.write(key: _keyResumeIndex, value: index.toString());
    await _storage.write(key: _keyResumePosition, value: positionMs.toString());
  }

  Future<({List<Map<String, dynamic>> queue, int index, int positionMs})?>
      getResumeState() async {
    final queueJson = await _storage.read(key: _keyResumeQueue);
    if (queueJson == null) return null;
    try {
      final queue = List<Map<String, dynamic>>.from(
          (jsonDecode(queueJson) as List).map((e) => Map<String, dynamic>.from(e as Map)));
      if (queue.isEmpty) return null;
      final index =
          int.tryParse(await _storage.read(key: _keyResumeIndex) ?? '0') ?? 0;
      final pos = int.tryParse(
              await _storage.read(key: _keyResumePosition) ?? '0') ??
          0;
      return (queue: queue, index: index, positionMs: pos);
    } catch (_) {
      return null;
    }
  }

  Future<void> clearResumeState() async {
    await _storage.delete(key: _keyResumeQueue);
    await _storage.delete(key: _keyResumeIndex);
    await _storage.delete(key: _keyResumePosition);
  }

  // ── Active NAS streaming context ────────────────────────────────────────────

  static const _keyActiveNasHeaders = 'active_nas_headers';
  static const _keyActiveNasContext = 'active_nas_context';

  /// Last-known streaming headers for the active NAS session. Lets the audio
  /// handler restore a NAS queue when started headlessly by Android Auto,
  /// where the UI-side session restore never runs.
  Future<void> saveActiveNasHeaders(Map<String, String> headers) =>
      _storage.write(key: _keyActiveNasHeaders, value: jsonEncode(headers));

  Future<Map<String, String>> getActiveNasHeaders() async {
    final json = await _storage.read(key: _keyActiveNasHeaders);
    if (json == null) return {};
    try {
      return Map<String, String>.from(jsonDecode(json) as Map);
    } catch (_) {
      return {};
    }
  }

  /// Identity of the active NAS session (id/url/vendor), so the audio
  /// handler can rebuild a working adapter — fresh stream URLs and headers —
  /// when Android Auto starts the app headlessly.
  Future<void> saveActiveNasContext({
    required String nasId,
    required String baseUrl,
    required String vendor,
  }) =>
      _storage.write(
        key: _keyActiveNasContext,
        value: jsonEncode({'nasId': nasId, 'baseUrl': baseUrl, 'vendor': vendor}),
      );

  Future<({String nasId, String baseUrl, String vendor})?>
      getActiveNasContext() async {
    final json = await _storage.read(key: _keyActiveNasContext);
    if (json == null) return null;
    try {
      final map = Map<String, dynamic>.from(jsonDecode(json) as Map);
      final nasId = map['nasId'] as String?;
      final baseUrl = map['baseUrl'] as String?;
      if (nasId == null || baseUrl == null) return null;
      return (
        nasId: nasId,
        baseUrl: baseUrl,
        vendor: map['vendor'] as String? ?? 'synology',
      );
    } catch (_) {
      return null;
    }
  }

  // ── NAS index refresh ───────────────────────────────────────────────────────

  Future<bool> getNasAutoRefresh() async =>
      (await _storage.read(key: _keyNasAutoRefresh)) != 'false';

  Future<void> setNasAutoRefresh(bool enabled) =>
      _storage.write(key: _keyNasAutoRefresh, value: enabled.toString());

  // ── Equalizer ───────────────────────────────────────────────────────────────

  Future<void> saveEqSettings(Map<String, dynamic> settings) =>
      _storage.write(key: _keyEqSettings, value: jsonEncode(settings));

  Future<Map<String, dynamic>?> getEqSettings() async {
    final json = await _storage.read(key: _keyEqSettings);
    if (json == null) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(json) as Map);
    } catch (_) {
      return null;
    }
  }

  // ── Volume ──────────────────────────────────────────────────────────────────

  Future<double> getVolume() async {
    final v = await _storage.read(key: _keyVolume);
    return double.tryParse(v ?? '1.0') ?? 1.0;
  }

  Future<void> setVolume(double volume) =>
      _storage.write(key: _keyVolume, value: volume.toString());
}
