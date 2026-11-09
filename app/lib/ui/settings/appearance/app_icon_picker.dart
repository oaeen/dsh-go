// Previews the launcher icon (桌面图标) and its adaptive-icon mask, for the
// launch screen miniature and the home-screen shortcut sheet.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../state/app_icon_state.dart';
import '../../shell/brand_glyph.g.dart';

/// How the launcher icon is drawn: the gradient of its background layer
/// (`res/drawable/ic_launcher_background.xml`) and its glyph.
class AppIconArt {
  const AppIconArt._(this.from, this.to, this.glyph, [this.mono]);

  /// Top-left and bottom-right of the background gradient.
  final Color from;
  final Color to;
  final AppIconGlyph glyph;

  /// The flat glyph colour, for [AppIconGlyph.mono].
  final Color? mono;

  /// The gradient's ends in the launcher's 108 grid (ic_launcher_background.xml).
  static const start = Offset(7.57, -5.87);
  static const end = Offset(100.43, 113.87);

  static AppIconArt of(AppIcon icon) => switch (icon) {
    // Default icon: official DeepSeek Harness white-background black-whale (白底黑鱼).
    AppIcon.mist => const AppIconArt._(Color(0xFFFFFFFF), Color(0xFFF8F9FB), AppIconGlyph.mono, Color(0xFF0A0A0A)),
  };
}

/// The brand glyph's renderings (`assets/brand/glyph-*.svg`).
enum AppIconGlyph { glassDark, glassLight, mono }

/// [icon] as the launcher shows it: [size] square, cut to [mask] (an outline
/// in 0…1, see [AppIconState.mask]; a rounded square when null), with a
/// hairline inside its edge so the light icon keeps its shape on a light card.
class AppIconPreview extends StatelessWidget {
  const AppIconPreview(this.icon, {super.key, this.size = maxIcon, this.mask});

  /// Icons are at most this big (a launcher's own size).
  static const maxIcon = 56.0;

  final AppIcon icon;
  final double size;
  final List<double>? mask;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: _IconPainter(icon, mask, Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08)),
  );
}

class _IconPainter extends CustomPainter {
  const _IconPainter(this.icon, this.mask, this.edge);

  final AppIcon icon;
  final List<double>? mask;
  final Color edge;

  @override
  void paint(Canvas canvas, Size size) {
    final art = AppIconArt.of(icon);
    final clip = launcherMaskPath(mask, size.width);
    canvas
      ..save()
      ..clipPath(clip)
      ..save()
      // The visible 72 of the 108 grid, as on the launcher.
      ..scale(size.width / 72)
      ..translate(-18, -18)
      ..drawRect(
        const Rect.fromLTWH(0, 0, 108, 108),
        Paint()..shader = ui.Gradient.linear(AppIconArt.start, AppIconArt.end, [art.from, art.to]),
      );
    switch (art.glyph) {
      case AppIconGlyph.mono:
        final paint = Paint()..color = art.mono!;
        canvas.drawPath(BrandGlyph.body, paint);
      case AppIconGlyph.glassDark || AppIconGlyph.glassLight:
        final dark = art.glyph == AppIconGlyph.glassDark;
        canvas.drawPath(BrandGlyph.body, Paint()..shader = dark ? BrandGlyph.tailDark : BrandGlyph.tailLight);
    }
    canvas
      ..restore()
      // Half of it falls outside the clip: a 1 px line just inside the edge.
      ..drawPath(
        clip,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = edge,
      )
      ..restore();
  }

  @override
  bool shouldRepaint(_IconPainter old) => old.icon != icon || old.mask != mask || old.edge != edge;
}

/// The launcher's icon shape at [side] × [side]: [mask] (a closed outline in
/// 0…1 from the system) or, without one, a rounded square.
Path launcherMaskPath(List<double>? mask, double side) {
  if (mask == null || mask.length < 6) {
    return RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(side * 0.32))
        .getOuterPath(Rect.fromLTWH(0, 0, side, side));
  }
  final path = Path()..moveTo(mask[0] * side, mask[1] * side);
  for (var i = 2; i + 1 < mask.length; i += 2) {
    path.lineTo(mask[i] * side, mask[i + 1] * side);
  }
  return path..close();
}
