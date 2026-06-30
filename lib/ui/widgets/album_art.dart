import 'dart:io';

import 'package:flutter/material.dart';

class AlbumArt extends StatelessWidget {
  final Uri? artUri;
  final double size;
  final double borderRadius;

  const AlbumArt({
    super.key,
    required this.artUri,
    required this.size,
    this.borderRadius = 8,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: _buildImage(context),
    );
  }

  Widget _buildImage(BuildContext context) {
    if (artUri == null) {
      return _placeholder(context);
    }

    if (artUri!.scheme == 'file') {
      return Image.file(
        File(artUri!.toFilePath()),
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _placeholder(context),
      );
    }

    if (artUri!.scheme == 'http' || artUri!.scheme == 'https') {
      return Image.network(
        artUri!.toString(),
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _placeholder(context),
        loadingBuilder: (_, child, progress) {
          if (progress == null) return child;
          return _placeholder(context);
        },
      );
    }

    return _placeholder(context);
  }

  Widget _placeholder(BuildContext context) {
    return Container(
      width: size,
      height: size,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.music_note,
        size: size * 0.4,
        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.3),
      ),
    );
  }
}
