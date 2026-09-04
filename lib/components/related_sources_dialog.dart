import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_state_repository.dart';
import 'package:venera/foundation/domain_database.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/comic_details_page/related_sources_section.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/translations.dart';

Future<void> showRelatedSourcesDialog(BuildContext context, Comic comic) {
  final sourceKeyController = TextEditingController();
  final comicIdController = TextEditingController();
  final searchController = TextEditingController(text: comic.title);
  const repository = ComicStateRepository();
  final currentIdentity = repository.identityFor(comic.sourceKey, comic.id);
  final searchableSources = ComicSource.all()
      .where(
        (source) =>
            source.searchPageData?.loadPage != null ||
            source.searchPageData?.loadNext != null,
      )
      .toList();
  final selectedSourceKeys = <String>{};
  final firstOtherSource = searchableSources.firstWhereOrNull(
    (source) => source.key != comic.sourceKey,
  );
  if (firstOtherSource != null) {
    selectedSourceKeys.add(firstOtherSource.key);
  } else if (searchableSources.isNotEmpty) {
    selectedSourceKeys.add(searchableSources.first.key);
  }
  var searchGroups = <String, _RelatedSearchGroup>{};
  var isSearching = false;
  var dialogClosed = false;
  var acceptedLinksByComicId = <String, DomainComicSourceLink>{};

  void refreshAcceptedLinks() {
    acceptedLinksByComicId = {
      for (final link in repository.relatedSourcesFor(comic))
        if (link.status == 'accepted') link.comicId: link,
    };
  }

  refreshAcceptedLinks();

  void updateDialog(StateSetter setState, VoidCallback fn) {
    if (dialogClosed) return;
    setState(fn);
  }

  void openDetail(String sourceKey, String id, {String? cover, String? title}) {
    App.mainNavigatorKey?.currentContext?.to(
      () => ComicPage(id: id, sourceKey: sourceKey, cover: cover, title: title),
    );
  }

  void showLinkPreview(
    BuildContext context,
    DomainComicSourceLink link, {
    VoidCallback? onAccept,
    VoidCallback? onReject,
    VoidCallback? onUnlink,
  }) {
    final sourceKey = _sourceKeyFromPlatformId(link.platformId);
    _showRelatedComicPreview(
      context: context,
      title: link.comicTitle,
      cover: link.comicCoverUri,
      sourceKey: sourceKey,
      sourceName: _sourceNameForKey(sourceKey, link.sourceName),
      id: link.sourceComicId,
      author: link.comicAuthor,
      status: link.comicStatus,
      actions: [
        if (onAccept != null)
          Button.filled(onPressed: onAccept, child: Text('Accept'.tl)),
        if (onReject != null)
          Button.text(onPressed: onReject, child: Text('Reject'.tl)),
        if (onUnlink != null)
          Button.text(onPressed: onUnlink, child: Text('Unlink'.tl)),
        Button.outlined(
          onPressed: () => openDetail(
            sourceKey,
            link.sourceComicId,
            cover: link.comicCoverUri,
            title: link.comicTitle,
          ),
          child: Text('Jump to Detail'.tl),
        ),
      ],
    );
  }

  void showResultPreview(
    BuildContext context,
    Comic result,
    VoidCallback? onLink,
  ) {
    _showRelatedComicPreview(
      context: context,
      title: result.title,
      cover: result.cover,
      sourceKey: result.sourceKey,
      sourceName: _sourceNameForKey(result.sourceKey, result.sourceKey),
      id: result.id,
      author: result.subtitle,
      status: _relatedStatusFromTags(result.tags),
      tags: result.tags,
      description: result.description,
      actions: [
        if (onLink != null)
          Button.filled(onPressed: onLink, child: Text('Link this comic'.tl)),
        Button.outlined(
          onPressed: () => openDetail(
            result.sourceKey,
            result.id,
            cover: result.cover,
            title: result.title,
          ),
          child: Text('Jump to Detail'.tl),
        ),
      ],
    );
  }

  void linkSearchResult(
    StateSetter setState,
    BuildContext context,
    Comic result,
  ) {
    try {
      repository.mirrorComic(result);
      repository.linkRelatedSource(
        comic: comic,
        targetSourceKey: result.sourceKey,
        targetComicId: result.id,
      );
      refreshAcceptedLinks();
      updateDialog(setState, () {});
      context.showMessage(message: 'Linked'.tl);
    } catch (e) {
      context.showMessage(message: e.toString().tl);
    }
  }

  void unlinkSearchResult(
    StateSetter setState,
    BuildContext context,
    DomainComicSourceLink link,
  ) {
    try {
      repository.unlinkRelatedSource(link);
      refreshAcceptedLinks();
      updateDialog(setState, () {});
      context.showMessage(message: 'Unlinked'.tl);
    } catch (e) {
      context.showMessage(message: e.toString().tl);
    }
  }

  Future<void> runSearch(StateSetter setState, BuildContext context) async {
    final keyword = searchController.text.trim();
    if (keyword.isEmpty || selectedSourceKeys.isEmpty) {
      context.showMessage(message: 'Invalid input'.tl);
      return;
    }
    updateDialog(setState, () {
      isSearching = true;
      searchGroups = {
        for (final sourceKey in selectedSourceKeys)
          sourceKey: _RelatedSearchGroup(
            sourceKey: sourceKey,
            sourceName: _sourceNameForKey(sourceKey, sourceKey),
            isLoading: true,
          ),
      };
    });
    for (final sourceKey in selectedSourceKeys.toList()) {
      final source = ComicSource.find(sourceKey);
      final searchData = source?.searchPageData;
      if (source == null || searchData == null) {
        updateDialog(setState, () {
          searchGroups[sourceKey] = _RelatedSearchGroup(
            sourceKey: sourceKey,
            sourceName: _sourceNameForKey(sourceKey, sourceKey),
            error: 'No searchable sources'.tl,
          );
        });
        continue;
      }
      final options =
          searchData.searchOptions
              ?.map((option) => option.defaultValue)
              .toList() ??
          const <String>[];
      try {
        final res = searchData.loadPage != null
            ? await searchData.loadPage!(keyword, 1, options)
            : await searchData.loadNext!(keyword, null, options);
        updateDialog(setState, () {
          searchGroups[sourceKey] = _RelatedSearchGroup(
            sourceKey: sourceKey,
            sourceName: source.name,
            results: res.dataOrNull ?? const <Comic>[],
            error: res.errorMessage,
          );
        });
      } catch (e) {
        updateDialog(setState, () {
          searchGroups[sourceKey] = _RelatedSearchGroup(
            sourceKey: sourceKey,
            sourceName: source.name,
            error: e.toString(),
          );
        });
      }
    }
    updateDialog(setState, () {
      isSearching = false;
    });
  }

  Widget buildSourceSelector(StateSetter setState, BuildContext context) {
    if (searchableSources.isEmpty) {
      return Text(
        'No searchable sources'.tl,
        style: TextStyle(color: context.colorScheme.onSurfaceVariant),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Select Source'.tl, style: ts.s16),
            const Spacer(),
            TextButton(
              onPressed: () {
                setState(() {
                  selectedSourceKeys
                    ..clear()
                    ..addAll(searchableSources.map((s) => s.key));
                });
              },
              child: Text('Select All'.tl),
            ),
            TextButton(
              onPressed: () => setState(selectedSourceKeys.clear),
              child: Text('Deselect'.tl),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 116),
          child: SingleChildScrollView(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final source in searchableSources)
                  _StableSourceFilterChip(
                    label: source.name,
                    selected: selectedSourceKeys.contains(source.key),
                    onSelected: (selected) {
                      setState(() {
                        if (selected) {
                          selectedSourceKeys.add(source.key);
                        } else {
                          selectedSourceKeys.remove(source.key);
                        }
                      });
                    },
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget buildLinkList(StateSetter setState, BuildContext context) {
    if (!repository.isDomainReady) {
      return Center(
        child: Text(
          'Related source database unavailable'.tl,
          style: TextStyle(color: context.colorScheme.onSurfaceVariant),
        ),
      );
    }
    final links = repository.relatedSourcesFor(comic);
    if (links.isEmpty) {
      return Center(
        child: Text(
          'No related sources'.tl,
          style: TextStyle(color: context.colorScheme.onSurfaceVariant),
        ),
      );
    }
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        for (final link in links)
          _RelatedSourceRow(
            link: link,
            isCurrent: link.comicId == currentIdentity.comicId,
            onTap: () => showLinkPreview(
              context,
              link,
              onAccept: link.status == 'candidate'
                  ? () {
                      repository.acceptRelatedSource(link);
                      refreshAcceptedLinks();
                      setState(() {});
                      App.rootContext.pop();
                    }
                  : null,
              onReject: link.status == 'candidate'
                  ? () {
                      repository.rejectRelatedSource(link);
                      setState(() {});
                      App.rootContext.pop();
                    }
                  : null,
              onUnlink:
                  link.status == 'accepted' &&
                      link.comicId != currentIdentity.comicId
                  ? () {
                      repository.unlinkRelatedSource(link);
                      refreshAcceptedLinks();
                      setState(() {});
                      App.rootContext.pop();
                    }
                  : null,
            ),
            onAccept: link.status == 'candidate'
                ? () {
                    repository.acceptRelatedSource(link);
                    refreshAcceptedLinks();
                    setState(() {});
                  }
                : null,
            onReject: link.status == 'candidate'
                ? () {
                    repository.rejectRelatedSource(link);
                    setState(() {});
                  }
                : null,
            onUnlink:
                link.status == 'accepted' &&
                    link.comicId != currentIdentity.comicId
                ? () {
                    repository.unlinkRelatedSource(link);
                    refreshAcceptedLinks();
                    setState(() {});
                  }
                : null,
          ),
      ],
    );
  }

  Widget buildSearchList(StateSetter setState, BuildContext context) {
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        buildSourceSelector(setState, context),
        const SizedBox(height: 12),
        TextField(
          controller: searchController,
          decoration: InputDecoration(
            labelText: 'Search by title'.tl,
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: const Icon(Icons.search),
              onPressed: isSearching
                  ? null
                  : () => runSearch(setState, context),
            ),
          ),
          onSubmitted: (_) => runSearch(setState, context),
        ),
        const SizedBox(height: 10),
        Button.filled(
          isLoading: isSearching,
          onPressed: () => runSearch(setState, context),
          child: Text('Search related comic'.tl),
        ),
        const SizedBox(height: 12),
        if (searchGroups.isEmpty)
          Text(
            'Search Results'.tl,
            style: TextStyle(color: context.colorScheme.onSurfaceVariant),
          )
        else
          for (final group in searchGroups.values)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              initiallyExpanded: true,
              title: Text(group.sourceName),
              subtitle: group.isLoading
                  ? Text('Running'.tl)
                  : Text(
                      group.error ??
                          'Found @count comics'.tlParams({
                            'count': group.results.length,
                          }),
                    ),
              children: [
                if (group.isLoading)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: LinearProgressIndicator(),
                  )
                else if (group.error != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      group.error!,
                      style: TextStyle(color: context.colorScheme.error),
                    ),
                  )
                else if (group.results.isEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'No related sources'.tl,
                      style: TextStyle(
                        color: context.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                else
                  for (final result in group.results.take(12))
                    Builder(
                      builder: (context) {
                        final resultIdentity = repository.identityFor(
                          result.sourceKey,
                          result.id,
                        );
                        final linked =
                            acceptedLinksByComicId[resultIdentity.comicId];
                        final isCurrent =
                            resultIdentity.comicId == currentIdentity.comicId;
                        return _RelatedSearchResultRow(
                          comic: result,
                          isLinked: linked != null,
                          isCurrent: isCurrent,
                          onTap: () => showResultPreview(
                            context,
                            result,
                            linked == null
                                ? () => linkSearchResult(
                                    setState,
                                    context,
                                    result,
                                  )
                                : null,
                          ),
                          onLink: linked == null
                              ? () =>
                                    linkSearchResult(setState, context, result)
                              : null,
                          onUnlink: linked != null && !isCurrent
                              ? () => unlinkSearchResult(
                                  setState,
                                  context,
                                  linked,
                                )
                              : null,
                        );
                      },
                    ),
              ],
            ),
        const SizedBox(height: 12),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          title: Text('Advanced precise link'.tl),
          children: [
            TextField(
              controller: sourceKeyController,
              decoration: InputDecoration(
                labelText: 'Source identifier'.tl,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: comicIdController,
              decoration: InputDecoration(
                labelText: 'Comic identifier or URL'.tl,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: Button.outlined(
                onPressed: () {
                  final sourceKey = sourceKeyController.text.trim();
                  final targetComicId = comicIdController.text.trim();
                  if (sourceKey.isEmpty || targetComicId.isEmpty) {
                    context.showMessage(message: 'Invalid input'.tl);
                    return;
                  }
                  try {
                    repository.linkRelatedSource(
                      comic: comic,
                      targetSourceKey: sourceKey,
                      targetComicId: targetComicId,
                    );
                    sourceKeyController.clear();
                    comicIdController.clear();
                    setState(() {});
                    context.showMessage(message: 'Linked'.tl);
                  } catch (e) {
                    context.showMessage(message: e.toString().tl);
                  }
                },
                child: Text('Link'.tl),
              ),
            ),
          ],
        ),
      ],
    );
  }

  return showDialog(
    context: App.rootContext,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) {
          return Dialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: context.brightness == Brightness.dark
                  ? BorderSide(color: context.colorScheme.outlineVariant)
                  : BorderSide.none,
            ),
            insetPadding: context.width < 400
                ? const EdgeInsets.symmetric(horizontal: 4)
                : const EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              width: math.min(640, math.max(300, context.width - 64)),
              height: math.min(680, math.max(420, context.height - 96)),
              child: Column(
                children: [
                  Appbar(
                    leading: IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        dialogClosed = true;
                        context.pop();
                      },
                    ),
                    title: Text('Related Sources'.tl),
                    backgroundColor: Colors.transparent,
                  ),
                  Expanded(
                    child: DefaultTabController(
                      length: 2,
                      child: Column(
                        children: [
                          Material(
                            shape: const Border(),
                            color: context.colorScheme.surfaceContainerLow,
                            child: AppTabBar(
                              tabs: [
                                Tab(text: 'Linked'.tl),
                                Tab(text: 'Search'.tl),
                              ],
                            ),
                          ),
                          Expanded(
                            child: TabBarView(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    8,
                                    16,
                                    8,
                                  ),
                                  child: buildLinkList(setState, context),
                                ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    8,
                                    16,
                                    8,
                                  ),
                                  child: buildSearchList(setState, context),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  ).whenComplete(() {
    dialogClosed = true;
    sourceKeyController.dispose();
    comicIdController.dispose();
    searchController.dispose();
  });
}

class _RelatedSearchGroup {
  const _RelatedSearchGroup({
    required this.sourceKey,
    required this.sourceName,
    this.results = const <Comic>[],
    this.error,
    this.isLoading = false,
  });

  final String sourceKey;
  final String sourceName;
  final List<Comic> results;
  final String? error;
  final bool isLoading;
}

String _sourceKeyFromPlatformId(String platformId) {
  const remotePrefix = 'remote:';
  if (platformId.startsWith(remotePrefix)) {
    return platformId.substring(remotePrefix.length);
  }
  return platformId;
}

String _sourceNameForKey(String sourceKey, String fallback) {
  if (sourceKey == 'local') {
    return 'Local'.tl;
  }
  return ComicSource.find(sourceKey)?.name ?? fallback;
}

class _StableSourceFilterChip extends StatelessWidget {
  const _StableSourceFilterChip({
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final ValueChanged<bool> onSelected;

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      showCheckmark: false,
      labelPadding: const EdgeInsetsDirectional.only(start: 2, end: 8),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 18,
            child: selected ? const Icon(Icons.check, size: 16) : null,
          ),
          Text(label),
        ],
      ),
      selected: selected,
      onSelected: onSelected,
    );
  }
}

