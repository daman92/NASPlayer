import 'package:flutter/material.dart';

import '../../models/track.dart';
import '../../utils/format_utils.dart';
import 'album_art.dart';

class TrackTile extends StatelessWidget {
  final Track track;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool isSelected;
  final bool isSelecting;
  final bool isCurrent;
  final int? position;
  final int? total;

  const TrackTile({
    super.key,
    required this.track,
    this.onTap,
    this.onLongPress,
    this.isSelected = false,
    this.isSelecting = false,
    this.isCurrent = false,
    this.position,
    this.total,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      color: isSelected
          ? theme.colorScheme.primary.withValues(alpha: 0.15)
          : Colors.transparent,
      child: ListTile(
        leading: isSelecting
            ? AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: isSelected
                    ? CircleAvatar(
                        backgroundColor: theme.colorScheme.primary,
                        radius: 20,
                        child: const Icon(Icons.check,
                            color: Colors.white, size: 18),
                      )
                    : CircleAvatar(
                        backgroundColor: theme.colorScheme.surfaceContainerHighest,
                        radius: 20,
                        child: Text(
                          position != null ? '$position' : '',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
              )
            : SizedBox(
                width: 40,
                height: 40,
                child: isCurrent
                    ? CircleAvatar(
                        backgroundColor:
                            theme.colorScheme.primary.withValues(alpha: 0.15),
                        child: Icon(Icons.equalizer,
                            color: theme.colorScheme.primary, size: 20),
                      )
                    : track.artworkPath != null
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: AlbumArt(
                              artUri: track.artworkPath != null
                                  ? Uri.file(track.artworkPath!)
                                  : null,
                              size: 40,
                            ),
                          )
                        : CircleAvatar(
                            backgroundColor: theme.colorScheme.surfaceContainerHighest,
                            child: Text(
                              position != null ? '$position' : '',
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
              ),
        title: Text(
          track.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: isCurrent
              ? theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                )
              : null,
        ),
        subtitle: Text(
          track.artist.isNotEmpty ? track.artist : track.album,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall,
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              FormatUtils.formatDuration(track.duration),
              style: theme.textTheme.bodySmall,
            ),
            if (track.format.isNotEmpty)
              Text(
                track.format.toUpperCase(),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontSize: 10,
                ),
              ),
          ],
        ),
        onTap: onTap,
        onLongPress: onLongPress,
      ),
    );
  }
}
