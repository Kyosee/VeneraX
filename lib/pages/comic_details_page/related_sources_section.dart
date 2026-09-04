import 'package:flutter/material.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/domain_database.dart';
import 'package:venera/utils/translations.dart';

String sourceKeyFromRelatedPlatformId(String platformId) {
  const prefix = 'remote:';
  return platformId.startsWith(prefix)
      ? platformId.substring(prefix.length)
      : platformId;
}

class ComicRelatedSourcesSection extends StatefulWidget {
  const ComicRelatedSourcesSection({
    super.key,
    required this.links,
    required this.currentComicId,
    required this.onManage,
    required this.onOpenSource,
  });

  final List<DomainComicSourceLink> links;
  final String currentComicId;
  final VoidCallback onManage;
  final ValueChanged<DomainComicSourceLink> onOpenSource;

  @override
  State<ComicRelatedSourcesSection> createState() =>
      _ComicRelatedSourcesSectionState();
}

class _ComicRelatedSourcesSectionState
    extends State<ComicRelatedSourcesSection> {
  bool _expanded = false;

  List<DomainComicSourceLink> get _visibleLinks {
    final links = widget.links
        .where(
          (link) => link.status == 'accepted' || link.status == 'candidate',
        )
        .toList();
    links.sort((a, b) {
      final aRank = _rank(a);
      final bRank = _rank(b);
      if (aRank != bRank) return aRank.compareTo(bRank);
      return _sourceName(a).compareTo(_sourceName(b));
    });
    return links;
  }

  int _rank(DomainComicSourceLink link) {
    if (_isCurrent(link)) return 0;
    if (link.status == 'accepted') return 1;
    return 2;
  }

  bool _isCurrent(DomainComicSourceLink link) =>
      link.comicId == widget.currentComicId;

  String _sourceName(DomainComicSourceLink link) {
    final sourceKey = sourceKeyFromRelatedPlatformId(link.platformId);
    if (sourceKey == 'local') return 'Local'.tl;
    return ComicSource.find(sourceKey)?.name ?? link.sourceName;
  }

  @override
  Widget build(BuildContext context) {
    final links = _visibleLinks;
    final acceptedCount = links
        .where((link) => link.status == 'accepted')
        .length;
    final candidateCount = links
        .where((link) => link.status == 'candidate')
        .length;
    return Container(
      key: const Key('comic-related-sources-section'),
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 10, 0, 6),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: context.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.hub_outlined,
                    size: 19,
                    color: context.colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          'Reading sources'.tl,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      if (acceptedCount > 0) ...[
                        const SizedBox(width: 8),
                        _CountBadge(count: acceptedCount),
                      ],
                      if (candidateCount > 0) ...[
                        const SizedBox(width: 6),
                        Tooltip(
                          message: 'Candidate'.tl,
                          child: _StatusPill(
                            text: candidateCount.toString(),
                            foreground: context.colorScheme.onTertiaryContainer,
                            background: context.colorScheme.tertiaryContainer,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                TextButton.icon(
                  key: const Key('comic-related-sources-toggle'),
                  onPressed: () => setState(() => _expanded = !_expanded),
                  icon: Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                  ),
                  label: Text(_expanded ? 'Collapse'.tl : 'Expand'.tl),
                ),
              ],
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            child: _expanded
                ? _buildExpanded(context, links)
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _buildExpanded(
    BuildContext context,
    List<DomainComicSourceLink> links,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (links.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
                child: Text(
                  'No related sources'.tl,
                  style: TextStyle(color: context.colorScheme.onSurfaceVariant),
                ),
              )
            else
              for (var i = 0; i < links.length; i++) ...[
                if (i > 0)
                  Divider(
                    height: 1,
                    indent: 62,
                    color: context.colorScheme.outlineVariant,
                  ),
                _buildSourceRow(context, links[i]),
              ],
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton.icon(
                  key: const Key('comic-related-sources-manage'),
                  onPressed: widget.onManage,
                  icon: const Icon(Icons.tune, size: 19),
                  label: Text('Manage'.tl),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSourceRow(BuildContext context, DomainComicSourceLink link) {
    final current = _isCurrent(link);
    final candidate = link.status == 'candidate';
    final sourceName = _sourceName(link);
    final cleanSourceName = sourceName.trim();
    final details = <String>[
      if (link.comicAuthor?.trim().isNotEmpty == true) link.comicAuthor!.trim(),
      if (link.comicStatus?.trim().isNotEmpty == true) link.comicStatus!.trim(),
    ];

    return InkWell(
      key: Key('comic-related-source-${link.comicId}'),
      onTap: current
          ? null
          : candidate
          ? widget.onManage
          : () => widget.onOpenSource(link),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: candidate
                    ? context.colorScheme.tertiaryContainer
                    : context.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(11),
              ),
              alignment: Alignment.center,
              child: Text(
                cleanSourceName.isEmpty
                    ? '?'
                    : cleanSourceName.substring(0, 1).toUpperCase(),
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: candidate
                      ? context.colorScheme.onTertiaryContainer
                      : context.colorScheme.primary,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    sourceName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    details.isEmpty
                        ? current
                              ? 'Current'.tl
                              : candidate
                              ? 'Candidate'.tl
                              : 'Linked'.tl
                        : details.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: context.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (current)
              _StatusPill(
                text: 'Current'.tl,
                foreground: context.colorScheme.onPrimaryContainer,
                background: context.colorScheme.primaryContainer,
              )
            else if (candidate)
              TextButton(onPressed: widget.onManage, child: Text('Manage'.tl))
            else
              Icon(
                Icons.open_in_new,
                size: 19,
                color: context.colorScheme.onSurfaceVariant,
              ),
          ],
        ),
      ),
    );
  }
}

class RelatedSearchLinkActions extends StatelessWidget {
  const RelatedSearchLinkActions({
    super.key,
    required this.isLinked,
    required this.isCurrent,
    this.onLink,
    this.onUnlink,
    this.unlinkKey,
  });

  final bool isLinked;
  final bool isCurrent;
  final VoidCallback? onLink;
  final VoidCallback? onUnlink;
  final Key? unlinkKey;

  @override
  Widget build(BuildContext context) {
    if (isCurrent) {
      return KeyedSubtree(
        key: const Key('related-search-current-status'),
        child: _StatusPill(
          text: 'Current'.tl,
          foreground: context.colorScheme.onPrimaryContainer,
          background: context.colorScheme.primaryContainer,
        ),
      );
    }
    if (!isLinked) {
      return IconButton(
        key: const Key('related-search-link-action'),
        icon: const Icon(Icons.link, size: 18),
        tooltip: 'Link this comic'.tl,
        onPressed: onLink,
      );
    }
    return Row(
      key: const Key('related-search-linked-actions'),
      mainAxisSize: MainAxisSize.min,
      children: [
        _StatusPill(
          text: 'Linked'.tl,
          foreground: context.colorScheme.onPrimaryContainer,
          background: context.colorScheme.primaryContainer,
        ),
        const SizedBox(width: 4),
        TextButton.icon(
          key: unlinkKey,
          onPressed: onUnlink,
          icon: const Icon(Icons.link_off, size: 18),
          label: Text('Unlink'.tl),
        ),
      ],
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: context.colorScheme.primary,
        borderRadius: BorderRadius.circular(11),
      ),
      alignment: Alignment.center,
      child: Text(
        count.toString(),
        style: TextStyle(
          color: context.colorScheme.onPrimary,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.text,
    required this.foreground,
    required this.background,
  });

  final String text;
  final Color foreground;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: TextStyle(color: foreground, fontSize: 12)),
    );
  }
}
