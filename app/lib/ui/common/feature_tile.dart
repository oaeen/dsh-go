// The big graphics of the nine headline features (their empty states,
// the phone page's overview).
//
// Flat duotone vectors: SVG masters in assets/tiles/duotone/, turned into paths
// by tool/make_feature_tiles.py (feature_tile_shapes.g.dart). Every colour is a
// tone of the theme's accent.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/theme.dart';
import 'feature_tile_shapes.g.dart';

export 'feature_tile_shapes.g.dart' show FeatureKind;

/// One feature's graphic, [size] square.
///
/// ```dart
/// FeatureTile(FeatureKind.automation, size: FeatureTile.empty)
/// ```
///
/// - Colours follow the accent and switch with light / dark; [tint] takes one of
///   the 8 identity hues (`DshColors.identity`) instead.
/// - Decorative unless [semanticLabel] is given: a title always sits next to it.
class FeatureTile extends StatelessWidget {
  const FeatureTile(this.kind, {super.key, this.size = 48, this.tint, this.semanticLabel});

  final FeatureKind kind;
  final double size;
  final int? tint;
  final String? semanticLabel;

  /// In a feature card (the circle badge it replaces is 36 too).
  static const card = 36.0;

  /// Over an empty state, in place of `EmptyView`'s 64 badge.
  static const empty = 64.0;

  /// Over a compact empty state (a sheet), in place of the 48 badge.
  static const compact = 48.0;

  @override
  Widget build(BuildContext context) {
    final palette = TilePalette.of(context, tint: tint);
    final Widget art = _VectorTile(art: DuotoneTiles.of(kind), size: size, palette: palette);
    final label = semanticLabel;
    return label == null ? ExcludeSemantics(child: art) : Semantics(label: label, image: true, child: art);
  }
}

/// The four tones of a tile, from the theme.
///
/// Hierarchy is contrast with the card the tile sits on: [ink] stands out most,
/// [wash] least but still reads (≥ [washContrast]; a 1.2 : 1 tint vanishes on
/// white). So in light the body is the deep accent and the back
/// shapes are light; in dark the body is the light accent and the back shapes are
/// deep, like the app's own filled buttons. A tone that falls short (a quiet
/// accent such as 石墨) is pushed toward [ink] until it reads.
@immutable
class TilePalette {
  const TilePalette({required this.wash, required this.mid, required this.ink, required this.on});

  final Color wash;
  final Color mid;
  final Color ink;

  /// Details on [ink].
  final Color on;

  /// Least contrast of [wash] and [mid] with the card.
  static const washContrast = 1.5;
  static const midContrast = 2.0;

  /// The accent: `primary`, `inversePrimary` (the accent's other-brightness
  /// tone) and `primaryContainer`.
  factory TilePalette.accent(ColorScheme scheme) {
    final p = scheme.primary;
    final other = scheme.inversePrimary;
    final container = scheme.primaryContainer;
    if (scheme.brightness == Brightness.dark) {
      return _readable(
        card(scheme),
        ink: p,
        mid: Color.lerp(p, other, 0.55)!,
        wash: Color.lerp(other, container, 0.4)!,
        on: scheme.onPrimary,
      );
    }
    return _readable(card(scheme), ink: p, mid: other, wash: Color.lerp(other, container, 0.5)!, on: container);
  }

  /// One identity hue: its container and on-container (`DshColors.identity` /
  /// `onIdentity`), mixed the same way.
  factory TilePalette.identity(DshColors colors, int slot, ColorScheme scheme) {
    final i = slot % colors.identity.length;
    final container = colors.identity[i];
    final strong = colors.onIdentity[i];
    if (scheme.brightness == Brightness.dark) {
      return _readable(
        card(scheme),
        ink: Color.lerp(strong, container, 0.1)!,
        mid: Color.lerp(strong, container, 0.45)!,
        wash: Color.lerp(container, strong, 0.22)!,
        on: container,
      );
    }
    return _readable(
      card(scheme),
      ink: Color.lerp(strong, container, 0.3)!,
      mid: Color.lerp(strong, container, 0.58)!,
      wash: Color.lerp(container, strong, 0.2)!,
      on: container,
    );
  }

  /// The card a tile is checked against: the lightest surface in light, the
  /// lightest dark one in dark (the hardest case either way).
  static Color card(ColorScheme scheme) =>
      scheme.brightness == Brightness.dark ? scheme.surfaceContainerHighest : scheme.surfaceContainerLowest;

  static TilePalette _readable(
    Color card, {
    required Color ink,
    required Color mid,
    required Color wash,
    required Color on,
  }) => TilePalette(
    ink: ink,
    mid: _atLeast(mid, ink, card, midContrast),
    wash: _atLeast(wash, ink, card, washContrast),
    on: on,
  );

  static Color _atLeast(Color color, Color toward, Color card, double ratio) {
    for (var t = 0.0; t < 1; t += 0.04) {
      final c = Color.lerp(color, toward, t)!;
      if (contrast(c, card) >= ratio) return c;
    }
    return toward;
  }

  /// WCAG contrast ratio of [a] and [b].
  static double contrast(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }

  /// The accent's palette, or identity hue [tint]'s.
  static TilePalette of(BuildContext context, {int? tint}) {
    final theme = Theme.of(context);
    return tint == null
        ? TilePalette.accent(theme.colorScheme)
        : TilePalette.identity(DshColors.of(context), tint, theme.colorScheme);
  }

  Color operator [](TileTone tone) => switch (tone) {
    TileTone.wash => wash,
    TileTone.mid => mid,
    TileTone.ink => ink,
    TileTone.on => on,
  };

  @override
  bool operator ==(Object other) =>
      other is TilePalette && other.wash == wash && other.mid == mid && other.ink == ink && other.on == on;

  @override
  int get hashCode => Object.hash(wash, mid, ink, on);
}

class _VectorTile extends StatelessWidget {
  const _VectorTile({required this.art, required this.size, required this.palette});

  final TileArt art;
  final double size;
  final TilePalette palette;

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: TilePainter(art, palette));
}

/// Draws a [TileArt] scaled to the canvas, its tones from [palette].
class TilePainter extends CustomPainter {
  const TilePainter(this.art, this.palette);

  final TileArt art;
  final TilePalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    const grid = Rect.fromLTWH(0, 0, TileArt.grid, TileArt.grid);
    canvas.save();
    canvas.scale(size.width / TileArt.grid, size.height / TileArt.grid);
    for (final layer in art.layers) {
      final cut = layer.cuts.isNotEmpty;
      // A layer of its own so a cut erases this layer's shapes and nothing under them.
      if (cut) canvas.saveLayer(grid.inflate(8), Paint());
      for (final shape in layer.shapes) {
        _draw(canvas, shape, Paint()..color = palette[shape.tone!]);
      }
      for (final shape in layer.cuts) {
        _draw(canvas, shape, Paint()..blendMode = BlendMode.clear);
      }
      if (cut) canvas.restore();
    }
    canvas.restore();
  }

  static void _draw(Canvas canvas, TileShape shape, Paint paint) {
    if (shape.fill) canvas.drawPath(shape.path, paint..style = PaintingStyle.fill);
    if (shape.stroke > 0) {
      canvas.drawPath(
        shape.path,
        paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = shape.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  @override
  bool shouldRepaint(TilePainter old) => old.art != art || old.palette != palette;
}
