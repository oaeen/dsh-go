// The feature tiles (lib/ui/common/feature_tile.dart).
//
// - The generated shapes: every feature in the duotone vector style, inside the grid's
//   safe area, centred, in two tones only.
// - The palette: every tone from the theme, readable on the card for every accent
//   and identity hue, in light and dark.
// - Golden sheets: the default style at the app's sizes; every accent; every
//   identity hue.
//
//   flutter test test/tiles/feature_tile_test.dart

import 'package:dsh_app/ui/common/feature_tile.dart';
import 'package:dsh_app/ui/common/feature_tile_shapes.g.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

/// The presets, and two custom colours (any hue can be picked).
final _accents = [
  ...AppAccent.presets,
  AppAccent.derive(const Color(0xFFD9467A), label: '自定义'),
  AppAccent.derive(const Color(0xFF3E9E5B), label: '自定义'),
];

/// Ink bounds of a tile in the 96 grid, strokes included, cuts ignored: measured
/// on the outlines (`Path.getBounds` counts curve control points).
Rect _bounds(TileArt art) {
  Rect? box;
  for (final layer in art.layers) {
    for (final shape in layer.shapes) {
      for (final metric in shape.path.computeMetrics()) {
        for (var d = 0.0; d <= metric.length; d += 0.1) {
          final p = metric.getTangentForOffset(d)!.position;
          final r = Rect.fromCircle(center: p, radius: shape.stroke / 2);
          box = box == null ? r : box.expandToInclude(r);
        }
      }
    }
  }
  return box!;
}

void main() {
  group('shapes', () {
    test('every feature in the safe area, centred', () {
      for (final kind in FeatureKind.values) {
        final box = _bounds(DuotoneTiles.of(kind));
        final where = 'duotone/${kind.name}: $box';
        // 4 units clear of the edge (1.5dp at 36dp) on every side.
        expect(box.left >= 4 && box.top >= 4 && box.right <= 92 && box.bottom <= 92, isTrue, reason: where);
        // The longer side spans 76–88 units: one keyline for the set.
        expect(box.longestSide, inInclusiveRange(76, 88), reason: where);
        // Centred within 2.5 units (the automation arrow hangs out on purpose).
        expect((box.center.dx - 48).abs(), lessThanOrEqualTo(2.6), reason: where);
        expect((box.center.dy - 48).abs(), lessThanOrEqualTo(2), reason: where);
      }
    });

    test('duotone uses two tones', () {
      for (final kind in FeatureKind.values) {
        final tones = {
          for (final layer in DuotoneTiles.of(kind).layers)
            for (final shape in layer.shapes) shape.tone,
        };
        expect(tones, {TileTone.wash, TileTone.ink}, reason: kind.name);
      }
    });

    test('cut shapes only live in cut layers', () {
      for (final kind in FeatureKind.values) {
        for (final layer in DuotoneTiles.of(kind).layers) {
          expect(layer.shapes.every((s) => s.tone != null), isTrue);
          expect(layer.cuts.every((s) => s.tone == null), isTrue);
        }
      }
    });
  });

  group('palette', () {
    final schemes = [
      for (final accent in _accents)
        for (final b in Brightness.values) ('${accent.label} ${accent.seed}', b, tileTheme(b, accent)),
    ];

    test('the accent palette is made of the scheme\'s tokens', () {
      final light = tileTheme(Brightness.light).colorScheme;
      final p = TilePalette.accent(light);
      expect(p.ink, light.primary);
      expect(p.mid, light.inversePrimary);
      expect(p.on, light.primaryContainer);
      expect(p.wash, Color.lerp(light.inversePrimary, light.primaryContainer, 0.5));
      final dark = tileTheme(Brightness.dark).colorScheme;
      final d = TilePalette.accent(dark);
      expect(d.ink, dark.primary);
      expect(d.on, dark.onPrimary);
    });

    test('every tone reads on the card, for every accent and identity hue', () {
      void check(String where, TilePalette p, ColorScheme scheme) {
        final card = TilePalette.card(scheme);
        final ink = TilePalette.contrast(p.ink, card);
        final mid = TilePalette.contrast(p.mid, card);
        final wash = TilePalette.contrast(p.wash, card);
        expect(wash, greaterThanOrEqualTo(TilePalette.washContrast), reason: '$where wash $wash');
        expect(mid, greaterThanOrEqualTo(TilePalette.midContrast), reason: '$where mid $mid');
        expect(ink, greaterThanOrEqualTo(3), reason: '$where ink $ink');
        // The hierarchy holds: ink > mid > wash against the card.
        expect(ink > mid && mid > wash, isTrue, reason: '$where $ink $mid $wash');
        // Details on ink stand out from it.
        expect(TilePalette.contrast(p.on, p.ink), greaterThanOrEqualTo(3), reason: '$where on');
      }

      for (final (name, b, theme) in schemes) {
        check('$name ${b.name}', TilePalette.accent(theme.colorScheme), theme.colorScheme);
      }
      for (final b in Brightness.values) {
        final theme = tileTheme(b);
        final colors = theme.extension<DshColors>()!;
        for (var slot = 0; slot < colors.identity.length; slot++) {
          check('identity $slot ${b.name}', TilePalette.identity(colors, slot, theme.colorScheme), theme.colorScheme);
        }
      }
    });
  });

  group('widget', () {
    testWidgets('renders duotone vector tile; decorative unless labelled', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        tileApp(
          const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FeatureTile(FeatureKind.terminal, size: 48),
                FeatureTile(FeatureKind.phone, size: 48, semanticLabel: '手机操控'),
              ],
            ),
          ),
        ),
      );
      expect(tester.getSize(find.byType(FeatureTile).first), const Size.square(48));
      expect(find.byType(Image), findsNothing);
      expect(find.bySemanticsLabel('手机操控'), findsOneWidget);
    });
  });

  for (final brightness in Brightness.values) {
    final mode = brightness.name;
    group('goldens ($mode)', () {
      setUp(() => SharedPreferences.setMockInitialValues({}));

      testWidgets('default style at card, compact and empty-state sizes', (tester) async {
        useView(tester, 820, 700);
        await tester.pumpWidget(tileApp(const _StyleSheet(), brightness: brightness));
        await decodeImages(tester);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/tiles_$mode.png'));
      });

      testWidgets('every accent', (tester) async {
        useView(tester, 620, 500);
        await tester.pumpWidget(tileApp(_AccentSheet(brightness), brightness: brightness));
        await decodeImages(tester);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/tiles_accents_$mode.png'));
      });

      testWidgets('every identity hue', (tester) async {
        useView(tester, 620, 500);
        await tester.pumpWidget(tileApp(const _IdentitySheet(), brightness: brightness));
        await decodeImages(tester);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/tiles_identity_$mode.png'));
      });
    });
  }
}

