import '../models/nas_config.dart';
import 'nas_adapter.dart';
import 'nextcloud_adapter.dart';
import 'qnap_adapter.dart';
import 'synology_adapter.dart';
import 'truenas_adapter.dart';

/// Detects the NAS vendor by probing known API endpoints (design doc 8.2)
/// and builds the matching adapter. Users can override the result manually
/// in Settings via [adapterForVendor].
class NasDetector {
  const NasDetector();

  /// Probe vendors in priority order and return the detected one, or null.
  Future<NasVendor?> detectVendor(
    String baseUrl,
    String cookies, {
    Map<String, String> extraHeaders = const {},
  }) async {
    final candidates = <NasAdapter>[
      SynologyAdapter(baseUrl, cookies: cookies, extraHeaders: extraHeaders),
      QnapAdapter(baseUrl, cookies: cookies, extraHeaders: extraHeaders),
      NextcloudAdapter(baseUrl, cookies: cookies, extraHeaders: extraHeaders),
      TrueNasAdapter(baseUrl, cookies: cookies, extraHeaders: extraHeaders),
    ];

    for (final adapter in candidates) {
      final vendor = await adapter.detect();
      if (vendor != null) return vendor;
    }
    return null;
  }

  NasAdapter adapterForVendor(
    NasVendor vendor,
    String baseUrl,
    String cookies, {
    Map<String, String> extraHeaders = const {},
  }) {
    switch (vendor) {
      case NasVendor.qnap:
        return QnapAdapter(baseUrl, cookies: cookies, extraHeaders: extraHeaders);
      case NasVendor.nextcloud:
        return NextcloudAdapter(baseUrl,
            cookies: cookies, extraHeaders: extraHeaders);
      case NasVendor.truenas:
        return TrueNasAdapter(baseUrl,
            cookies: cookies, extraHeaders: extraHeaders);
      case NasVendor.synology:
      case NasVendor.generic:
      case NasVendor.unknown:
        return SynologyAdapter(baseUrl,
            cookies: cookies, extraHeaders: extraHeaders);
    }
  }

  /// Detect and build in one step, falling back to Synology (most common).
  Future<({NasAdapter adapter, NasVendor? detected})> createAdapter(
    String baseUrl,
    String cookies, {
    Map<String, String> extraHeaders = const {},
  }) async {
    final vendor =
        await detectVendor(baseUrl, cookies, extraHeaders: extraHeaders);
    return (
      adapter: adapterForVendor(
        vendor ?? NasVendor.synology,
        baseUrl,
        cookies,
        extraHeaders: extraHeaders,
      ),
      detected: vendor,
    );
  }
}
