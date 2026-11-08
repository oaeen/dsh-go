// 订阅详情 (a detail page): who is signed in, the models the subscription brings
// (its catalog group), 「退出登录」. 「暂无模型」 only when the catalog was read and
// lists none for it; a failed read is an error with 「重试」, no connection is
// the offline message.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/models_state.dart';
import '../../state/providers_state.dart' show formatTokens;
import '../../state/read_list_cache.dart' show ReadListStatus;
import '../../state/subscriptions_state.dart';
import '../common/app_dialog.dart';
import '../common/list_page_row.dart';
import '../common/page_hero.dart';
import '../common/read_list_status.dart';
import '../common/status_chip.dart';
import '../features/feature_kit.dart';
import '../features/feature_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'model_context_page.dart';
import 'provider_widgets.dart';
import 'subscription_sheet.dart';

class SubscriptionPage extends ConsumerStatefulWidget {
  const SubscriptionPage({super.key, required this.subscription});

  final Subscription subscription;

  @override
  ConsumerState<SubscriptionPage> createState() => _SubscriptionPageState();
}

class _SubscriptionPageState extends ConsumerState<SubscriptionPage> {
  bool _busy = false;
  bool _checkingIn = false;
  final _updatingOptions = <String>{};

  String _resolveLabel(SubscriptionStatus? status) =>
      subscriptionLabel(widget.subscription, displayName: status?.displayName);

