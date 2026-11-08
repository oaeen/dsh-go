import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/phone_state.dart';
import '../common/brief_notice.dart';
import '../common/list_page_row.dart';
import '../common/overview_card.dart';
import '../common/risk_notice.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'dnd_mode_page.dart';
import 'phone_widgets.dart';

/// One-line summary of Root mode for settings rows and cards.
String rootModeSummary(PhoneRootCliStatus rootCli, L10n l10n) {
  if (!rootCli.enabled) return l10n.phoneControlNotEnabled;
  if (rootCli.adbReady) return l10n.phoneRootModeReadyWithAdb;
  if (rootCli.granted == true) return l10n.phoneRootModeReady;
  if (rootCli.reason != null) return rootCli.reason!;
  return l10n.phoneRootModeEnabledPending;
}

/// 设置 → Root 模式: host `su` bridge (`host-su`), local loopback ADB
/// (`127.0.0.1:5555`, `dsh-adb-bootstrap`) and `dsh-android-cli-install`.
class RootModeScreen extends ConsumerStatefulWidget {
  const RootModeScreen({super.key});

  @override
  ConsumerState<RootModeScreen> createState() => _RootModeScreenState();
}

class _RootModeScreenState extends ConsumerState<RootModeScreen> {
  bool _toggling = false;
  bool _testingSu = false;
  bool _startingAdb = false;

  PhoneController get _phone => ref.read(phoneProvider.notifier);

  Future<void> _onToggle(bool next) async {
    if (_toggling) return;
    if (next && !await confirmRisk(context, RiskNotices.rootChannel)) return;
    if (!mounted) return;
    setState(() => _toggling = true);
    final res = await _phone.setRootCliEnabled(next);
    if (!mounted) return;
    setState(() => _toggling = false);
    if (!res.ok) {
      showBriefNotice(
        context,
        res.reason ?? (next ? context.l10n.phoneEnableFailed : context.l10n.phoneDisableFailed),
      );
      return;
    }
    showBriefNotice(context, next ? context.l10n.phoneEnabled : context.l10n.phoneDisabled);
  }

  Future<void> _testSu() async {
    if (_testingSu) return;
    final rootCli = ref.read(phoneProvider).status.rootCli;
    if (rootCli.granted != true && !await confirmRisk(context, RiskNotices.rootChannel)) return;
    if (!mounted) return;
    setState(() => _testingSu = true);
    final res = await _phone.testRootCli();
    if (!mounted) return;
    setState(() => _testingSu = false);
    if (!res.ok) {
      showBriefNotice(context, res.reason ?? context.l10n.phoneActionFailedLater);
      return;
    }
    showBriefNotice(context, context.l10n.phoneRootModeSuGranted);
  }

  Future<void> _startAdb() async {
    if (_startingAdb) return;
    final rootCli = ref.read(phoneProvider).status.rootCli;
    if (rootCli.granted != true && !await confirmRisk(context, RiskNotices.rootChannel)) return;
    if (!mounted) return;
    setState(() => _startingAdb = true);
    final res = await _phone.bootstrapRootAdb();
    if (!mounted) return;
    setState(() => _startingAdb = false);
    if (!res.ok) {
      showBriefNotice(context, res.reason ?? context.l10n.phoneActionFailedLater);
      return;
    }
    showBriefNotice(context, context.l10n.phoneRootModeAdbSuccess);
  }

  Future<void> _copyCommand(String cmd) async {
    await Clipboard.setData(ClipboardData(text: cmd));
    if (mounted) showBriefNotice(context, context.l10n.phoneRootModeCommandCopied);
  }

