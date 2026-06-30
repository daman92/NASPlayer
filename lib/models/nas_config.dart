enum NasVendor { synology, qnap, nextcloud, truenas, generic, unknown }

class NasConfig {
  final String id;
  final String name;
  final String baseUrl;
  final NasVendor vendor;
  final bool isActive;
  final DateTime addedAt;

  const NasConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.vendor,
    this.isActive = false,
    required this.addedAt,
  });

  String get displayName => name.isNotEmpty ? name : baseUrl;

  NasConfig copyWith({
    String? name,
    String? baseUrl,
    NasVendor? vendor,
    bool? isActive,
  }) =>
      NasConfig(
        id: id,
        name: name ?? this.name,
        baseUrl: baseUrl ?? this.baseUrl,
        vendor: vendor ?? this.vendor,
        isActive: isActive ?? this.isActive,
        addedAt: addedAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'vendor': vendor.name,
        'isActive': isActive,
        'addedAt': addedAt.toIso8601String(),
      };

  factory NasConfig.fromJson(Map<String, dynamic> json) => NasConfig(
        id: json['id'] as String,
        name: json['name'] as String,
        baseUrl: json['baseUrl'] as String,
        vendor: NasVendor.values.firstWhere(
          (v) => v.name == json['vendor'],
          orElse: () => NasVendor.unknown,
        ),
        isActive: json['isActive'] as bool? ?? false,
        addedAt: DateTime.parse(json['addedAt'] as String),
      );
}

class NasFileEntry {
  final String name;
  final String path;
  final bool isDirectory;
  final int? size;
  final DateTime? modified;
  final String? mimeType;

  const NasFileEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.size,
    this.modified,
    this.mimeType,
  });

  bool get isAudio {
    if (isDirectory) return false;
    final ext = name.split('.').last.toLowerCase();
    return const {'mp3', 'flac', 'aac', 'ogg', 'wav', 'alac', 'aiff', 'm4a', 'opus'}
        .contains(ext);
  }
}
