import 'package:audio_service/audio_service.dart';

enum TrackSource { local, nas }

class Track {
  final String id;
  final String title;
  final String artist;
  final String album;
  final Duration duration;
  final String filePath;
  final String? artworkPath;
  final String? artworkUrl;
  final String format;
  final int? bitDepth;
  final int? sampleRate;
  final int? bitrate;
  final TrackSource source;
  final String? nasVendor;

  const Track({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    required this.filePath,
    required this.source,
    this.artworkPath,
    this.artworkUrl,
    this.format = '',
    this.bitDepth,
    this.sampleRate,
    this.bitrate,
    this.nasVendor,
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
          if (bitDepth != null) 'bitDepth': bitDepth,
          if (sampleRate != null) 'sampleRate': sampleRate,
        },
      );

  String get formatLabel {
    final parts = <String>[];
    if (format.isNotEmpty) parts.add(format.toUpperCase());
    if (bitDepth != null) parts.add('${bitDepth}-bit');
    if (sampleRate != null) parts.add('${(sampleRate! / 1000).toStringAsFixed(1)}kHz');
    return parts.join(' / ');
  }

  Track copyWith({
    String? title,
    String? artist,
    String? album,
    Duration? duration,
    String? artworkPath,
    String? artworkUrl,
    String? format,
    int? bitDepth,
    int? sampleRate,
    int? bitrate,
  }) =>
      Track(
        id: id,
        title: title ?? this.title,
        artist: artist ?? this.artist,
        album: album ?? this.album,
        duration: duration ?? this.duration,
        filePath: filePath,
        source: source,
        artworkPath: artworkPath ?? this.artworkPath,
        artworkUrl: artworkUrl ?? this.artworkUrl,
        format: format ?? this.format,
        bitDepth: bitDepth ?? this.bitDepth,
        sampleRate: sampleRate ?? this.sampleRate,
        bitrate: bitrate ?? this.bitrate,
        nasVendor: nasVendor,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Track && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
