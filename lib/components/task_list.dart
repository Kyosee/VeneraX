import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/utils/translations.dart';

/// Lightweight list metadata; task cards are built only inside the viewport.
class TaskListEntry {
  const TaskListEntry({
    required this.id,
    required this.title,
    required this.category,
    required this.status,
    required this.time,
    required this.builder,
  });

  final String id;
  final String title;
  final String category;
  final String status;
  final DateTime time;
  final WidgetBuilder builder;
}

class TaskListView extends StatefulWidget {
  const TaskListView({
    required this.entries,
    required this.emptyText,
    required this.emptyIcon,
    super.key,
  });

  final List<TaskListEntry> entries;
  final String emptyText;
  final IconData emptyIcon;

  @override
  State<TaskListView> createState() => _TaskListViewState();
}

class _TaskListViewState extends State<TaskListView>
    with AutomaticKeepAliveClientMixin {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  String? _category;
  String? _status;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _changeFilters(VoidCallback change) {
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(change);
  }

  void _clearFilters() => _changeFilters(() {
    _search.clear();
    _category = null;
    _status = null;
  });

  static String _statusLabel(String status) => switch (status) {
    'running' => 'Running'.tl,
    'paused' => 'Paused'.tl,
    'waitingConfirmation' => 'Waiting for confirmation'.tl,
    'completed' => 'Completed'.tl,
    'failed' => 'Failed'.tl,
    'canceled' => 'Canceled'.tl,
    _ => status,
  };

  Widget _filter({
    required String label,
    required String? value,
    required Map<String, String> options,
    required ValueChanged<String?> onChanged,
  }) => InputDecorator(
    decoration: InputDecoration(
      labelText: label,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    ),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: value,
        isExpanded: true,
        hint: Text('All'.tl),
        items: [
          DropdownMenuItem<String>(value: null, child: Text('All'.tl)),
          for (final option in options.entries)
            DropdownMenuItem(
              value: option.key,
              child: Text(
                option.value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: onChanged,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final colors = Theme.of(context).colorScheme;
    final categories = {
      for (final entry in widget.entries) entry.category: entry.category.tl,
      if (_category != null) _category!: _category!.tl,
    };
    final statuses = {
      for (final entry in widget.entries)
        entry.status: _statusLabel(entry.status),
      if (_status != null) _status!: _statusLabel(_status!),
    };
    final terms = _search.text.trim().toLowerCase().split(RegExp(r'\s+'));
    final filtered = widget.entries.where((entry) {
      if (_category != null && entry.category != _category) return false;
      if (_status != null && entry.status != _status) return false;
      final text =
          '${entry.title} ${entry.category.tl} ${_statusLabel(entry.status)}'
              .toLowerCase();
      return terms.every(text.contains);
    }).toList();
    final hasFilters =
        _search.text.isNotEmpty || _category != null || _status != null;
    final indexById = {
      for (var i = 0; i < filtered.length; i++) filtered[i].id: i,
    };

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Column(
            children: [
              AppSearchField(
                controller: _search,
                hintText: 'Search tasks'.tl,
                onChanged: (_) => _changeFilters(() {}),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _filter(
                      label: 'Task type'.tl,
                      value: _category,
                      options: categories,
                      onChanged: (value) =>
                          _changeFilters(() => _category = value),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _filter(
                      label: 'Status'.tl,
                      value: _status,
                      options: statuses,
                      onChanged: (value) =>
                          _changeFilters(() => _status = value),
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '@shown of @total tasks'.tlParams({
                        'shown': filtered.length,
                        'total': widget.entries.length,
                      }),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Clear filters'.tl,
                    onPressed: hasFilters ? _clearFilters : null,
                    icon: const Icon(Icons.filter_alt_off_outlined, size: 20),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          hasFilters
                              ? Icons.search_off_rounded
                              : widget.emptyIcon,
                          size: 48,
                          color: colors.onSurfaceVariant,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          hasFilters
                              ? 'No matching tasks'.tl
                              : widget.emptyText,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          hasFilters
                              ? 'Try another search or clear the filters.'.tl
                              : 'Background activity will appear here.'.tl,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                        if (hasFilters) ...[
                          const SizedBox(height: 16),
                          TextButton(
                            onPressed: _clearFilters,
                            child: Text('Clear filters'.tl),
                          ),
                        ],
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: filtered.length,
                  findChildIndexCallback: (key) =>
                      key is ValueKey<String> ? indexById[key.value] : null,
                  itemBuilder: (context, index) => KeyedSubtree(
                    key: ValueKey(filtered[index].id),
                    child: filtered[index].builder(context),
                  ),
                ),
        ),
      ],
    );
  }
}