  void _push(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final status = ref.watch(phoneProvider.select((s) => s.status));
    final rootCli = status.rootCli;
    final subtitle = rootModeSummary(rootCli, l10n);
    const gap = SizedBox(height: 24);

    return AppPage.list(
      title: l10n.phoneRootModeTitle,
      subtitle: Text(l10n.phoneRootModeSubtitle),
      children: [
        OverviewCard(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          leading: const OverviewGlyph(AppIcons.terminal, tint: 4),
          title: Text(l10n.phoneRootModeTitle),
          subtitle: AnimatedSwitcher(
            duration: AppMotion.of(context, AppMotion.quick),
            layoutBuilder: (current, previous) =>
                Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
            child: Text(subtitle, key: ValueKey(subtitle)),
          ),
          onTap: _toggling ? null : () => unawaited(_onToggle(!rootCli.enabled)),
          trailing: _toggling
              ? const SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 2, strokeCap: StrokeCap.round),
                )
              : Switch(
                  key: const Key('root-mode-switch'),
                  value: rootCli.enabled,
                  onChanged: (v) => unawaited(_onToggle(v)),
                ),
        ),
        gap,
        ListPageCard(
          title: l10n.phoneRootModeSectionStatus,
          children: [
            ListPageRow(
              key: const Key('root-mode-su-row'),
              icon: AppIcons.permissions,
              title: l10n.phoneRootModeSuTitle,
              subtitle: rootCli.granted == true
                  ? l10n.phoneRootModeSuGranted
                  : (rootCli.reason ?? l10n.phoneRootModeSuHint),
              subtitleMaxLines: 2,
              trailing: _testingSu
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, strokeCap: StrokeCap.round),
                    )
                  : FixButton(
                      label: rootCli.granted == true ? l10n.phoneRootModeSuTest : l10n.phoneRootModeSuGrant,
                      onPressed: () => unawaited(_testSu()),
                    ),
            ),
            ListPageRow(
              key: const Key('root-mode-adb-row'),
              icon: AppIcons.thisPhone,
              title: l10n.phoneRootModeAdbTitle,
              subtitle: rootCli.adbReady ? l10n.phoneRootModeAdbReady : l10n.phoneRootModeAdbHint,
              subtitleMaxLines: 2,
              trailing: _startingAdb
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, strokeCap: StrokeCap.round),
                    )
                  : FixButton(
                      label: rootCli.adbReady ? l10n.phoneRootModeAdbRestart : l10n.phoneRootModeAdbStart,
                      onPressed: () => unawaited(_startAdb()),
                    ),
            ),
            ListPageRow(
              key: const Key('root-mode-dnd-row'),
              icon: AppIcons.dndMode,
              title: l10n.phoneDndTitle,
              subtitle: dndSummary(status.background),
              onTap: () => _push(const PhoneDndPage()),
            ),
          ],
        ),
        gap,
        ListPageCard(
          title: l10n.phoneRootModeCommandsSection,
          children: [
            _CommandRow(
              command: 'host-su -c "id"',
              subtitle: l10n.phoneRootModeCmdHostSuHint,
              onCopy: () => unawaited(_copyCommand('host-su -c "id"')),
            ),
            _CommandRow(
              command: 'dsh-adb-bootstrap',
              subtitle: l10n.phoneRootModeCmdAdbHint,
              onCopy: () => unawaited(_copyCommand('dsh-adb-bootstrap')),
            ),
            _CommandRow(
              command: 'dsh-android-cli-install',
              subtitle: l10n.phoneRootModeCmdAndroidCliHint,
              onCopy: () => unawaited(_copyCommand('dsh-android-cli-install')),
            ),
          ],
        ),
      ],
    );
  }
}

class _CommandRow extends StatelessWidget {
  const _CommandRow({required this.command, required this.subtitle, required this.onCopy});

  final String command;
  final String subtitle;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return ListPageRow(
      icon: AppIcons.command,
      title: command,
      titleStyle: AppType.mono(size: 14),
      subtitle: subtitle,
      subtitleMaxLines: 2,
      trailing: Icon(AppIcons.copy, size: 18, color: DshColors.of(context).textTertiary),
      chevron: false,
      onTap: onCopy,
    );
  }
}
