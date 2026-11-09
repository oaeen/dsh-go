// 桌面图标: adaptive-icon mask, channel, and preview against the shipped icon layer.

import 'dart:io';
import 'dart:math' as math;

import 'package:dsh_app/state/app_icon_state.dart';
import 'package:dsh_app/ui/settings/appearance/app_icon_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A circle (a Pixel's mask), [n] points.
List<double> _circle([int n = 240]) => [
  for (var i = 0; i < n; i++) ...[0.5 + 0.5 * math.cos(2 * math.pi * i / n), 0.5 + 0.5 * math.sin(2 * math.pi * i / n)],
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('mask', () {
    test("the system's outline, scaled", () {
      final path = launcherMaskPath(_circle(), 60);
      expect(path.getBounds().width, closeTo(60, 0.01));
      expect(path.contains(const Offset(30, 30)), isTrue);
      expect(path.contains(const Offset(3, 3)), isFalse);
      expect(path.contains(const Offset(1, 30)), isTrue);
    });

    test('a rounded square without one', () {
      final path = launcherMaskPath(null, 60);
      expect(path.getBounds(), const Rect.fromLTWH(0, 0, 60, 60));
      expect(path.contains(const Offset(0.5, 0.5)), isFalse);
      expect(path.contains(const Offset(3, 30)), isTrue);
      expect(launcherMaskPath(const [0.5, 0.5], 60).getBounds().width, closeTo(60, 0.01));
    });
  });

  group('channel', () {
    const name = 'dsh/launcher_icon';
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(const MethodChannel(name), null));

    void answer(Object? Function(MethodCall call) reply) =>
        messenger.setMockMethodCallHandler(const MethodChannel(name), (call) async => reply(call));

    test('state', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      answer((_) => {'current': 'mist', 'mask': _circle(8)});
      final state = await const LauncherIconChannel().state();
      expect(state?.current, AppIcon.mist);
      expect(state?.mask, hasLength(16));
      answer((_) => {'current': 'mist', 'mask': null});
      expect((await const LauncherIconChannel().state())?.mask, isNull);
      answer(
        (_) => {
          'current': 'mist',
          'mask': [0.1, 'x'],
        },
      );
      expect((await const LauncherIconChannel().state())?.mask, isNull);
      answer((_) => {'current': 'rainbow'});
      expect(await const LauncherIconChannel().state(), isNull);
      answer((_) => throw PlatformException(code: 'failed'));
      expect(await const LauncherIconChannel().state(), isNull);
      messenger.setMockMethodCallHandler(const MethodChannel(name), null);
      expect(await const LauncherIconChannel().state(), isNull);
    });

    test('set', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      MethodCall? seen;
      answer((call) {
        seen = call;
        return {'current': 'mist'};
      });
      expect(await const LauncherIconChannel().set(AppIcon.mist), AppIcon.mist);
      expect(seen?.method, 'set');
      expect(seen?.arguments, {'id': 'mist'});
      answer((_) => throw PlatformException(code: 'failed'));
      expect(await const LauncherIconChannel().set(AppIcon.mist), isNull);
    });
  });

  group('the preview matches the shipped icon', () {
    const res = 'android/app/src/main/res';

    test('background gradient', () {
      for (final icon in AppIcon.values) {
        final file = icon == AppIcon.mist ? 'ic_launcher_background' : 'ic_launcher_${icon.name}_background';
        final xml = File('$res/drawable/$file.xml').readAsStringSync();
        double attr(String a) => double.parse(RegExp('android:$a="([-0-9.]+)"').firstMatch(xml)!.group(1)!);
        final colors = [
          for (final m in RegExp('android:color="#([0-9A-Fa-f]{8})"').allMatches(xml))
            Color(int.parse(m.group(1)!, radix: 16)),
        ];
        final art = AppIconArt.of(icon);
        expect(colors, [art.from, art.to], reason: file);
        expect(Offset(attr('startX'), attr('startY')), AppIconArt.start, reason: file);
        expect(Offset(attr('endX'), attr('endY')), AppIconArt.end, reason: file);
      }
    });
  });
}
