// Layout idea after PiPilot (https://github.com/CikeSeven/pi_pilot), MIT, Copyright (c) 2026 CikeSeven. See THIRD_PARTY_NOTICES.md.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/app_sheet.dart';
import '../common/list_page_row.dart' show ListPageRow;
import '../common/overview_card.dart' show OverviewChevron;
import '../common/segmented_pill.dart';

export '../common/segmented_pill.dart' show PillSegment, SegmentedPill;
import '../../l10n/l10n.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'index/spot_anchor.dart';
import 'index/spots.dart';

export 'index/spot_anchor.dart' show SpotAnchor, SpotKey;
export 'index/spots.dart' show SettingSpot, SettingsIndex, SettingsPageId, Spots;

/// Page-level group spacing: groups sit 24 apart,
/// flush with the 16 page gutter.
const kSettingsGroupMargin = EdgeInsets.fromLTRB(16, 0, 16, 24);

/// The measured geometry every settings-style row shares. Change it here and in
/// `test/settings/settings_geometry_test.dart` together.
///
/// ```
/// |16| (32) |12| 标题 / 副标题 …… 值 |4| ›   |16 到字形|
/// |16| (32) |12| 标题 …………………………  [ 开关轨道 ] |16|
/// |16| 标签 ………………………………………………………… 值 |16|
/// ```
abstract final class SettingsMetrics {
  /// Card edge → icon disc / plain label on the left, and → switch track,
  /// chevron ink, segmented pill or a bare value on the right.
  static const inset = 16.0;

  /// Right padding of a row ending in a switch or chevron: the switch's track
  /// sits 4 inside its box, the chevron is nudged out by
  /// [OverviewChevron.nudge] — both end at [inset].
  static const trailingPad = ListPageRow.trailingPad;
  static const icon = 32.0;
  static const iconGlyph = 18.0;

  /// Line icon on secondary pages (no tinted disc), centred in the [icon] slot.
  static const lineGlyph = 20.0;
  static const iconGap = 12.0;

  /// Where titles start in rows with an icon.
  static const textStart = inset + icon + iconGap;
  static const rowHeight = 52.0;
  static const rowHeightTwoLine = 64.0;
}

/// Title style of every settings row (15 / 1.4).
TextStyle? settingsTitleStyle(BuildContext context) =>
    Theme.of(context).textTheme.bodyLarge?.copyWith(fontSize: 15, height: 1.4);

/// Icon for a settings row, centred in the 32dp icon slot without a coloured
/// background disc.
class SettingsIcon extends StatelessWidget {
  const SettingsIcon(this.icon, {super.key, this.tint = 0, this.danger = false});

  final IconData icon;
  final int tint;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final colors = DshColors.of(context);
    final fg = danger ? colors.danger : Theme.of(context).colorScheme.onSurfaceVariant;
    return SizedBox.square(
      dimension: SettingsMetrics.icon,
      child: Icon(icon, size: SettingsMetrics.lineGlyph, color: fg),
    );
  }
}

/// A 20dp line icon in the secondary colour, centred in the 32dp icon slot:
/// how rows on secondary pages show an icon.
class SettingsLineIcon extends StatelessWidget {
  const SettingsLineIcon(this.icon, {super.key, this.danger = false});

  final IconData icon;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final colors = DshColors.of(context);
    return SizedBox.square(
      dimension: SettingsMetrics.icon,
      child: Icon(
        icon,
        size: SettingsMetrics.lineGlyph,
        color: danger ? colors.danger : Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// One row: icon · title (+ subtitle) · value · chevron/trailing.
///
/// Single-line rows are 52 tall, rows with a subtitle 64; the whole row is the
/// tap target (a soft highlight, no ripple). A [Switch] passed as [trailing]
/// is drawn without its extra tap padding so switch rows are as tall as the rest.
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    this.icon,
    this.title,
    this.spot,
    this.subtitle,
    this.value,
    this.trailing,
    this.onTap,
    this.tint = 0,
    this.danger = false,
    this.chevron,
    this.tinted = true,
  }) : assert(title != null || spot != null);

