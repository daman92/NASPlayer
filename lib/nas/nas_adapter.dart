import '../models/nas_config.dart';
import '../models/track.dart';

abstract class NasAdapter {
  NasVendor get vendor;
  String get baseUrl;

  Future<List<NasFileEntry>> listDirectory(String path);
  Future<List<Track>> listAudioFiles(String path);
  String getStreamUrl(String filePath);

  Future<NasVendor?> detect();
}
