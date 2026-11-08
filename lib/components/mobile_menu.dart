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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        alignment: AlignmentDirectional.centerStart,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: Row(
        children: [
          if (entry.icon != null) ...[
            Icon(entry.icon, size: 20),
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
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        child: Row(
          children: [
            if (entry.icon != null) ...[
              Icon(entry.icon, size: 22),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.text),
                  if (entry.subtitle != null)
                    Text(entry.subtitle!, style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ],
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
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final entry in items)
          SizedBox(
            width: (width - (columns - 1) * 8) / columns,
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
                    backgroundColor: entry.isSelected
                        ? context.colorScheme.secondaryContainer
                        : context.colorScheme.surfaceContainerHigh,
                    minimumSize: const Size(0, 72),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (entry.icon != null) ...[
                        Icon(entry.icon, size: 22),
                        const SizedBox(height: 8),
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
    final remaining = entries
        .where((entry) => entry != primary && !quick.contains(entry))
        .toList();
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final plain = remaining
                .where((entry) => entry.group == null && !entry.destructive)
                .toList();
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
                      SizedBox(width: 40, height: 52, child: leading),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title ?? 'Actions'.tl,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          if (subtitle != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              subtitle!,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close'.tl,
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (primary != null) ...[
                  _primary(context, primary),
                  const SizedBox(height: 12),
                ],
                if (quick.isNotEmpty) ...[
                  _quickActions(context, quick, width),
                  const SizedBox(height: 12),
                ],
                if (plain.isNotEmpty) _grid(context, plain, width),
                for (final group in MenuGroup.values)
                  if (remaining.any(
                    (entry) => entry.group == group && !entry.destructive,
                  )) ...[
                    const Divider(height: 24),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        group.label,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: context.colorScheme.onSurfaceVariant,
                            ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    _grid(
                      context,
                      remaining
                          .where(
                            (entry) =>
                                entry.group == group && !entry.destructive,
                          )
                          .toList(),
                      width,
                    ),
                  ],
                if (destructive.isNotEmpty) ...[
                  const Divider(height: 24),
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
