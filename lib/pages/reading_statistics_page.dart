import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/reading_statistics.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/utils/translations.dart';

class ReadingStatisticsPage extends StatelessWidget {
  const ReadingStatisticsPage({super.key, this.summary, this.onClear});

  /// Test seam for rendering the page without opening the history database.
  final ReadingStatisticsSummary? summary;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    if (summary != null) {
      return _buildPage(context, summary!);
    }
    return ListenableBuilder(
      listenable: HistoryManager(),
      builder: (context, _) {
        return _buildPage(context, HistoryManager().getReadingStatistics());
      },
    );
  }

  Widget _buildPage(BuildContext context, ReadingStatisticsSummary data) {
    final hasData = data.total > Duration.zero;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppbar(
            title: Text('Reading Statistics'.tl),
            actions: [
              IconButton(
                key: const Key('clear-reading-statistics'),
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Clear Reading Statistics'.tl,
                onPressed: hasData ? () => _confirmClear(context) : null,
              ),
            ],
          ),
          SliverToBoxAdapter(
            child: _PageSection(child: _SummaryBand(summary: data)),
          ),
          if (!hasData)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyStatistics(
                key: const Key('reading-statistics-empty'),
              ),
            )
          else ...[
            SliverToBoxAdapter(
              child: _PageSection(
                top: 28,
                child: _SectionTitle(
                  title: 'Last 7 Days Trend'.tl,
                  icon: Icons.bar_chart,
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: _PageSection(
                top: 12,
                child: _ReadingTrend(daily: data.daily),
              ),
            ),
            SliverToBoxAdapter(
              child: _PageSection(
                top: 28,
                bottom: 4,
                child: _SectionTitle(
                  title: 'Comics Read in Last 30 Days'.tl,
                  icon: Icons.menu_book_outlined,
                ),
              ),
            ),
            if (data.recentComics.isEmpty)
              SliverToBoxAdapter(
                child: _PageSection(
                  top: 16,
                  child: Text(
                    'No comics read in the last 30 days'.tl,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: context.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              )
            else
              SliverList.builder(
                itemCount: data.recentComics.length,
                itemBuilder: (context, index) {
                  return _PageSection(
                    horizontal: 16,
                    child: _RecentComicTile(comic: data.recentComics[index]),
                  );
                },
              ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: MediaQuery.paddingOf(context).bottom + 24,
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _confirmClear(BuildContext context) {
    showConfirmDialog(
      context: context,
      title: 'Clear Reading Statistics'.tl,
      content: 'Are you sure you want to clear reading statistics?'.tl,
      confirmText: 'Clear',
      btnColor: context.colorScheme.error,
      onConfirm: onClear ?? HistoryManager().clearReadingStatistics,
    );
  }
}

class _PageSection extends StatelessWidget {
  const _PageSection({
    required this.child,
    this.horizontal = 20,
    this.top = 16,
    this.bottom = 0,
  });

  final Widget child;
  final double horizontal;
  final double top;
  final double bottom;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920),
        child: Padding(
          padding: EdgeInsets.fromLTRB(horizontal, top, horizontal, bottom),
          child: child,
        ),
      ),
    );
  }
}

class _SummaryBand extends StatelessWidget {
  const _SummaryBand({required this.summary});

  final ReadingStatisticsSummary summary;

  @override
  Widget build(BuildContext context) {
    final items = [
      _SummaryItem(
        icon: Icons.today_outlined,
        label: 'Today'.tl,
        value: formatReadingDuration(summary.today),
        color: context.colorScheme.primary,
      ),
      _SummaryItem(
        icon: Icons.date_range_outlined,
        label: 'Last 7 Days'.tl,
        value: formatReadingDuration(summary.lastSevenDays),
        color: context.colorScheme.secondary,
      ),
      _SummaryItem(
        icon: Icons.auto_stories_outlined,
        label: 'All Time'.tl,
        value: formatReadingDuration(summary.total),
        color: context.colorScheme.tertiary,
      ),
    ];
    return Container(
      key: const Key('reading-statistics-summary'),
      color: context.colorScheme.surfaceContainerLow,
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 420) {
            return Column(
              children: [
                for (var index = 0; index < items.length; index++) ...[
                  _SummaryCell(item: items[index], compact: true),
                  if (index != items.length - 1) const Divider(height: 1),
                ],
              ],
            );
          }
          return IntrinsicHeight(
            child: Row(
              children: [
                for (var index = 0; index < items.length; index++) ...[
                  Expanded(child: _SummaryCell(item: items[index])),
                  if (index != items.length - 1)
                    const VerticalDivider(width: 1),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SummaryItem {
  const _SummaryItem({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;
}

class _SummaryCell extends StatelessWidget {
  const _SummaryCell({required this.item, this.compact = false});

  final _SummaryItem item;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final content = [
      Icon(item.icon, color: item.color, size: 22),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              item.label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 3),
            Text(
              item.value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    ];
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 16 : 14,
        vertical: compact ? 12 : 18,
      ),
      child: Row(children: content),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.icon});

  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: context.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

class _ReadingTrend extends StatelessWidget {
  const _ReadingTrend({required this.daily});

  final List<DailyReadingDuration> daily;

  @override
  Widget build(BuildContext context) {
    final maxMilliseconds = daily.fold<int>(
      0,
      (value, item) => math.max(value, item.duration.inMilliseconds),
    );
    return SizedBox(
      key: const Key('reading-statistics-trend'),
      height: 156,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var index = 0; index < daily.length; index++)
            Expanded(
              child: _ReadingBar(
                item: daily[index],
                maxMilliseconds: maxMilliseconds,
                isToday: index == daily.length - 1,
              ),
            ),
        ],
      ),
    );
  }
}

class _ReadingBar extends StatelessWidget {
  const _ReadingBar({
    required this.item,
    required this.maxMilliseconds,
    required this.isToday,
  });

  final DailyReadingDuration item;
  final int maxMilliseconds;
  final bool isToday;

  @override
  Widget build(BuildContext context) {
    final factor = maxMilliseconds == 0
        ? 0.0
        : item.duration.inMilliseconds / maxMilliseconds;
    final label = '${item.day.month}/${item.day.day}';
    return Tooltip(
      message: '$label  ${formatReadingDuration(item.duration)}',
      child: Semantics(
        label: '$label ${formatReadingDuration(item.duration)}',
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Column(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: FractionallySizedBox(
                    heightFactor: factor,
                    widthFactor: 0.58,
                    child: DecoratedBox(
                      key: ValueKey('reading-bar-$label'),
                      decoration: BoxDecoration(
                        color: isToday
                            ? context.colorScheme.tertiary
                            : context.colorScheme.primary,
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(4),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.fade,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentComicTile extends StatelessWidget {
  const _RecentComicTile({required this.comic});

  final ComicReadingStatistics comic;

  Comic get _displayComic => Comic(
    comic.title,
    comic.cover,
    comic.id,
    comic.subtitle,
    null,
    '',
    comic.type.sourceKey,
    null,
    null,
  );

  @override
  Widget build(BuildContext context) {
    final displayComic = _displayComic;
    final image = comic.cover.isEmpty ? null : findImageProvider(displayComic);
    return InkWell(
      key: ValueKey('reading-comic-${comic.type.value}-${comic.id}'),
      onTap: () {
        context.to(
          () => ComicPage(
            id: comic.id,
            sourceKey: comic.type.sourceKey,
            cover: comic.cover,
            title: comic.title,
          ),
        );
      },
      child: Container(
        constraints: const BoxConstraints(minHeight: 78),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: context.colorScheme.outlineVariant),
          ),
        ),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 60,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: context.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
              ),
              child: image == null
                  ? const Icon(Icons.menu_book_outlined)
                  : AnimatedImage(image: image, fit: BoxFit.cover),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    comic.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  if (comic.subtitle.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      comic.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 84,
              child: Text(
                formatReadingDuration(comic.duration),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: context.colorScheme.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyStatistics extends StatelessWidget {
  const _EmptyStatistics({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_stories_outlined,
              size: 44,
              color: context.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              'No reading statistics yet'.tl,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }
}

String formatReadingDuration(Duration duration) {
  if (duration < const Duration(minutes: 1)) {
    return 'Less than a minute'.tl;
  }
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  if (hours > 0 && minutes > 0) {
    return '@h h @m min'.tlParams({'h': hours, 'm': minutes});
  }
  if (hours > 0) {
    return '@h h'.tlParams({'h': hours});
  }
  return '@m min'.tlParams({'m': minutes});
}
