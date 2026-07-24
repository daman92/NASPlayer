/// Extracts title/artist hints from a filename when tags are missing.
///
/// Handles the common conventions:
///   "01 - Artist - Title", "01. Title", "Artist - Title",
///   "Artist_-_Title", "07 Title"
class ParsedFilename {
  final String title;
  final String? artist;

  const ParsedFilename({required this.title, this.artist});
}

ParsedFilename parseTrackFilename(String nameWithoutExtension) {
  var s = nameWithoutExtension.replaceAll('_', ' ').trim();

  // Strip a leading track number ("01", "01.", "01 -", "1-02 ").
  s = s.replaceFirst(RegExp(r'^\s*\d{1,3}([-.]\d{1,3})?\s*[-–.]?\s+'), '');
  if (s.isEmpty) s = nameWithoutExtension.replaceAll('_', ' ').trim();

  // "Artist - Title" (en/em dashes too). Use the FIRST separator so
  // "Artist - Title - Live" keeps the suffix in the title.
  final match = RegExp(r'^(.{1,80}?)\s+[-–—]\s+(.+)$').firstMatch(s);
  if (match != null) {
    final artist = match.group(1)!.trim();
    final title = match.group(2)!.trim();
    final artistIsJustANumber = RegExp(r'^\d+$').hasMatch(artist);
    if (artist.isNotEmpty && title.isNotEmpty && !artistIsJustANumber) {
      return ParsedFilename(title: title, artist: artist);
    }
  }

  return ParsedFilename(title: s);
}
