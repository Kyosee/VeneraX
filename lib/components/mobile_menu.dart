part of 'components.dart';

class _MobileMenu extends StatelessWidget {
  const _MobileMenu({
    required this.entries,
    this.title,
    this.subtitle,
    this.leading,
  });

  final List<MenuEntry> entries;
  final String? title;
  final String? subtitle;
  final Widget? leading;

  void _select(BuildContext context, MenuEntry entry) {
    Navigator.of(context).pop(entry);
  }

  Widget _button(BuildContext context, MenuEntry entry) {
    final color = entry.destructive
        ? context.colorScheme.error
        : entry.color ?? context.colorScheme.onSurface;
    return TextButton(
      onPressed: () => _select(context, entry),
      style: TextButton.styleFrom(
        foregroundColor: color,
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w400),
        alignment: AlignmentDirectional.centerStart,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: Row(
        children: [
          if (entry.icon != null) ...[
            Icon(
              entry.icon,
              size: 20,
              color: entry.destructive
                  ? color
                  : context.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
          ],
          Expanded(child: Text(entry.text, softWrap: true)),
        ],
      ),
    );
  }

  Widget _grid(BuildContext context, List<MenuEntry> items, double width) {
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 20;
    final columns = items.length > 1 && width >= 300 && !largeText ? 2 : 1;
    final itemWidth = (width - (columns - 1) * 8) / columns;
    return Wrap(
      spacing: 8,
      runSpacing: 2,
      children: [
        for (final entry in items)
          SizedBox(width: itemWidth, child: _button(context, entry)),
      ],
    );
  }

  Widget _primary(BuildContext context, MenuEntry entry) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: () => _select(context, entry),
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 54),
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final stacked =
                constraints.maxWidth < 280 ||
                MediaQuery.textScalerOf(context).scale(14) > 20;
            return Row(
              children: [
                if (entry.icon != null) ...[
                  Icon(entry.icon, size: 21),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(entry.text),
                      if (stacked && entry.subtitle != null)
                        Text(
                          entry.subtitle!,
                          style: const TextStyle(fontSize: 12),
                        ),
                    ],
                  ),
                ),
                if (!stacked && entry.subtitle != null) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    fit: FlexFit.tight,
                    child: Text(
                      entry.subtitle!,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                      ),
                      textAlign: TextAlign.end,
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _quickActions(
    BuildContext context,
    List<MenuEntry> items,
    double width,
  ) {
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 20;
    final columns = largeText ? 2 : math.min(3, items.length);
    final itemWidth = (width - (columns - 1) * 8) / columns;
    const labelStyle = TextStyle(fontSize: 13, fontWeight: FontWeight.w500);
    final labelHeight = items.fold<double>(0, (height, entry) {
      final painter = TextPainter(
        text: TextSpan(
          text: entry.compactText ?? entry.text,
          style: labelStyle,
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: itemWidth - 12);
      final result = math.max(height, painter.height);
      painter.dispose();
      return result;
    });
    final itemHeight = math.max(68.0, labelHeight + 44);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final entry in items)
          SizedBox(
            width: itemWidth,
            height: itemHeight,
            child: Semantics(
              selected: entry.isSelected,
              child: Tooltip(
                message: entry.text,
                child: TextButton(
                  onPressed: () => _select(context, entry),
                  style: TextButton.styleFrom(
                    foregroundColor: entry.isSelected
                        ? context.colorScheme.primary
                        : context.colorScheme.onSurfaceVariant,
                    backgroundColor: context.colorScheme.surfaceContainerHigh,
                    textStyle: labelStyle,
                    minimumSize: const Size(0, 68),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 8,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (entry.icon != null) ...[
                        Icon(entry.icon, size: 21),
                        const SizedBox(height: 6),
                      ],
                      Text(
                        entry.compactText ?? entry.text,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final primary = entries
        .where(
          (entry) => entry.role == MenuEntryRole.primary && !entry.destructive,
        )
        .firstOrNull;
    final quick = entries
        .where(
          (entry) => entry.role == MenuEntryRole.quick && !entry.destructive,
        )
        .take(3)
        .toList();
    final details = title == null
        ? null
        : entries
              .where((entry) => entry.action == MenuAction.details)
              .firstOrNull;
    final remaining = entries
        .where(
          (entry) =>
              entry != primary && entry != details && !quick.contains(entry),
        )
        .toList();
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final plain = remaining
                .where(
                  (entry) =>
                      entry.group == null &&
                      entry.action != MenuAction.select &&
                      !entry.destructive,
                )
                .toList();
            final groups = <(String, List<MenuEntry>)>[
              (
                MenuGroup.organize.label,
                remaining
                    .where(
                      (entry) =>
                          !entry.destructive &&
                          (entry.group == MenuGroup.organize ||
                              entry.action == MenuAction.select),
                    )
                    .toList(),
              ),
              (
                MenuGroup.export.label,
                remaining
                    .where(
                      (entry) =>
                          !entry.destructive && entry.group == MenuGroup.export,
                    )
                    .toList(),
              ),
              (
                'Source and more'.tl,
                [
                  for (final group in [MenuGroup.source, MenuGroup.more])
                    ...remaining.where(
                      (entry) => !entry.destructive && entry.group == group,
                    ),
                ],
              ),
            ];
            final destructive = remaining
                .where((entry) => entry.destructive)
                .toList();
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    if (leading != null) ...[
                      SizedBox(width: 42, height: 56, child: leading),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title ?? 'Actions'.tl,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              height: 1.3,
                            ),
                          ),
                          if (details != null)
                            TextButton(
                              onPressed: () => _select(context, details),
                              style: TextButton.styleFrom(
                                foregroundColor:
                                    context.colorScheme.onSurfaceVariant,
                                minimumSize: const Size(0, 36),
                                padding: EdgeInsets.zero,
                                alignment: AlignmentDirectional.centerStart,
                                textStyle: const TextStyle(fontSize: 12),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (subtitle != null) ...[
                                    Flexible(
                                      child: Text(
                                        subtitle!,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const Padding(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 6,
                                      ),
                                      child: Text('·'),
                                    ),
                                  ],
                                  Text(details.text),
                                  const Icon(Icons.chevron_right, size: 16),
                                ],
                              ),
                            )
                          else if (subtitle != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              subtitle!,
                              style: TextStyle(
                                fontSize: 12,
                                color: context.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close'.tl,
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                      iconSize: 20,
                      color: context.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (primary != null) ...[
                  _primary(context, primary),
                  const SizedBox(height: 10),
                ],
                if (quick.isNotEmpty) ...[
                  _quickActions(context, quick, width),
                  const SizedBox(height: 4),
                ],
                if (plain.isNotEmpty) _grid(context, plain, width),
                for (final (label, items) in groups)
                  if (items.isNotEmpty) ...[
                    Divider(
                      height: 20,
                      thickness: 0.5,
                      color: context.colorScheme.outlineVariant,
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: context.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    _grid(context, items, width),
                  ],
                if (destructive.isNotEmpty) ...[
                  Divider(
                    height: 16,
                    thickness: 0.5,
                    color: context.colorScheme.outlineVariant,
                  ),
                  for (final entry in destructive) _button(context, entry),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}