  /// Null for a plain row that lines up with [InfoRow]s.
  final IconData? icon;

  /// Defaults to [spot]'s title.
  final String? title;

  /// The row in the settings index: its anchor (key, search landing) and,
  /// unless [title] says otherwise, its title.
  final SettingSpot? spot;
  final String? subtitle;

  /// Current value, right-aligned in the secondary colour.
  final Widget? value;

  /// Replaces the chevron (switches, spinners).
  final Widget? trailing;
  final VoidCallback? onTap;
  final int tint;
  final bool danger;

  /// Defaults to "has onTap and no trailing".
  final bool? chevron;

  /// False draws [icon] as a 20dp line icon ([SettingsLineIcon]) instead of a
  /// tinted disc: the default for rows on secondary pages.
  final bool tinted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final showChevron = chevron ?? (onTap != null && trailing == null);
    final endsInGlyph = showChevron || trailing != null;
    final icon = this.icon;
    final title = this.title ?? spot!.title(context.l10n);
    return anchorSpot(
      spot,
      InkWell(
        onTap: onTap,
        splashFactory: rowSplash(context),
        highlightColor: scheme.onSurface.withValues(alpha: 0.05),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: subtitle == null ? SettingsMetrics.rowHeight : SettingsMetrics.rowHeightTwoLine,
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              SettingsMetrics.inset,
              6,
              endsInGlyph ? SettingsMetrics.trailingPad : SettingsMetrics.inset,
              6,
            ),
            child: Row(
              children: [
                if (icon != null) ...[
                  tinted ? SettingsIcon(icon, tint: tint, danger: danger) : SettingsLineIcon(icon, danger: danger),
                  const SizedBox(width: SettingsMetrics.iconGap),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: settingsTitleStyle(context)?.copyWith(color: danger ? colors.danger : scheme.onSurface),
                      ),
                      if (subtitle case final sub?) ...[
                        const SizedBox(height: 1),
                        Text(sub, style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary)),
                      ],
                    ],
                  ),
                ),
                if (value case final value?) ...[
                  const SizedBox(width: 12),
                  DefaultTextStyle.merge(
                    style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                    child: value,
                  ),
                ],
                if (trailing case final trailing?) ...[
                  const SizedBox(width: 8),
                  SwitchTheme(
                    data: SwitchTheme.of(context).copyWith(materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    child: trailing,
                  ),
                ],
                if (showChevron) ...[const SizedBox(width: 4), const OverviewChevron()],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Row with a switch; the whole row toggles.
class SettingsSwitchTile extends StatelessWidget {
  const SettingsSwitchTile({
    super.key,
    this.icon,
    this.title,
    this.spot,
    this.subtitle,
    required this.value,
    required this.onChanged,
    this.tint = 0,
    this.tinted = true,
  }) : assert(title != null || spot != null);

  final IconData? icon;

  /// Defaults to [spot]'s title.
  final String? title;
  final SettingSpot? spot;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final int tint;
  final bool tinted;

  @override
  Widget build(BuildContext context) {
    final fluid = AppMotion.fluid(context);
    void change(bool next) {
      if (fluid) HapticFeedback.selectionClick();
      onChanged!(next);
    }

    return MergeSemantics(
      child: SettingsTile(
        icon: icon,
        title: title,
        spot: spot,
        subtitle: subtitle,
        tint: tint,
        tinted: tinted,
        onTap: onChanged == null ? null : () => change(!value),
        trailing: Switch(value: value, onChanged: onChanged == null ? null : change),
      ),
    );
  }
}

/// Plain label/value row for read-only facts (about, diagnostics): the label
/// where a plain row's title starts, the value ending 16 from the card edge.
class InfoRow extends StatelessWidget {
  const InfoRow({super.key, required this.label, required this.value, this.mono = false});

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: SettingsMetrics.rowHeight),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: SettingsMetrics.inset, vertical: 6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(label, style: settingsTitleStyle(context)?.copyWith(color: scheme.onSurface)),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  value,
                  textAlign: TextAlign.end,
                  style: mono
                      ? AppType.monoLabel(color: scheme.onSurfaceVariant).copyWith(height: 1.6)
                      : AppType.tabular(theme.textTheme.bodyMedium!.copyWith(color: scheme.onSurfaceVariant)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A group of rows with a small, faint title above the card and an optional
/// one-line footnote under it (title → card 8, card → footnote 8, groups 24
/// apart). Titles and footnotes start 24 from the
/// screen edge, under the page's large title.
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    this.title,
    required this.children,
    this.footer,
    this.margin = kSettingsGroupMargin,
    this.spot,
  });

  final String? title;
  final List<Widget> children;

  /// The card as one place in the settings index (界面's 网页版): its rows
  /// light together, inside the card's rounded edge.
  final SettingSpot? spot;

  /// A short note under the card (secondary colour). Keep it to a sentence.
  final Widget? footer;
  final EdgeInsetsGeometry margin;

  /// Style of section titles, for places that draw one without a card.
  static TextStyle? titleStyle(BuildContext context) => groupTitleStyle(context);

  /// Space between the card and its [footer].
  static const footerGap = 8.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: margin,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title case final title?)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Semantics(header: true, child: Text(title, style: titleStyle(context))),
            ),
          SheetGroup(
            margin: EdgeInsets.zero,
            children: spot == null
                ? children
                : [
                    // One child keeps SheetGroup's 2dp between rows inside it.
                    SpotAnchor(
                      spot: spot!,
                      child: Column(mainAxisSize: MainAxisSize.min, spacing: 2, children: children),
                    ),
                  ],
          ),
          if (footer case final footer?)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, footerGap, 8, 0),
              child: DefaultTextStyle.merge(
                style: theme.textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary, height: 1.55),
                child: footer,
              ),
            ),
        ],
      ),
    );
  }
}

