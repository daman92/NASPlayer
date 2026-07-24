import 'package:audio_service/audio_service.dart';

enum TrackSource { local, nas }

class Track {
  final String id;
  final String title;
  final String artist;
  final String album;
  final Duration duration;

  /// Playable location: a filesystem path for local tracks, or a fully
  /// resolved (authenticated) stream URL for NAS tracks.
  final String filePath;

  /// The raw path on the NAS (e.g. `/music/Album/01.flac`) for NAS tracks.
  /// Stored in playlists/DB so stream URLs can be re-resolved with fresh
  /// session cookies at play time.
  final String? nasPath;

  /// HTTP headers (session cookies) the player must send when streaming.
  final Map<String, String>? httpHeaders;

  final String? artworkPath;
  final String? artworkUrl;
  final String format;
  final int? bitDepth;
  final int? sampleRate;
  final int? bitrate;
  final TrackSource source;
  final String? nasVendor;
  final DateTime? dateModified;

  const Track({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    required this.filePath,
    required this.source,
    this.nasPath,
    this.httpHeaders,
    this.artworkPath,
    this.artworkUrl,
    this.format = '',
    this.bitDepth,
    this.sampleRate,
    this.bitrate,
    this.nasVendor,
    this.dateModified,
  });

  MediaItem toMediaItem() => MediaItem(
        id: filePath,
        title: title,
        artist: artist,
        album: album,
        duration: duration,
        artUri: artworkUrl != null
            ? Uri.parse(artworkUrl!)
            : artworkPath != null
                ? Uri.file(artworkPath!)
                : null,
        extras: {
          'source': source.name,
          'format': format,
          'trackId': id,
          if (nasPath != null) 'nasPath': nasPath,
          if (httpHeaders != null) 'headers': httpHeaders,
          if (bitDepth != null) 'bitDepth': bitDepth,
          if (sampleRate != null) 'sampleRate': sampleRate,
          if (bitrate != null) 'bitrate': bitrate,
        },
      );

  String get formatLabel {
    final parts = <String>[];
    if (format.isNotEmpty) parts.add(format.toUpperCase());
    if (bitDepth != null) parts.add('$bitDepth-bit');
    if (sampleRate != null) {
      final khz = sampleRate! / 1000;
      parts.add('${khz % 1 == 0 ? khz.toInt() : khz.toStringAsFixed(1)}kHz');
    }
    if (parts.length < 3 && bitrate != null && bitrate! > 0) {
      parts.add('${(bitrate! / 1000).round()}kbps');
    }
    return parts.join(' / ');
  }

  Track copyWith({
    String? title,
    String? artist,
    String? album,
    Duration? duration,
    String? filePath,
    String? nasPath,
    Map<String, String>? httpHeaders,
    String? artworkPath,
    String? artworkUrl,
    String? format,
    int? bitDepth,
    int? sampleRate,
    int? bitrate,
    DateTime? dateModified,
  }) =>
      Track(
        id: id,
        title: title ?? this.title,
        artist: artist ?? this.artist,
        album: album ?? this.album,
        duration: duration ?? this.duration,
        filePath: filePath ?? this.filePath,
        source: source,
        nasPath: nasPath ?? this.nasPath,
        httpHeaders: httpHeaders ?? this.httpHeaders,
        artworkPath: artworkPath ?? this.artworkPath,
        artworkUrl: artworkUrl ?? this.artworkUrl,
        format: format ?? this.format,
        bitDepth: bitDepth ?? this.bitDepth,
        sampleRate: sampleRate ?? this.sampleRate,
        bitrate: bitrate ?? this.bitrate,
        nasVendor: nasVendor,
        dateModified: dateModified ?? this.dateModified,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Track && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
