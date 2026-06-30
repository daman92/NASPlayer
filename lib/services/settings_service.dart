import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';

class SettingsService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _keyLastFolder = 'last_local_folder';
  static const _keyNasConfigs = 'nas_configs';
  static const _keyNasCookies = 'nas_cookies_';
  static const _keyResumeTrack = 'resume_track';
  static const _keyResumePosition = 'resume_position';
  static const _keyTheme = 'theme';

  Future<String?> getLastLocalFolder() =>
      _storage.read(key: _keyLastFolder);

  Future<void> setLastLocalFolder(String path) =>
      _storage.write(key: _keyLastFolder, value: path);

  Future<void> saveCookiesForNas(String nasId, String cookies) =>
      _storage.write(key: '$_keyNasCookies$nasId', value: cookies);

  Future<String?> getCookiesForNas(String nasId) =>
      _storage.read(key: '$_keyNasCookies$nasId');

  Future<void> deleteCookiesForNas(String nasId) =>
      _storage.delete(key: '$_keyNasCookies$nasId');

  Future<void> saveResumeState(String trackPath, int positionMs) async {
    await _storage.write(key: _keyResumeTrack, value: trackPath);
    await _storage.write(
        key: _keyResumePosition, value: positionMs.toString());
  }

  Future<({String path, int positionMs})?> getResumeState() async {
    final path = await _storage.read(key: _keyResumeTrack);
    final posStr = await _storage.read(key: _keyResumePosition);
    if (path == null) return null;
    return (path: path, positionMs: int.tryParse(posStr ?? '0') ?? 0);
  }

  Future<void> clearResumeState() async {
    await _storage.delete(key: _keyResumeTrack);
    await _storage.delete(key: _keyResumePosition);
  }

  Future<List<Map<String, dynamic>>> loadNasConfigs() async {
    final json = await _storage.read(key: _keyNasConfigs);
    if (json == null) return [];
    try {
      return List<Map<String, dynamic>>.from(jsonDecode(json) as List);
    } catch (_) {
      return [];
    }
  }

  Future<void> saveNasConfigs(List<Map<String, dynamic>> configs) =>
      _storage.write(key: _keyNasConfigs, value: jsonEncode(configs));
}