/// 设置里的分段选择行(主题、字号这类二到四选一):放得下就和标题排一行、
/// 控件靠右;放不下(窄屏、系统大字号)就把控件放到标题下面整行显示,
/// 选项不会被挤成竖排。左右内边距与 [SettingsTile] 相同,胶囊右缘与开关轨道对齐。
class SettingsSegmentTile<T> extends StatelessWidget {
  const SettingsSegmentTile({
    super.key,
    this.icon,
    this.tint = 0,
    this.title,
    this.spot,
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.tinted = true,
  }) : assert(title != null || spot != null);

  final IconData? icon;
  final int tint;

  /// Defaults to [spot]'s title.
  final String? title;
  final SettingSpot? spot;
  final List<PillSegment<T>> segments;
  final T selected;
  final ValueChanged<T>? onChanged;
  final bool tinted;

  @override
  Widget build(BuildContext context) {
    final titleStyle = settingsTitleStyle(context);
    final icon = this.icon;
    final title = this.title ?? spot!.title(context.l10n);
    const iconWidth = SettingsMetrics.icon + SettingsMetrics.iconGap;
    return anchorSpot(
      spot,
      Padding(
        padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 8, SettingsMetrics.inset, 8),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final pillWidth = SegmentedPill.naturalWidth(context, [for (final s in segments) s.label]);
            final titlePainter = TextPainter(
              text: TextSpan(text: title, style: titleStyle),
              textScaler: MediaQuery.textScalerOf(context),
              maxLines: 1,
              textDirection: TextDirection.ltr,
            )..layout();
            final titleWidth = titlePainter.width;
            titlePainter.dispose();
            final lead = icon == null ? 0.0 : iconWidth;
            final inline = lead + titleWidth + 16 + pillWidth <= constraints.maxWidth;
            final heading = [
              if (icon != null) ...[
                tinted ? SettingsIcon(icon, tint: tint) : SettingsLineIcon(icon),
                const SizedBox(width: SettingsMetrics.iconGap),
              ],
            ];
            final pill = SegmentedPill<T>(
              segments: segments,
              selected: selected,
              onChanged: onChanged,
              expand: !inline,
            );
            if (inline) {
              return ConstrainedBox(
                constraints: const BoxConstraints(minHeight: SettingsMetrics.rowHeight - 16),
                child: Row(
                  children: [
                    ...heading,
                    Text(title, style: titleStyle),
                    const Spacer(),
                    pill,
                  ],
                ),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: SettingsMetrics.icon),
                  child: Row(
                    children: [
                      ...heading,
                      Expanded(child: Text(title, style: titleStyle)),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: EdgeInsets.only(left: lead),
                  child: pill,
                ),
                const SizedBox(height: 4),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 设置里的下拉选择行(对话字号、语言等):左图标与标题同 [SettingsTile],
/// 右侧显示当前选中项的下拉框,点整行或下拉框展开菜单。
class SettingsDropdownTile<T> extends StatefulWidget {
  const SettingsDropdownTile({
    super.key,
    this.icon,
    this.tint = 0,
    this.title,
    this.spot,
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.tinted = true,
  }) : assert(title != null || spot != null);

  final IconData? icon;
  final int tint;

  /// Defaults to [spot]'s title.
  final String? title;
  final SettingSpot? spot;
  final List<PillSegment<T>> segments;
  final T selected;
  final ValueChanged<T>? onChanged;
  final bool tinted;

  @override
  State<SettingsDropdownTile<T>> createState() => _SettingsDropdownTileState<T>();
}

class _SettingsDropdownTileState<T> extends State<SettingsDropdownTile<T>> {
  final _boxKey = GlobalKey();
  bool _open = false;

  Future<void> _openMenu() async {
    final box = _boxKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final navigator = Navigator.of(context);
    final overlay = navigator.overlay!.context.findRenderObject()! as RenderBox;
    final triggerRect = Rect.fromPoints(
      box.localToGlobal(Offset.zero, ancestor: overlay),
      box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
    );
    if (AppMotion.fluid(context)) HapticFeedback.selectionClick();
    setState(() => _open = true);
    final picked = await navigator.push<T>(
      _SettingsDropdownRoute<T>(
        triggerRect: triggerRect,
        segments: widget.segments,
        selected: widget.selected,
        capturedThemes: InheritedTheme.capture(from: context, to: navigator.context),
        duration: AppMotion.of(context, AppMotion.quick),
      ),
    );
    if (!mounted) return;
    setState(() => _open = false);
    if (picked == null || picked == widget.selected) return;
    if (AppMotion.fluid(context)) HapticFeedback.selectionClick();
    widget.onChanged?.call(picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final dark = theme.brightness == Brightness.dark;
    final selectedLabel =
        widget.segments.where((s) => s.value == widget.selected).firstOrNull?.label ?? widget.segments.first.label;
    final enabled = widget.onChanged != null;
    final fill = _open
        ? scheme.primary.withValues(alpha: dark ? 0.16 : 0.08)
        : (dark ? Colors.white.withValues(alpha: 0.06) : scheme.onSurface.withValues(alpha: 0.045));
    final borderColor = _open
        ? scheme.primary.withValues(alpha: 0.35)
        : scheme.outlineVariant.withValues(alpha: dark ? 0.45 : 0.65);

    return SettingsTile(
      icon: widget.icon,
      tint: widget.tint,
      title: widget.title,
      spot: widget.spot,
      tinted: widget.tinted,
      chevron: false,
      onTap: enabled ? _openMenu : null,
      value: AnimatedContainer(
        key: _boxKey,
        duration: AppMotion.of(context, AppMotion.quick),
        curve: AppMotion.std,
        decoration: ShapeDecoration(
          color: fill,
          shape: Squircle.border(AppShape.sm, side: BorderSide(color: borderColor, width: 0.5)),
        ),
        padding: const EdgeInsets.fromLTRB(11, 5, 8, 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              selectedLabel,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: _open ? scheme.primary : scheme.onSurface,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 4),
            AnimatedRotation(
              turns: _open ? 0.5 : 0.0,
              duration: AppMotion.of(context, AppMotion.quick),
              curve: AppMotion.std,
              child: Icon(AppIcons.expand, size: 16, color: _open ? scheme.primary : colors.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsDropdownRoute<T> extends PopupRoute<T> {
  _SettingsDropdownRoute({
    required this.triggerRect,
    required this.segments,
    required this.selected,
    required this.capturedThemes,
    required this.duration,
  });

  final Rect triggerRect;
  final List<PillSegment<T>> segments;
  final T selected;
  final CapturedThemes capturedThemes;
  final Duration duration;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => '';

  @override
  Duration get transitionDuration => duration;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    final padding = MediaQuery.paddingOf(context);
    return capturedThemes.wrap(
      MediaQuery.removePadding(
        context: context,
        removeTop: true,
        removeBottom: true,
        removeLeft: true,
        removeRight: true,
        child: CustomSingleChildLayout(
          delegate: _DropdownPositionDelegate(triggerRect: triggerRect, padding: padding),
          child: _DropdownMenuSheet<T>(
            animation: animation,
            segments: segments,
            selected: selected,
          ),
        ),
      ),
    );
  }
}

class _DropdownPositionDelegate extends SingleChildLayoutDelegate {
  const _DropdownPositionDelegate({required this.triggerRect, required this.padding});

  final Rect triggerRect;
  final EdgeInsets padding;

  static const _edgeMargin = 16.0;
  static const _verticalGap = 6.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => BoxConstraints.loose(
    Size(
      (constraints.maxWidth - _edgeMargin * 2).clamp(120.0, 260.0),
      (constraints.maxHeight - padding.vertical - _edgeMargin * 2).clamp(80.0, 360.0),
    ),
  );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    var x = triggerRect.right - childSize.width;
    x = x.clamp(_edgeMargin + padding.left, size.width - childSize.width - _edgeMargin - padding.right);
    final belowY = triggerRect.bottom + _verticalGap;
    final maxY = size.height - padding.bottom - _edgeMargin;
    var y = belowY;
    if (belowY + childSize.height > maxY && triggerRect.top - _verticalGap - childSize.height >= padding.top + _edgeMargin) {
      y = triggerRect.top - _verticalGap - childSize.height;
    } else if (belowY + childSize.height > maxY) {
      y = (maxY - childSize.height).clamp(padding.top + _edgeMargin, maxY);
    }
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_DropdownPositionDelegate oldDelegate) =>
      oldDelegate.triggerRect != triggerRect || oldDelegate.padding != padding;
}

class _DropdownMenuSheet<T> extends StatelessWidget {
  const _DropdownMenuSheet({
    required this.animation,
    required this.segments,
    required this.selected,
  });

  final Animation<double> animation;
  final List<PillSegment<T>> segments;
  final T selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final curved = CurvedAnimation(parent: animation, curve: AppMotion.enter, reverseCurve: AppMotion.exit);

    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
      child: ScaleTransition(
        alignment: Alignment.topRight,
        scale: Tween<double>(begin: 0.94, end: 1.0).animate(curved),
        child: GlassSurface(
          tier: GlassTier.chrome,
          borderRadius: AppShape.radiusMd,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 136, maxWidth: 240),
            child: IntrinsicWidth(
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 2,
                  children: [
                    for (final s in segments)
                      _DropdownMenuItem<T>(
                        label: s.label,
                        isSelected: s.value == selected,
                        dark: dark,
                        scheme: scheme,
                        theme: theme,
                        onTap: () => Navigator.of(context).pop(s.value),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DropdownMenuItem<T> extends StatelessWidget {
  const _DropdownMenuItem({
    required this.label,
    required this.isSelected,
    required this.dark,
    required this.scheme,
    required this.theme,
    required this.onTap,
  });

  final String label;
  final bool isSelected;
  final bool dark;
  final ColorScheme scheme;
  final ThemeData theme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final selectedFill = scheme.primary.withValues(alpha: dark ? 0.18 : 0.10);
    return Semantics(
      button: true,
      selected: isSelected,
      child: Material(
        color: isSelected ? selectedFill : Colors.transparent,
        shape: Squircle.border(AppShape.sm),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          customBorder: Squircle.border(AppShape.sm),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: isSelected ? scheme.primary : scheme.onSurface,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Icon(
                  AppIcons.selected,
                  size: 16,
                  color: isSelected ? scheme.primary : Colors.transparent,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
