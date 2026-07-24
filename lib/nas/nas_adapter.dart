import '../models/nas_config.dart';
import '../models/track.dart';

/// Thrown when the NAS rejects the session (expired/invalid cookies).
/// The UI catches this to prompt a WebView re-login (design doc section 7).
class NasAuthException implements Exception {
  final String message;
  const NasAuthException([this.message = 'NAS session expired']);

  @override
  String toString() => message;
}

/// Thrown for any other NAS API failure (network, bad path, server error).
class NasApiException implements Exception {
  final String message;
  const NasApiException(this.message);

  @override
  String toString() => message;
}

abstract class NasAdapter {
  NasVendor get vendor;
  String get baseUrl;

  /// Headers (session cookies) required to stream files from this NAS.
  Map<String, String> get streamHeaders;

  /// One-time async initialization (e.g. resolving the Nextcloud username)
  /// so that [getStreamUrl] works before any directory has been browsed.
  Future<void> prepare();

  Future<List<NasFileEntry>> listDirectory(String path);
  Future<List<Track>> listAudioFiles(String path);
  String getStreamUrl(String filePath);
  Track entryToTrack(NasFileEntry entry);

  Future<NasVendor?> detect();
}
