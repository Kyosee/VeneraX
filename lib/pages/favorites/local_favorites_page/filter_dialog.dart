part of '../favorites_page.dart';

class _LocalFavoritesFilterDialog extends StatefulWidget {
  const _LocalFavoritesFilterDialog({
    required this.initReadFilterSelect,
    required this.initDownloadFilterSelect,
    required this.initSourceFilterSelect,
    required this.initTagFilterSelect,
    required this.initAuthorFilterSelect,
    required this.initTagMatchAll,
    required this.initAuthorMatchAll,
    required this.sourceFilterValues,
    required this.sourceFilterLabel,
    required this.tagFilterValues,
    required this.authorFilterValues,
    required this.updateConfig,
  });

  final String initReadFilterSelect;
  final String initDownloadFilterSelect;
  final Set<String> initSourceFilterSelect;
  final Set<String> initTagFilterSelect;
  final Set<String> initAuthorFilterSelect;
  final bool initTagMatchAll;
  final bool initAuthorMatchAll;
  final List<String> sourceFilterValues;
  final String Function(String sourceKey) sourceFilterLabel;
  final List<MapEntry<String, int>> tagFilterValues;
  final List<MapEntry<String, int>> authorFilterValues;
  final void Function(
    String readFilter,
    String downloadFilter,
    Set<String> sourceFilter,
    Set<String> tagFilter,
    Set<String> authorFilter,
    bool tagMatchAll,
    bool authorMatchAll,
  )
  updateConfig;

  @override
  State<_LocalFavoritesFilterDialog> createState() =>
      _LocalFavoritesFilterDialogState();
}

const readFilterList = ['All', 'UnCompleted', 'Completed'];

const downloadFilterList = ['All', 'Downloaded', 'Not Downloaded'];

