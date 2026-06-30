class Playlist {
  final String id;
  final String name;
  final List<String> trackIds;
  final List<String> trackPaths;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? coverArtPath;

  const Playlist({
    required this.id,
    required this.name,
    required this.trackIds,
    required this.trackPaths,
    required this.createdAt,
    required this.updatedAt,
    this.coverArtPath,
  });

  int get trackCount => trackPaths.length;

  Playlist copyWith({
    String? name,
    List<String>? trackIds,
    List<String>? trackPaths,
    DateTime? updatedAt,
    String? coverArtPath,
  }) =>
      Playlist(
        id: id,
        name: name ?? this.name,
        trackIds: trackIds ?? List.from(this.trackIds),
        trackPaths: trackPaths ?? List.from(this.trackPaths),
        createdAt: createdAt,
        updatedAt: updatedAt ?? DateTime.now(),
        coverArtPath: coverArtPath ?? this.coverArtPath,
      );

  Playlist withTrackAdded(String trackId, String trackPath) => copyWith(
        trackIds: [...trackIds, trackId],
        trackPaths: [...trackPaths, trackPath],
        updatedAt: DateTime.now(),
      );

  Playlist withTrackRemoved(int index) {
    final newIds = List<String>.from(trackIds)..removeAt(index);
    final newPaths = List<String>.from(trackPaths)..removeAt(index);
    return copyWith(trackIds: newIds, trackPaths: newPaths, updatedAt: DateTime.now());
  }

  Playlist withTracksReordered(int oldIndex, int newIndex) {
    final newIds = List<String>.from(trackIds);
    final newPaths = List<String>.from(trackPaths);
    final id = newIds.removeAt(oldIndex);
    final path = newPaths.removeAt(oldIndex);
    final adjusted = oldIndex < newIndex ? newIndex - 1 : newIndex;
    newIds.insert(adjusted, id);
    newPaths.insert(adjusted, path);
    return copyWith(trackIds: newIds, trackPaths: newPaths, updatedAt: DateTime.now());
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'trackIds': trackIds,
        'trackPaths': trackPaths,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'coverArtPath': coverArtPath,
      };

  factory Playlist.fromJson(Map<String, dynamic> json) => Playlist(
        id: json['id'] as String,
        name: json['name'] as String,
        trackIds: List<String>.from(json['trackIds'] as List),
        trackPaths: List<String>.from(json['trackPaths'] as List),
        createdAt: DateTime.parse(json['createdAt'] as String),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
        coverArtPath: json['coverArtPath'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Playlist && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
