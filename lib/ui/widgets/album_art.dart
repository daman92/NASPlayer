import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

class AlbumArt extends StatelessWidget {
  final Uri? artUri;
  final double size;
  final double borderRadius;

  /// When true and no artwork exists, show animated sound bars instead of
  /// the static placeholder (used on Now Playing while audio is playing).
  final bool animate;

  const AlbumArt({
    super.key,
    required this.artUri,
    required this.size,
    this.borderRadius = 8,
    this.animate = false,
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
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.surfaceContainerHighest,
            scheme.primary.withValues(alpha: 0.25),
          ],
        ),
      ),
      child: animate
          ? _SoundBars(color: scheme.primary)
          : Icon(
              Icons.music_note,
              size: size.isFinite ? size * 0.4 : 96,
              color: scheme.onSurface.withValues(alpha: 0.35),
            ),
    );
  }
}

/// Equalizer-style animated bars for artwork-less tracks while playing.
class _SoundBars extends StatefulWidget {
  final Color color;

  const _SoundBars({required this.color});

  @override
  State<_SoundBars> createState() => _SoundBarsState();
}

class _SoundBarsState extends State<_SoundBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  static const _bars = 5;
  // Different cycle speeds per bar so the motion never looks mechanical.
  static const _speeds = [1.0, 1.7, 1.3, 2.1, 1.5];
  static const _phases = [0.0, 1.1, 2.3, 0.6, 1.8];

  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(vsync: this, duration: const Duration(seconds: 2))
          ..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 120.0;
        final barMax = height * 0.42;
        final barMin = barMax * 0.18;
        final barWidth = (constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : 120.0) *
            0.055;

        return AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final t = _controller.value * 2 * math.pi;
            return Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                for (var i = 0; i < _bars; i++) ...[
                  if (i > 0) SizedBox(width: barWidth * 0.6),
                  Container(
                    width: barWidth,
                    height: barMin +
                        (barMax - barMin) *
                            (0.5 +
                                0.5 *
                                    math.sin(t * _speeds[i] + _phases[i])),
                    decoration: BoxDecoration(
                      color: widget.color.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(barWidth / 2),
                    ),
                  ),
                ],
              ],
            );
          },
        );
      },
    );
  }
}