String? _relatedStatusFromTags(List<String>? tags) {
  if (tags == null) return null;
  const names = {'status', '状态', '狀態', '連載狀態', '连载状态'};
  for (final tag in tags) {
    final parts = tag.split(RegExp(r'[:：]'));
    if (parts.length < 2) continue;
    if (names.contains(parts.first.trim().toLowerCase())) {
      final value = parts.sublist(1).join(':').trim();
      if (value.isNotEmpty) return value;
    }
  }
  return null;
}

void _showRelatedComicPreview({
  required BuildContext context,
  required String title,
  required String? cover,
  required String sourceKey,
  required String sourceName,
  required String id,
  String? author,
  String? status,
  String? description,
  List<String>? tags,
  List<Widget> actions = const [],
}) {
  showDialog(
    context: context,
    builder: (context) {
      final cleanAuthor = author?.replaceAll('\n', ' ').trim();
      final cleanStatus = status?.replaceAll('\n', ' ').trim();
      final cleanDescription = description?.replaceAll('\n', ' ').trim();
      return ContentDialog(
        title: 'Details'.tl,
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 520,
            maxHeight: math.min(460, context.height - 152),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 86,
                    height: 116,
                    child: cover == null || cover.isEmpty
                        ? ColoredBox(
                            color: context.colorScheme.surfaceContainerHigh,
                          )
                        : AnimatedImage(
                            image: CachedImageProvider(
                              cover,
                              sourceKey: sourceKey,
                              cid: id,
                            ),
                            fit: BoxFit.cover,
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title.replaceAll('\n', ' '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: ts.s18.bold,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        [
                          sourceName,
                          if (cleanAuthor != null && cleanAuthor.isNotEmpty)
                            cleanAuthor,
                          if (cleanStatus != null && cleanStatus.isNotEmpty)
                            cleanStatus,
                        ].join(' · '),
                        style: TextStyle(
                          fontSize: 13,
                          color: context.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (tags != null && tags.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final tag in tags.take(8))
                              Chip(
                                label: Text(tag),
                                visualDensity: VisualDensity.compact,
                              ),
                          ],
                        ),
                      ],
                      if (cleanDescription != null &&
                          cleanDescription.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          cleanDescription,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          ...actions,
          Button.text(onPressed: () => context.pop(), child: Text('Close'.tl)),
        ],
      );
    },
  );
}