class _LocalFavoritesFilterDialogState
    extends State<_LocalFavoritesFilterDialog> {
  late var readFilter = widget.initReadFilterSelect;
  late var downloadFilter = widget.initDownloadFilterSelect;
  late var sourceFilter = {...widget.initSourceFilterSelect};
  late var tagFilter = {...widget.initTagFilterSelect};
  late var authorFilter = {...widget.initAuthorFilterSelect};
  late bool tagMatchAll = widget.initTagMatchAll;
  late bool authorMatchAll = widget.initAuthorMatchAll;
  String tagSearch = "";
  String authorSearch = "";
  bool sourceExpanded = false;
  bool tagExpanded = false;
  bool authorExpanded = false;

  @override
  void initState() {
    super.initState();
    sourceExpanded = sourceFilter.isNotEmpty;
    tagExpanded = tagFilter.isNotEmpty;
    authorExpanded = authorFilter.isNotEmpty;
  }

  Widget _buildSection({
    required String title,
    required bool expanded,
    required VoidCallback onToggle,
    required Widget Function() childBuilder,
    String? badge,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                if (badge != null && badge.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(
                      badge,
                      style: TextStyle(
                        color: context.colorScheme.primary,
                        fontSize: 12,
                      ),
                    ),
                  ),
                Icon(expanded ? Icons.expand_less : Icons.expand_more),
              ],
            ),
          ),
        ),
        if (expanded) childBuilder(),
      ],
    );
  }


  Widget _buildChipSection({
    required List<MapEntry<String, int>> values,
    required Set<String> selected,
    required String search,
    required ValueChanged<String> onSearchChanged,
    required void Function(String tag, bool sel) onSelectChanged,
    required String emptyText,
    required String emptyMatchText,
    required String searchHint,
    required bool matchAll,
    required ValueChanged<bool> onMatchModeChanged,
  }) {
    final filtered = search.trim().isEmpty
        ? values
        : values
              .where(
                (e) => e.key.toLowerCase().contains(
                  search.trim().toLowerCase(),
                ),
              )
              .toList();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: values.length > 8
                      ? TextField(
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: searchHint,
                            prefixIcon: const Icon(Icons.search, size: 18),
                            border: const OutlineInputBorder(),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
                          ),
                          onChanged: onSearchChanged,
                        )
                      : const SizedBox.shrink(),
                ),
                if (values.length > 8) const SizedBox(width: 8),
                InkWell(
                  borderRadius: BorderRadius.circular(4),
                  onTap: () => onMatchModeChanged(!matchAll),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: matchAll
                          ? context.colorScheme.primaryContainer
                          : null,
                      border: Border.all(
                        color: matchAll
                            ? context.colorScheme.primary
                            : context.colorScheme.outlineVariant,
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      matchAll ? "Match all".tl : "Match any".tl,
                      style: TextStyle(
                        fontSize: 12,
                        color: matchAll
                            ? context.colorScheme.primary
                            : context.colorScheme.outline,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (values.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                emptyText,
                style: TextStyle(color: context.colorScheme.outline),
              ),
            )
          else if (filtered.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                emptyMatchText,
                style: TextStyle(color: context.colorScheme.outline),
              ),
            )
          else
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: filtered.map((entry) {
                final isSel = selected.contains(entry.key);
                return FilterChip(
                  label: Text("${entry.key} (${entry.value})"),
                  selected: isSel,
                  onSelected: (s) => onSelectChanged(entry.key, s),
                );
              }).toList(),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: "Filter".tl,
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.6,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text("Filter reading status".tl),
                trailing: Select(
                  current: readFilter.tl,
                  values: readFilterList.map((e) => e.tl).toList(),
                  minWidth: 64,
                  onTap: (index) {
                    setState(() {
                      readFilter = readFilterList[index];
                    });
                  },
                ),
              ),
              const Divider(height: 1),
              ListTile(
                title: Text("Filter download status".tl),
                trailing: Select(
                  current: downloadFilter.tl,
                  values: downloadFilterList.map((e) => e.tl).toList(),
                  minWidth: 64,
                  onTap: (index) {
                    setState(() {
                      downloadFilter = downloadFilterList[index];
                    });
                  },
                ),
              ),
              const Divider(height: 1),
              _buildSection(
                title: "Filter comic source".tl,
                expanded: sourceExpanded,
                badge: sourceFilter.isEmpty ? null : "${sourceFilter.length}",
                onToggle: () =>
                    setState(() => sourceExpanded = !sourceExpanded),
                childBuilder: () => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: widget.sourceFilterValues.map((sourceKey) {
                    return CheckboxListTile(
                      dense: true,
                      title: Text(widget.sourceFilterLabel(sourceKey)),
                      value: sourceFilter.contains(sourceKey),
                      onChanged: (checked) {
                        setState(() {
                          if (checked ?? false) {
                            sourceFilter.add(sourceKey);
                          } else {
                            sourceFilter.remove(sourceKey);
                          }
                        });
                      },
                    );
                  }).toList(),
                ),
              ),
              const Divider(height: 1),
              _buildSection(
                title: "Filter authors".tl,
                expanded: authorExpanded,
                badge: authorFilter.isEmpty
                    ? null
                    : "${authorFilter.length}",
                onToggle: () =>
                    setState(() => authorExpanded = !authorExpanded),
                childBuilder: () => _buildChipSection(
                  values: widget.authorFilterValues,
                  selected: authorFilter,
                  search: authorSearch,
                  onSearchChanged: (v) =>
                      setState(() => authorSearch = v),
                  onSelectChanged: (a, sel) => setState(() {
                    if (sel) {
                      authorFilter.add(a);
                    } else {
                      authorFilter.remove(a);
                    }
                  }),
                  emptyText: "No authors".tl,
                  emptyMatchText: "No matched authors".tl,
                  searchHint: "Search authors".tl,
                  matchAll: authorMatchAll,
                  onMatchModeChanged: (v) =>
                      setState(() => authorMatchAll = v),
                ),
              ),
              const Divider(height: 1),
              _buildSection(
                title: "Filter tags".tl,
                expanded: tagExpanded,
                badge: tagFilter.isEmpty ? null : "${tagFilter.length}",
                onToggle: () => setState(() => tagExpanded = !tagExpanded),
                childBuilder: () => _buildChipSection(
                  values: widget.tagFilterValues,
                  selected: tagFilter,
                  search: tagSearch,
                  onSearchChanged: (v) =>
                      setState(() => tagSearch = v),
                  onSelectChanged: (t, sel) => setState(() {
                    if (sel) {
                      tagFilter.add(t);
                    } else {
                      tagFilter.remove(t);
                    }
                  }),
                  emptyText: "No tags".tl,
                  emptyMatchText: "No matched tags".tl,
                  searchHint: "Search tags".tl,
                  matchAll: tagMatchAll,
                  onMatchModeChanged: (v) =>
                      setState(() => tagMatchAll = v),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            setState(() {
              readFilter = readFilterList[0];
              downloadFilter = downloadFilterList[0];
              sourceFilter.clear();
              tagFilter.clear();
              authorFilter.clear();
              tagSearch = "";
              authorSearch = "";
            });
          },
          child: Text("Reset".tl),
        ),
        FilledButton(
          onPressed: () {
            appdata.implicitData["local_favorites_read_filter"] = readFilter;
            appdata.implicitData["local_favorites_download_filter"] =
                downloadFilter;
            appdata.implicitData["local_favorites_source_filter"] = sourceFilter
                .toList();
            appdata.implicitData["local_favorites_tag_filter"] = tagFilter
                .toList();
            appdata.implicitData["local_favorites_author_filter"] =
                authorFilter.toList();
            appdata.implicitData["local_favorites_tag_match_all"] = tagMatchAll;
            appdata.implicitData["local_favorites_author_match_all"] =
                authorMatchAll;
            appdata.writeImplicitData();
            if (mounted) {
              Navigator.pop(context);
              WidgetsBinding.instance.addPostFrameCallback((_) {
                widget.updateConfig(
                  readFilter,
                  downloadFilter,
                  Set<String>.from(sourceFilter),
                  Set<String>.from(tagFilter),
                  Set<String>.from(authorFilter),
                  tagMatchAll,
                  authorMatchAll,
                );
              });
            }
          },
          child: Text("Confirm".tl),
        ),
      ],
    );
  }
}
