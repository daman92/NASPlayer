import '../models/nas_config.dart';
import '../services/settings_service.dart';
import 'nas_adapter.dart';
import 'synology_adapter.dart';

class NasDetector {
  final SettingsService _settings;

  NasDetector(this._settings);

  Future<NasAdapter?> createAdapter(String nasId, String baseUrl) async {
    final cookies = await _settings.getCookiesForNas(nasId) ?? '';

    // Try Synology first (Phase 1 priority)
    final synology = SynologyAdapter(baseUrl, cookies: cookies);
    final synologyVendor = await synology.detect();
    if (synologyVendor != null) return synology;

    // Phase 2: QNAP, Nextcloud adapters would be tried here

    // Return Synology as default (most common)
    return SynologyAdapter(baseUrl, cookies: cookies);
  }

  NasAdapter adapterForVendor(
    NasVendor vendor,
    String baseUrl,
    String cookies,
  ) {
    switch (vendor) {
      case NasVendor.synology:
      case NasVendor.unknown:
      case NasVendor.generic:
        return SynologyAdapter(baseUrl, cookies: cookies);
      default:
        // Phase 2: return vendor-specific adapters
        return SynologyAdapter(baseUrl, cookies: cookies);
    }
  }
}