class _RelatedSourceRow extends StatelessWidget {
  const _RelatedSourceRow({
    required this.link,
    required this.isCurrent,
    this.onTap,
    this.onAccept,
    this.onReject,
    this.onUnlink,
  });

  final DomainComicSourceLink link;
  final bool isCurrent;
  final VoidCallback? onTap;
  final VoidCallback? onAccept;
  final VoidCallback? onReject;
  final VoidCallback? onUnlink;

  @override
  Widget build(BuildContext context) {
    final statusText = link.status == 'candidate'
        ? 'Candidate'.tl
        : 'Linked'.tl;
    final sourceText = link.linkSource == 'auto' ? 'Auto'.tl : 'Manual'.tl;
    final confidence = link.confidence == null
        ? ''
        : ' ${(link.confidence! * 100).round()}%';
    final author = link.comicAuthor?.replaceAll('\n', ' ').trim();
    final comicStatus = link.comicStatus?.replaceAll('\n', ' ').trim();
    final sourceKey = _sourceKeyFromPlatformId(link.platformId);
    final sourceName = _sourceNameForKey(sourceKey, link.sourceName);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: context.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                width: 38,
                height: 52,
                child: link.comicCoverUri == null || link.comicCoverUri!.isEmpty
                    ? ColoredBox(
                        color: context.colorScheme.surfaceContainerHigh,
                      )
                    : AnimatedImage(
                        image: CachedImageProvider(
                          link.comicCoverUri!,
                          sourceKey: sourceKey,
                          cid: link.sourceComicId,
                        ),
                        fit: BoxFit.cover,
                      ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    link.comicTitle.replaceAll('\n', ' '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      sourceName,
                      if (author != null && author.isNotEmpty) author,
                      if (comicStatus != null && comicStatus.isNotEmpty)
                        comicStatus,
                      statusText,
                      sourceText,
                      if (confidence.isNotEmpty) confidence.trim(),
                      if (isCurrent) 'Current'.tl,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: context.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (onAccept != null)
              Button.icon(
                icon: const Icon(Icons.check, size: 18),
                tooltip: 'Accept'.tl,
                onPressed: onAccept!,
              ),
            if (onReject != null)
              Button.icon(
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Reject'.tl,
                onPressed: onReject!,
              ),
            if (onUnlink != null)
              Button.icon(
                icon: const Icon(Icons.link_off, size: 18),
                tooltip: 'Unlink'.tl,
                onPressed: onUnlink!,
              ),
          ],
        ),
      ),
    );
  }
}

class _RelatedSearchResultRow extends StatelessWidget {
  const _RelatedSearchResultRow({
    required this.comic,
    required this.isLinked,
    required this.isCurrent,
    this.onLink,
    this.onUnlink,
    this.onTap,
  });

  final Comic comic;
  final bool isLinked;
  final bool isCurrent;
  final VoidCallback? onLink;
  final VoidCallback? onUnlink;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final sourceName = _sourceNameForKey(comic.sourceKey, comic.sourceKey);
    final subtitle = comic.subtitle?.replaceAll('\n', ' ').trim();
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: context.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                width: 38,
                height: 52,
                child: AnimatedImage(
                  image: CachedImageProvider(
                    comic.cover,
                    sourceKey: comic.sourceKey,
                    cid: comic.id,
                  ),
                  fit: BoxFit.cover,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    comic.title.replaceAll('\n', ' '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      sourceName,
                      if (subtitle != null && subtitle.isNotEmpty) subtitle,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: context.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            RelatedSearchLinkActions(
              isLinked: isLinked,
              isCurrent: isCurrent,
              onLink: onLink,
              onUnlink: onUnlink,
              unlinkKey: Key(
                'related-search-unlink-${comic.sourceKey}-${comic.id}',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
