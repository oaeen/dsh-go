// The controls of the new-chat empty state.
//
// - Primary: at most one, and only when the screen has a way forward of its
//   own (「重新连接」). A brand-filled pill.
// - Secondary: the workspace chip and the new chat's options (folder, preset,
//   permissions) — quiet chips of one size: a faint fill, no shadow, muted text.
// - Suggestions: quiet cards with a tinted glyph, a title and one line of
//   what they do; under them one tip line.
//
// The pill and the chips share the height, the side insets and the type
// metrics, so a state change (connected ↔ failed) swaps them in place.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../common/fade_in.dart';
import '../common/pressable.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'empty_state.dart' show ChatSuggestion;

/// The sizes every empty-state control shares (measured in
/// `test/chat/empty_actions_test.dart`).
abstract final class EmptyActions {
  /// Height at 1× text; grows with the text, equally for both tiers.
  static const height = 36.0;

  /// Side padding of a pill, the same on both sides.
  static const inset = 14.0;

  /// Vertical padding (only matters once large text outgrows [height]).
  static const padV = 6.0;

  static const iconSize = 16.0;
  static const iconGap = 6.0;

  /// Room a Rounded glyph leaves inside its box at [iconSize] (~1.3 at 16):
  /// the leading icon's side gets that much less padding so both sides read
  /// the same.
  static const leadingAir = 1.0;

  /// A trailing chevron (`expand_more`, 18) carries ~4.5 of air on its side.
  static const chevronSize = 18.0;
  static const chevronAir = 4.0;

  /// Between suggestion chips, across and down.
  static const gap = 8.0;

  /// The one type style of both tiers (14 / 1.55): equal line heights keep
  /// the tiers equally tall at every text size.
  static TextStyle? labelStyle(BuildContext context) => Theme.of(context).textTheme.bodyMedium;
}

/// The quiet chip's fill: crisp Material 3 Expressive surface container in light
/// mode, subtle elevated tint in dark mode.
Color quietChipFill(ThemeData theme) => theme.brightness == Brightness.dark
    ? Colors.white.withValues(alpha: 0.08)
    : Colors.white.withValues(alpha: 0.90);

/// Shared shell of both tiers: a stadium [Material] with an ink ripple and
/// the 0.97 press, one row of content, [EmptyActions.height] tall.
class _Pill extends StatelessWidget {
  const _Pill({
    required this.color,
    required this.onTap,
    required this.padding,
    required this.child,
    required this.semanticsLabel,
    this.onTapHint,
    this.enabled = true,
    this.expand = false,
  });

  final Color color;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final Widget child;
  final String semanticsLabel;
  final String? onTapHint;
  final bool enabled;

