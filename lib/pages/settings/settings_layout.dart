part of 'settings_page.dart';

class _SettingsSection {
  const _SettingsSection({
    required this.title,
    required this.children,
    this.subtitle,
    this.icon = Icons.tune,
    this.common = false,
  });

  final String title;
  final String? subtitle;
  final IconData icon;
  final bool common;
  final List<Widget> children;
}

String? _settingsSectionForTitle(int category, String? title) {
  if (title == null) return null;
  return _settingsSearchIndex
      .where(
        (entry) => entry.category == category && entry.targetTitle == title,
      )
      .firstOrNull
      ?.section;
}

class _SettingsPageView extends StatelessWidget {
  const _SettingsPageView({
    required this.title,
    required this.sections,
    required this.onOpenSection,
    this.description,
    this.section,
    this.intro,
    this.showHeader = true,
  });

  final String title;
  final String? description;
  final List<_SettingsSection> sections;
  final ValueChanged<String> onOpenSection;
  final String? section;
  final Widget? intro;
  final bool showHeader;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) =>
        _buildView(context, constraints.maxWidth),
  );

  Widget _buildView(BuildContext context, double width) {
    final selected = sections
        .where((item) => item.title == section)
        .firstOrNull;
    final detail = selected != null && !selected.common ? selected : null;
    final colors = context.colorScheme;
    final wide = width >= 700;
    final spacious = width >= 1180;
    final theme = Theme.of(context);
    final titleStyle = theme.textTheme.bodyMedium?.copyWith(fontSize: 14);
    final body = SmoothCustomScrollView(
      scrollbarTopPadding: 0,
      slivers: [
        SliverToBoxAdapter(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: double.infinity),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  wide ? 32 : 20,
                  12,
                  wide ? 32 : 20,
                  32,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      (detail?.title ?? title).tl,
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontSize: 27,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if ((detail?.subtitle ?? description)
                        case final String text)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          text.tl,
                          style: TextStyle(
                            fontSize: 13,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    const SizedBox(height: 24),
                    if (intro != null) ...[intro!, const SizedBox(height: 24)],
                    if (detail != null)
                      _SettingsGroup(children: detail.children)
                    else
                      _overview(spacious),
                    SizedBox(height: MediaQuery.paddingOf(context).bottom),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
    return Theme(
      data: theme.copyWith(
        listTileTheme: theme.listTileTheme.copyWith(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          minTileHeight: 60,
          titleTextStyle: titleStyle,
          subtitleTextStyle: theme.textTheme.bodySmall?.copyWith(
            fontSize: 12,
            color: colors.onSurfaceVariant,
          ),
          iconColor: colors.onSurfaceVariant,
        ),
        dividerTheme: theme.dividerTheme.copyWith(
          space: 1,
          thickness: 0.6,
          color: colors.outlineVariant,
        ),
      ),
      child: Material(
        color: wide ? colors.surface : colors.surfaceContainerLow,
        child: Column(
          children: [
            if (showHeader && Navigator.of(context).canPop())
              Appbar(
                title: Text(
                  (detail == null ? 'Settings' : title).tl,
                  style: const TextStyle(fontSize: 14),
                ),
                backgroundColor: wide
                    ? colors.surface
                    : colors.surfaceContainerLow,
              ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }

  Widget _overview(bool spacious) {
    final groups = <Widget>[
      for (final item in sections.where((item) => item.common))
        _SettingsGroup(
          title: item.title == 'Reading mode' ? null : item.title,
          children: item.children,
        ),
      if (sections.any((item) => !item.common))
        LayoutBuilder(
          builder: (context, constraints) => _SettingsGroup(
            title: 'More settings',
            columns: constraints.maxWidth >= 620 ? 2 : 1,
            children: [
              for (final item in sections.where((item) => !item.common))
                _SettingsLink(
                  title: item.title,
                  subtitle: item.subtitle,
                  icon: item.icon,
                  onTap: () => onOpenSection(item.title),
                ),
            ],
          ),
        ),
    ];
    if (!spacious || groups.length < 2) return Column(children: groups);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 6, child: groups.first),
        const SizedBox(width: 24),
        Expanded(flex: 5, child: Column(children: groups.skip(1).toList())),
      ],
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({this.title, required this.children, this.columns = 1});
  final String? title;
  final List<Widget> children;
  final int columns;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    final colors = context.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 9),
              child: Text(
                title!.tl,
                style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
              ),
            ),
          Material(
            color: colors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: colors.outlineVariant.withValues(alpha: 0.65),
                width: 0.7,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < children.length; i += columns) ...[
                  if (i > 0) const Divider(indent: 16, endIndent: 16),
                  if (columns == 1 || i + 1 == children.length)
                    children[i]
                  else
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: children[i]),
                          const VerticalDivider(width: 1, thickness: 0.6),
                          Expanded(child: children[i + 1]),
                        ],
                      ),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsLink extends StatelessWidget {
  const _SettingsLink({
    required this.title,
    required this.onTap,
    this.subtitle,
    this.icon,
  });
  final String title;
  final String? subtitle;
  final IconData? icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 68),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 21),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title.tl,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(fontSize: 14),
                  ),
                  if (subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        subtitle!.tl,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontSize: 12,
                          color: context.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            const Icon(Icons.chevron_right, size: 18),
          ],
        ),
      ),
    ),
  );
}