  Future<void> _checkin() async {
    final backend = ref.read(subscriptionBackendProvider);
    if (backend == null || _checkingIn) return;
    setState(() => _checkingIn = true);
    try {
      final result = await backend.checkin(widget.subscription);
      ref.invalidate(subscriptionUsageProvider(widget.subscription));
      if (!mounted) return;
      final text = result.message?.trim().isNotEmpty == true
          ? result.message!.trim()
          : (result.ok
                ? context.l10n.engineSubscriptionCheckinDone
                : context.l10n.engineSubscriptionPluginActionFailed(result.outcome));
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(context.l10n.engineSubscriptionPluginActionFailed('$error'))));
    } finally {
      if (mounted) setState(() => _checkingIn = false);
    }
  }

  Future<void> _toggleOption(SubscriptionOption option, bool nextValue) async {
    final backend = ref.read(subscriptionBackendProvider);
    if (backend == null || _updatingOptions.contains(option.key)) return;
    setState(() => _updatingOptions.add(option.key));
    try {
      await backend.setOption(widget.subscription, option.key, nextValue);
      refreshAfterSubscriptionChange(ref);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(context.l10n.engineSubscriptionPluginActionFailed('$error'))));
    } finally {
      if (mounted) setState(() => _updatingOptions.remove(option.key));
    }
  }

  Future<void> _signOut() async {
    final status = ref.read(subscriptionsProvider).value?.of(widget.subscription);
    final label = _resolveLabel(status);
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(context.l10n.engineSubscriptionSignOutTitle(label)),
        content: Text(context.l10n.engineSubscriptionSignOutBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(context.l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: DshColors.of(dialog).danger,
              foregroundColor: DshColors.of(dialog).onDanger,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(context.l10n.commonSignOut),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final backend = ref.read(subscriptionBackendProvider);
    if (backend == null) return;
    setState(() => _busy = true);
    try {
      await backend.signOut(widget.subscription);
      refreshAfterSubscriptionChange(ref);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(context.l10n.engineSubscriptionSignOutFailed(describeLoginError(error)))));
    }
  }

  /// The catalog couldn't say which models the subscription brings: [error]
  /// when the read failed, null when the catalog reported this provider failing
  /// (its message is the engine's own text, not shown).
  Widget _modelsFailed(Object? error) {
    final title = context.l10n.engineSubscriptionModelsFailed;
    void retry() => ref.invalidate(modelCatalogProvider);
    return error == null
        ? FeatureMessage(icon: AppIcons.error, title: title, action: (context.l10n.commonRetry, retry))
        : FeatureMessage.error(title: title, error: error, onRetry: retry);
  }

  /// 「上下文长度」: one model's override of the catalog's figure.
  void _openContext(ModelInfo model, ModelOverride? current) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ModelContextPage(
          subscription: widget.subscription,
          route: widget.subscription.wire,
          modelId: model.id,
          modelName: model.name,
          current: current,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final snapshot = ref.watch(subscriptionsProvider).value;
    final status = snapshot?.of(widget.subscription);
    final signedIn = status?.signedIn ?? false;
    final catalog = ref.watch(modelCatalogProvider);
    final wire = widget.subscription.wire;
    // The pi-ai route this subscription declared: the model overrides hang off
    // it (`providers.<route>.modelOverrides`). Null before sign-in or while the
    // bridge is declaring it.
    final profile = ref.watch(subscriptionProfileProvider(widget.subscription)).value;
    final models = [
      for (final group in catalog.value?.groups ?? const [])
        if (group.id == wire) ...group.models,
    ];
    // The read failed, or the catalog says this subscription's provider did:
    // that doesn't show it has no models. (Other providers' failures don't
    // count against this one.)
    final failed = catalog.hasError || (catalog.value?.failures.any((f) => f.provider == wire) ?? false);
    final account = status?.account?.trim();
    final label = _resolveLabel(status);
    final supportsUsage = signedIn && (status?.supportsUsage ?? false);
    final supportsCheckin = signedIn && (status?.supportsCheckin ?? false);
    final options = status?.options ?? const <SubscriptionOption>[];
    final usageAsync = supportsUsage ? ref.watch(subscriptionUsageProvider(widget.subscription)) : null;
    const gap = SizedBox(height: 24);
    final modelsTitle = models.isEmpty ? l10n.engineModelTitle : l10n.engineProviderModelCount(models.length);

    return AppPage(
      title: label,
      hero: PageHero(
        leading: Monogram(label, size: 56, letter: subscriptionLetter(widget.subscription)),
        title: label,
        subtitle: Row(
          children: [
            ProviderDot(signedIn ? StatusTone.ok : StatusTone.idle),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                signedIn ? l10n.commonSignedIn : l10n.engineAccountSignedOut,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
      slivers: [
        SliverList.list(
          children: [
            ListPageCard(
              children: [
                ListPageRow(
                  icon: AppIcons.account,
                  title: l10n.engineAccountTitle,
                  value: account == null || account.isEmpty
                      ? (signedIn ? l10n.commonSignedIn : l10n.engineAccountSignedOut)
                      : account,
                ),
                if (supportsCheckin)
                  ListPageRow(
                    icon: AppIcons.done,
                    title: l10n.engineSubscriptionCheckin,
                    trailing: _checkingIn
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : null,
                    onTap: _checkingIn ? null : _checkin,
                  ),
              ],
            ),
            if (supportsUsage && usageAsync != null) ...[
              gap,
              _UsageCard(
                usageAsync: usageAsync,
                onRefresh: () => ref.invalidate(subscriptionUsageProvider(widget.subscription)),
              ),
            ],
            if (options.isNotEmpty) ...[
              gap,
              ListPageCard(
                title: l10n.engineSubscriptionOptionsSection,
                children: [
                  for (final opt in options)
                    ListPageRow(
                      icon: AppIcons.configure,
                      title: opt.label,
                      subtitle: opt.description,
                      trailing: Switch.adaptive(
                        value: opt.value == true,
                        onChanged: _updatingOptions.contains(opt.key) ? null : (v) => _toggleOption(opt, v),
                      ),
                      onTap: _updatingOptions.contains(opt.key)
                          ? null
                          : () => _toggleOption(opt, !(opt.value == true)),
                    ),
                ],
              ),
            ],
            gap,
            if (models.isEmpty && !catalog.isLoading && failed)
              _modelsFailed(catalog.error)
            else if (models.isEmpty && !catalog.isLoading && catalog.value == null)
              const FeatureOffline()
            else
              ListPageCard(
                // Models kept from before a failed refresh: shown, marked as such.
                title: failed ? readListHeading(modelsTitle, ReadListStatus.failed) : modelsTitle,
                children: [
                  if (catalog.isLoading && models.isEmpty)
                    const QuietSpinner(padding: EdgeInsets.symmetric(vertical: 16))
                  else if (models.isEmpty)
                    ListPageRow(
                      icon: AppIcons.modelItem,
                      iconColor: colors.textTertiary,
                      title: l10n.engineSubscriptionNoModels,
                    )
                  else
                    for (final model in models)
                      _ModelRow(
                        model: model,
                        modelOverride: profile?.modelOverrides[model.id],
                        showContext: profile != null,
                        onTap: profile == null ? null : () => _openContext(model, profile.modelOverrides[model.id]),
                      ),
                ],
              ),
            gap,
            Center(
              child: TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: colors.danger),
                onPressed: _busy || !signedIn ? null : _signOut,
                icon: const Icon(AppIcons.logout, size: 19),
                label: Text(l10n.commonSignOut),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 订阅模型的一行：名字 + 渠道模型 id，右侧是它生效的上下文长度（有覆盖时
/// 是覆盖值，没有时写「默认」= 跟随目录）。点开可改。
class _ModelRow extends StatelessWidget {
  const _ModelRow({required this.model, required this.modelOverride, required this.showContext, required this.onTap});

  final ModelInfo model;

  /// The model's override, when it has one.
  final ModelOverride? modelOverride;

  /// Whether the route profile is known: only then can the row say which
  /// context length is in effect (「默认」 or the override).
  final bool showContext;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final value = modelOverride?.contextWindow;
    return ListPageRow(
      icon: AppIcons.modelItem,
      title: model.name,
      subtitle: model.name == model.id ? null : model.id,
      value: !showContext ? null : (value == null ? l10n.commonDefault : formatTokens(value)),
      onTap: onTap,
    );
  }
}

class _UsageCard extends StatelessWidget {
  const _UsageCard({required this.usageAsync, required this.onRefresh});

  final AsyncValue<SubscriptionUsage?> usageAsync;
  final VoidCallback onRefresh;

  String _formatWindowValue(SubscriptionUsageWindow window) {
    final display = window.display?.trim();
    if (display != null && display.isNotEmpty) return display;
    final amount = window.amount;
    final limit = window.limit;
    final unit = window.unit?.trim();
    if (limit > 0) {
      final a = amount % 1 == 0 ? amount.toInt().toString() : amount.toStringAsFixed(2);
      final l = limit % 1 == 0 ? limit.toInt().toString() : limit.toStringAsFixed(2);
      return unit != null && unit.isNotEmpty ? '$a / $l $unit' : '$a / $l';
    }
    if (amount > 0) {
      final a = amount % 1 == 0 ? amount.toInt().toString() : amount.toStringAsFixed(2);
      return unit != null && unit.isNotEmpty ? '$a $unit' : a;
    }
    if (window.usedPercent case final pct?) {
      return '${pct.toStringAsFixed(0)}%';
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final usage = usageAsync.value;
    return ListPageCard(
      title: l10n.engineSubscriptionUsageSection,
      children: [
        if (usageAsync.isLoading && usage == null)
          const QuietSpinner(padding: EdgeInsets.symmetric(vertical: 16))
        else if (usage != null) ...[
          if (usage.plan case final plan? when plan.trim().isNotEmpty)
            ListPageRow(
              icon: AppIcons.balance,
              title: l10n.engineProvidersSubscription,
              value: plan.trim(),
            ),
          for (final window in usage.windows)
            ListPageRow(
              icon: AppIcons.chart,
              title: window.name,
              subtitle: window.resetsAt,
              value: _formatWindowValue(window),
            ),
        ],
        ListPageRow(
          icon: AppIcons.refresh,
          title: l10n.engineSubscriptionUsageRefresh,
          onTap: usageAsync.isLoading ? null : onRefresh,
        ),
      ],
    );
  }
}