  /// Fill the width given (a grid cell) and centre the content.
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final tap = enabled ? onTap : null;
    return Semantics(
      button: true,
      enabled: tap != null,
      label: semanticsLabel,
      onTapHint: tap == null ? null : onTapHint,
      onTap: tap,
      excludeSemantics: true,
      child: Pressable(
        enabled: tap != null,
        child: Material(
          color: color,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: tap,
            customBorder: const StadiumBorder(),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: EmptyActions.height),
              // Shrinks to the content, or (expand) fills the cell and
              // centres it: equal room on both sides either way.
              child: Align(
                widthFactor: expand ? null : 1,
                heightFactor: 1,
                child: Padding(padding: padding, child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Tier 1: the empty state's one primary action, a brand-filled pill.
class EmptyPrimaryPill extends StatelessWidget {
  const EmptyPrimaryPill({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _Pill(
      color: scheme.primary,
      onTap: onTap,
      semanticsLabel: label,
      padding: const EdgeInsets.symmetric(horizontal: EmptyActions.inset + 4, vertical: EmptyActions.padV),
      child: Text(
        label,
        maxLines: 1,
        style: EmptyActions.labelStyle(context)?.copyWith(color: scheme.onPrimary, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Tier 2: a quiet chip — [icon], one line of [label], an optional
/// [trailing] chevron. Shrinks to its content unless [expand].
class QuietChip extends StatelessWidget {
  const QuietChip({
    super.key,
    required this.label,
    this.icon,
    this.trailing,
    this.onTap,
    this.enabled = true,
    this.expand = false,
    this.semanticsLabel,
    this.onTapHint,
  });

  final String label;
  final IconData? icon;

  /// A chevron that says "this opens a choice".
  final IconData? trailing;
  final VoidCallback? onTap;
  final bool enabled;
  final bool expand;

  /// Read instead of [label].
  final String? semanticsLabel;
  final String? onTapHint;

  /// The padding that makes both sides read the same (see [EmptyActions]).
  static EdgeInsetsDirectional paddingFor({bool icon = false, bool trailing = false}) => EdgeInsetsDirectional.fromSTEB(
    EmptyActions.inset - (icon ? EmptyActions.leadingAir : 0),
    EmptyActions.padV,
    EmptyActions.inset - (trailing ? EmptyActions.chevronAir : 0),
    EmptyActions.padV,
  );

  /// The width a chip needs to show [label] whole.
  static double widthFor(BuildContext context, String label, {bool icon = false, bool trailing = false}) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: EmptyActions.labelStyle(context)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return paddingFor(icon: icon, trailing: trailing).horizontal +
        width +
        (icon ? EmptyActions.iconSize + EmptyActions.iconGap : 0) +
        (trailing ? EmptyActions.chevronSize + 2 : 0);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return _Pill(
      color: quietChipFill(theme),
      onTap: onTap,
      enabled: enabled,
      expand: expand,
      semanticsLabel: semanticsLabel ?? label,
      onTapHint: onTapHint,
      padding: paddingFor(icon: icon != null, trailing: trailing != null),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: EmptyActions.iconSize, color: muted),
            const SizedBox(width: EmptyActions.iconGap),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: EmptyActions.labelStyle(context)?.copyWith(color: muted),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 2),
            Icon(trailing, size: EmptyActions.chevronSize, color: muted),
          ],
        ],
      ),
    );
  }
}

/// The colour family of a suggestion's glyph badge. Each suggestion is its own
/// kind of start, so each carries one calm hue; none of them is an accent.
enum SuggestionTint { teal, violet, amber, blue }

/// The badge colour of [tint], readable on the card in both themes.
Color suggestionTintColor(BuildContext context, SuggestionTint tint) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  final dsh = DshColors.of(context);
  return switch (tint) {
    SuggestionTint.teal => dsh.success,
    SuggestionTint.violet => dark ? DshPalette.duskLift : DshPalette.dusk,
    SuggestionTint.amber => dsh.warning,
    SuggestionTint.blue => dsh.info,
  };
}

/// Sizes of the suggestion cards (measured in `test/chat/empty_actions_test.dart`).
abstract final class SuggestionCardMetrics {
  /// Between cards, across and down.
  static const gap = 10.0;

  static const padH = 12.0;
  static const padV = 12.0;

  /// The icon box at the card's start, and the glyph in it.
  static const badge = 22.0;
  static const glyph = 20.0;

  /// Badge → text.
  static const badgeGap = 10.0;

  /// Below this a cell leaves the text too little room beside the badge, and
  /// the cards go one per row instead.
  static const minCell = 150.0;
}

/// The hairline around a quiet card: the same weight as the chips' fill.
Color quietCardRim(ThemeData theme) => theme.brightness == Brightness.dark
    ? Colors.white.withValues(alpha: 0.08)
    : theme.colorScheme.onSurface.withValues(alpha: 0.06);

/// One suggestion: a tinted glyph badge at the start, and beside it a short
/// title over one line of what it will do, in a low quiet card. The whole
/// card is the target.
class SuggestionCard extends StatelessWidget {
  const SuggestionCard({
    super.key,
    required this.suggestion,
    required this.onTap,
    this.enabled = true,
    this.showDetail = true,
  });

  final ChatSuggestion suggestion;
  final VoidCallback onTap;
  final bool enabled;

  /// The line under the title; the grid turns it off for every card at once
  /// when one of them would wrap (a narrow phone, large text). Screen readers
  /// hear it either way.
  final bool showDetail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final detail = suggestion.detail;
    final shape = AppShape.outlined(quietCardRim(theme), radius: AppShape.lg, width: 0.5);
    final tap = enabled ? onTap : null;
    return Semantics(
      button: true,
      enabled: tap != null,
      label: detail == null ? suggestion.label : '${suggestion.label}, $detail',
      onTap: tap,
      excludeSemantics: true,
      child: Pressable(
        enabled: tap != null,
        child: Material(
          color: quietChipFill(theme),
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: tap,
            customBorder: shape,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: SuggestionCardMetrics.padH,
                vertical: SuggestionCardMetrics.padV,
              ),
              child: Row(
                children: [
                  SizedBox.square(
                    dimension: SuggestionCardMetrics.badge,
                    child: Icon(
                      suggestion.icon,
                      size: SuggestionCardMetrics.glyph,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: SuggestionCardMetrics.badgeGap),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          suggestion.label,
                          maxLines: showDetail && detail != null ? 1 : 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.onSurface),
                        ),
                        if (showDetail && detail != null) ...[
                          const SizedBox(height: 1),
                          Text(
                            detail,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The suggestions as cards: two equal columns edge to edge with the
/// composer, [SuggestionCardMetrics.gap] apart both ways, each row as tall as
/// its taller card. Titles wrap to two lines, so large text keeps two columns
/// until a cell is narrower than [SuggestionCardMetrics.minCell]; then every
/// card takes the full width, one per row.
class SuggestionCards extends StatelessWidget {
  const SuggestionCards({
    super.key,
    required this.suggestions,
    required this.enabled,
    required this.onSuggestion,
    this.firstIndex = 0,
  });

  final List<ChatSuggestion> suggestions;
  final bool enabled;
  final ValueChanged<ChatSuggestion> onSuggestion;

  /// Entrance stagger of the first card (after what is above them).
  final int firstIndex;

  @override
  Widget build(BuildContext context) {
    if (suggestions.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = SuggestionCardMetrics.gap;
        final cell = (constraints.maxWidth - gap) / 2;
        final columns = cell >= SuggestionCardMetrics.minCell ? 2 : 1;
        // The room beside the badge; every detail on one line, or none.
        final textWidth =
            (columns == 2 ? cell : constraints.maxWidth) -
            2 * SuggestionCardMetrics.padH -
            SuggestionCardMetrics.badge -
            SuggestionCardMetrics.badgeGap;
        final detailStyle = Theme.of(context).textTheme.bodySmall;
        bool fits(String text) {
          final painter = TextPainter(
            text: TextSpan(text: text, style: detailStyle),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 1,
          )..layout(maxWidth: math.max(0, textWidth));
          final ok = !painter.didExceedMaxLines;
          painter.dispose();
          return ok;
        }

        final showDetails = suggestions.every((s) => s.detail == null || fits(s.detail!));

        Widget card(int i) {
          final s = suggestions[i];
          return FadeSlideIn(
            index: firstIndex + i,
            child: AnimatedOpacity(
              opacity: enabled ? 1 : 0.5,
              duration: AppMotion.of(context, AppMotion.quick),
              child: SuggestionCard(
                suggestion: s,
                enabled: enabled,
                showDetail: showDetails,
                onTap: () => onSuggestion(s),
              ),
            ),
          );
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < suggestions.length; i += columns) ...[
              if (i > 0) const SizedBox(height: gap),
              if (columns == 1)
                card(i)
              else
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: card(i)),
                      const SizedBox(width: gap),
                      Expanded(child: i + 1 < suggestions.length ? card(i + 1) : const SizedBox.shrink()),
                    ],
                  ),
                ),
            ],
          ],
        );
      },
    );
  }
}

/// One of the new chat's options, light: a small glyph, its value and a
/// caret, with no fill until pressed. A row of them reads as this chat's
/// settings rather than as more buttons.
class SetupItem extends StatelessWidget {
  const SetupItem({
    super.key,
    required this.icon,
    required this.label,
    required this.semanticsLabel,
    required this.onTap,
    this.onTapHint,
  });

  final IconData icon;
  final String label;
  final String semanticsLabel;
  final VoidCallback onTap;
  final String? onTapHint;

  static const height = 32.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Semantics(
      button: true,
      label: semanticsLabel,
      onTapHint: onTapHint,
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          customBorder: const SquircleBorder(borderRadius: AppShape.radiusSm),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: height),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 14, color: muted),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(fontSize: 13, color: muted),
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(AppIcons.expand, size: 14, color: dsh.textTertiary),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