const _sampleKinds = [FeatureKind.terminal, FeatureKind.automation, FeatureKind.community];

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => GlassSurface(
    tier: GlassTier.card,
    borderRadius: AppShape.radiusLg,
    child: Padding(padding: const EdgeInsets.all(14), child: child),
  );
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 64,
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(color: DshColors.of(context).textTertiary),
    ),
  );
}

Widget _row(List<Widget> children, {double gap = 12}) => Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    for (final (i, c) in children.indexed) ...[if (i > 0) SizedBox(width: gap), c],
  ],
);

/// The nine features at 64 (empty states), at 48 (compact) and at 36 (cards).
class _StyleSheet extends StatelessWidget {
  const _StyleSheet();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Card(
          child: Row(
            children: [
              const _Label('双色'),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final size in [FeatureTile.empty, FeatureTile.compact, FeatureTile.card]) ...[
                    _row([
                      for (final kind in FeatureKind.values) FeatureTile(kind, size: size),
                    ], gap: 76 - size),
                    const SizedBox(height: 8),
                  ],
                ],
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// One row per accent, each in its own theme: three features.
class _AccentSheet extends StatelessWidget {
  const _AccentSheet(this.brightness);

  final Brightness brightness;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final accent in _accents)
            Theme(
              data: tileTheme(brightness, accent),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    _Label(accent.label),
                    _row([for (final kind in _sampleKinds) FeatureTile(kind, size: 40)], gap: 8),
                  ],
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

/// One row per identity hue: three features.
class _IdentitySheet extends StatelessWidget {
  const _IdentitySheet();

  @override
  Widget build(BuildContext context) {
    final colors = DshColors.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var slot = 0; slot < colors.identity.length; slot++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    _Label('identity $slot'),
                    _row([
                      for (final kind in _sampleKinds) FeatureTile(kind, size: 40, tint: slot),
                    ], gap: 8),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
