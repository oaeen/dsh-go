import 'package:dsh_app/state/account_state.dart';
import 'package:dsh_app/state/balance_state.dart';
import 'package:dsh_app/state/risk_notice_store.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/common/risk_notice.dart';
import 'package:dsh_app/ui/engine/engine_screen.dart';
import 'package:dsh_app/ui/phone/dnd_mode_page.dart';
import 'package:dsh_app/ui/phone/phone_control_screen.dart';
import 'package:dsh_app/ui/phone/root_mode_screen.dart';
import 'package:dsh_app/ui/settings/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account/support.dart' show FixedAccount, sampleBalance, sampleProfile;
import '../shell/golden_harness.dart' show FakeSettings;
import 'harness.dart';
import 'support.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('entry points', () {
    testWidgets('SettingsScreen shows explicit Root 模式 entry and navigates to RootModeScreen', (tester) async {
      await pumpPhone(
        tester,
        ProviderScope(
          overrides: [
            accountWalletBalanceProvider.overrideWithValue(sampleBalance),
            accountProvider.overrideWith(
              () => FixedAccount(
                const AccountState(phase: AccountPhase.signedIn, connected: true, profile: sampleProfile),
              ),
            ),
            settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
          ],
          child: const SettingsScreen(),
        ),
        native: FakePhoneNative(
          status: phoneStatus(
            enabled: false,
            rootCli: rootCliStatus(enabled: true, listening: true, checked: true, granted: true, adbReady: true),
          ),
        ),
        size: const Size(390, 2000),
      );

      expect(find.text('Root 模式'), findsOneWidget);
      expect(find.byKey(const Key('settings-root-mode')), findsOneWidget);

      await tester.tap(find.text('Root 模式'));
      await tester.pumpAndSettle();
      expect(find.byType(RootModeScreen), findsOneWidget);
      expect(find.text('已就绪 · Root 与本机 ADB (5555) 可用'), findsOneWidget);
    });

    testWidgets('PhoneControlScreen shows Root 模式 entry even when phone control is OFF', (tester) async {
      await pumpPhone(
        tester,
        const PhoneControlScreen(),
        native: FakePhoneNative(
          status: phoneStatus(
            enabled: false,
            rootCli: rootCliStatus(enabled: false),
          ),
        ),
      );

      expect(find.text('Root 模式'), findsOneWidget);
      expect(find.text('未开启'), findsWidgets);

      await tester.tap(find.text('Root 模式'));
      await tester.pumpAndSettle();
      expect(find.byType(RootModeScreen), findsOneWidget);
    });

    testWidgets('EngineScreen shows Root 模式 entry under 更多', (tester) async {
      await pumpPhone(
        tester,
        const EngineScreen(),
        native: FakePhoneNative(
          status: phoneStatus(
            rootCli: rootCliStatus(enabled: true, listening: true, checked: true, granted: true),
          ),
        ),
        size: const Size(390, 2000),
      );

      expect(find.text('Root 模式'), findsOneWidget);
      expect(find.text('宿主机 su、本机 ADB (5555) 与 Android CLI'), findsOneWidget);
    });
  });

  group('RootModeScreen', () {
    testWidgets('first enable asks RiskNotices.rootChannel confirmation; confirming turns on Root CLI', (tester) async {
      final h = await pumpPhone(
        tester,
        const RootModeScreen(),
        native: FakePhoneNative(
          status: phoneStatus(rootCli: rootCliStatus(enabled: false)),
        ),
        size: const Size(390, 1600),
      );

      expect(find.text('未开启'), findsWidgets);
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();

      expect(find.byType(RiskNoticeSheet), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('risk-confirm')));
      await tester.pumpAndSettle();

      expect(h.native!.callsOf('setRootCliEnabled').single.arguments, {'enabled': true});
      expect(find.text('已就绪 · Root 已授权'), findsOneWidget);
      expect(find.text('已获 Root 授权 (uid=0)'), findsOneWidget);
    });

    testWidgets('testRootCli and bootstrapRootAdb buttons trigger su check and local adbd bootstrap', (tester) async {
      await const PrefsRiskNoticeStore().silence(RiskNotices.rootChannel.id);
      final h = await pumpPhone(
        tester,
        const RootModeScreen(),
        native: FakePhoneNative(
          status: phoneStatus(
            rootCli: rootCliStatus(enabled: true, listening: true, checked: false),
          ),
        ),
        size: const Size(390, 1600),
      );

      expect(find.text('通过 Magisk、KernelSU 或 APatch 授权宿主机 su'), findsOneWidget);
      await tester.tap(find.text('申请授权'));
      await tester.pumpAndSettle();
      expect(h.native!.callsOf('testRootCli'), hasLength(1));
      expect(find.text('已获 Root 授权 (uid=0)'), findsWidgets);

      expect(find.text('一键开启本机 adbd 环回端口并自动注入容器公钥，免无线调试配对'), findsOneWidget);
      await tester.tap(find.text('启动 ADB'));
      await tester.pumpAndSettle();
      expect(h.native!.callsOf('bootstrapRootAdb'), hasLength(1));
      expect(find.text('127.0.0.1:5555 已就绪，容器内 adb 与 android 直连'), findsOneWidget);
    });

    testWidgets('links to PhoneDndPage and copies CLI snippets', (tester) async {
      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await pumpPhone(
        tester,
        const RootModeScreen(),
        native: FakePhoneNative(
          status: phoneStatus(
            rootCli: rootCliStatus(enabled: true, listening: true, checked: true, granted: true),
          ),
        ),
        size: const Size(390, 1600),
      );

      await tester.tap(find.text('host-su -c "id"'));
      await tester.pumpAndSettle();
      expect(copied, 'host-su -c "id"');
      expect(find.text('命令已复制'), findsOneWidget);

      await tester.tap(find.text('不打扰模式'));
      await tester.pumpAndSettle();
      expect(find.byType(PhoneDndPage), findsOneWidget);
    });
  });
}
