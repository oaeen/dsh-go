// 订阅插件市场 (marketplace for Magpie / OpenCode auth plugins): browse the
// bundled @magpie-community/opencode-*-auth catalog or install any npm / Git
// plugin spec directly. Installed plugins automatically surface as rows in the
// 「订阅」 section on ProvidersPage.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/subscriptions_state.dart';
import '../common/list_page_row.dart';
import '../features/feature_kit.dart';
import '../features/feature_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'provider_widgets.dart';

class SubscriptionMarketPage extends ConsumerStatefulWidget {
  const SubscriptionMarketPage({super.key});

  @override
  ConsumerState<SubscriptionMarketPage> createState() => _SubscriptionMarketPageState();
}

class _SubscriptionMarketPageState extends ConsumerState<SubscriptionMarketPage> {
  final _customSpecController = TextEditingController();
  final _busySpecs = <String>{};
  bool _installingCustom = false;

  @override
  void dispose() {
    _customSpecController.dispose();
    super.dispose();
  }

  Future<void> _installSpec(String spec, {String? label, bool clearInput = false}) async {
    final trimmed = spec.trim();
    if (trimmed.isEmpty) return;
    final backend = ref.read(subscriptionBackendProvider);
    if (backend == null) return;
    setState(() {
      _busySpecs.add(trimmed);
      if (clearInput) _installingCustom = true;
    });
    try {
      await backend.installPlugin(trimmed);
      if (clearInput) _customSpecController.clear();
      ref.invalidate(subscriptionMarketProvider);
      refreshAfterSubscriptionChange(ref);
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(context.l10n.engineSubscriptionPluginInstallSuccess(label ?? trimmed))),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(context.l10n.engineSubscriptionPluginActionFailed('$error'))),
      );
    } finally {
      if (mounted) {
        setState(() {
          _busySpecs.remove(trimmed);
          if (clearInput) _installingCustom = false;
        });
      }
    }
  }

  Future<void> _removeSpec(String spec, {String? label}) async {
    final trimmed = spec.trim();
    if (trimmed.isEmpty) return;
    final backend = ref.read(subscriptionBackendProvider);
    if (backend == null) return;
    setState(() => _busySpecs.add(trimmed));
    try {
      await backend.removePlugin(trimmed);
      ref.invalidate(subscriptionMarketProvider);
      refreshAfterSubscriptionChange(ref);
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(context.l10n.engineSubscriptionPluginRemoveSuccess(label ?? trimmed))),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(context.l10n.engineSubscriptionPluginActionFailed('$error'))),
      );
    } finally {
      if (mounted) {
        setState(() => _busySpecs.remove(trimmed));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final marketAsync = ref.watch(subscriptionMarketProvider);
    final isEn = Localizations.localeOf(context).languageCode == 'en';
    const gap = SizedBox(height: 24);

    return AppPage.list(
      title: l10n.engineSubscriptionPluginMarket,
      subtitle: Text(l10n.engineSubscriptionPluginMarketSubtitle),
      children: [
        ListPageCard(
          title: l10n.engineSubscriptionPluginCustomTitle,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Row(
                children: [
                  Expanded(
                    child: ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _customSpecController,
                      builder: (context, value, _) => TextField(
                        controller: _customSpecController,
                        enabled: !_installingCustom,
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (text) => _installSpec(text, clearInput: true),
                        style: AppType.mono(),
                        decoration: InputDecoration(
                          hintText: l10n.engineSubscriptionPluginCustomHint,
                          isDense: true,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _customSpecController,
                    builder: (context, value, _) {
                      final canSubmit = value.text.trim().isNotEmpty && !_installingCustom;
                      return FilledButton.tonal(
                        onPressed: canSubmit
                            ? () => _installSpec(_customSpecController.text, clearInput: true)
                            : null,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 36),
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          shape: const StadiumBorder(),
                        ),
                        child: _installingCustom
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Text(l10n.engineSubscriptionPluginInstall),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
        gap,
        marketAsync.when(
          loading: () => const QuietSpinner(padding: EdgeInsets.symmetric(vertical: 40)),
          error: (error, _) => FeatureMessage.error(
            title: l10n.engineSubscriptionPluginMarket,
            error: error,
            onRetry: () => ref.invalidate(subscriptionMarketProvider),
          ),
          data: (plugins) {
            if (plugins.isEmpty) {
              return FeatureMessage(
                icon: AppIcons.plugin,
                title: l10n.engineSubscriptionPluginMarket,
                body: l10n.engineSubscriptionPluginMarketSubtitle,
              );
            }
            return ListPageCard(
              title: l10n.engineSubscriptionPluginMarket,
              children: [
                for (final plugin in plugins)
                  _MarketPluginRow(
                    plugin: plugin,
                    isEn: isEn,
                    busy: _busySpecs.contains(plugin.package),
                    onInstall: () => _installSpec(plugin.package, label: plugin.name),
                    onRemove: () => _removeSpec(plugin.package, label: plugin.name),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _MarketPluginRow extends StatelessWidget {
  const _MarketPluginRow({
    required this.plugin,
    required this.isEn,
    required this.busy,
    required this.onInstall,
    required this.onRemove,
  });

  final SubscriptionMarketPlugin plugin;
  final bool isEn;
  final bool busy;
  final VoidCallback onInstall;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final preferred = isEn ? plugin.summaryEn : plugin.summaryZh;
    final fallback = isEn ? plugin.summaryZh : plugin.summaryEn;
    final summary = preferred.trim().isNotEmpty ? preferred.trim() : fallback.trim();
    final subtitle = summary.isNotEmpty ? summary : plugin.package;
    return ListPageRow(
      leading: Monogram(plugin.name),
      title: plugin.name,
      subtitle: subtitle,
      subtitleMaxLines: 2,
      trailing: busy
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : plugin.installed
          ? OutlinedButton(
              onPressed: onRemove,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.standard,
                shape: const StadiumBorder(),
                foregroundColor: colors.danger,
                textStyle: Theme.of(context).textTheme.labelLarge,
              ),
              child: Text(l10n.engineSubscriptionPluginRemove),
            )
          : FilledButton.tonal(
              onPressed: onInstall,
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.standard,
                shape: const StadiumBorder(),
                textStyle: Theme.of(context).textTheme.labelLarge,
              ),
              child: Text(l10n.engineSubscriptionPluginInstall),
            ),
    );
  }
}
