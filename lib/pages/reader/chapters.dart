part of 'reader.dart';

class _ChaptersView extends StatefulWidget {
  const _ChaptersView(this.reader);

  final _ReaderState reader;

  @override
  State<_ChaptersView> createState() => _ChaptersViewState();
}

class _ChaptersViewState extends State<_ChaptersView> {
  bool desc = false;

  late final ScrollController _scrollController;

  var downloaded = <String>[];

  List<int> get _visibleIndices => [
    for (final chapter in widget.reader.chapterOrder)
      if (!widget.reader.isChapterHidden(chapter) ||
          widget.reader.chapter == chapter)
        chapter - 1,
  ];

  @override
  void initState() {
    super.initState();
    final epIndex = _visibleIndices.indexOf(widget.reader.chapter - 1) - 1;
    _scrollController = ScrollController(
      initialScrollOffset: (epIndex * 48.0 + 52).clamp(0, double.infinity),
    );
    var local = LocalManager().find(widget.reader.cid, widget.reader.type);
    if (local != null) {
      downloaded = local.downloadedChapters;
    }
  }

  @override
  Widget build(BuildContext context) {
    var chapters = widget.reader.widget.chapters!;
    var current = widget.reader.chapter - 1;
    // Flat 0-based indices still shown after "hide duplicate chapters". The
    // current chapter is kept even when hidden, so a history entry pointing at
    // a duplicate still highlights something.
    final visible = _visibleIndices;
    return Scaffold(
      body: SmoothCustomScrollView(
        controller: _scrollController,
        scrollbarTopPadding: context.padding.top + 56,
        slivers: [
          SliverAppbar(
            style: AppbarStyle.shadow,
            title: Text("Chapters".tl),
            actions: [
              Tooltip(
                message: "Click to change the order".tl,
                child: TextButton.icon(
                  icon: Icon(
                    !desc ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 18,
                  ),
                  label: Text(!desc ? "Ascending".tl : "Descending".tl),
                  onPressed: () {
                    setState(() {
                      desc = !desc;
                    });
                  },
                ),
              ),
            ],
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) {
                var index = visible[desc ? visible.length - 1 - i : i];
                var chapter = chapters.titles.elementAt(index);
                return _ChapterListTile(
                  onTap: () {
                    widget.reader.toChapter(index + 1);
                    Navigator.of(context).pop();
                  },
                  title: chapter,
                  isActive: current == index,
                  isDownloaded:
                      downloaded.contains(chapters.ids.elementAt(index)),
                );
              },
              childCount: visible.length,
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupedChaptersView extends StatefulWidget {
  const _GroupedChaptersView(this.reader);

  final _ReaderState reader;

  @override
  State<_GroupedChaptersView> createState() => _GroupedChaptersViewState();
}

class _GroupedChaptersViewState extends State<_GroupedChaptersView>
    with SingleTickerProviderStateMixin {
  ComicChapters get chapters => widget.reader.widget.chapters!;

  late final TabController tabController;

  late final ScrollController _scrollController;

  late final String initialGroupName;

  var downloaded = <String>[];

  @override
  void initState() {
    super.initState();
    int index = 0;
    int epIndex = widget.reader.chapter - 1;
    while (epIndex >= 0) {
      epIndex -= chapters.getGroupByIndex(index).length;
      index++;
    }
    tabController = TabController(
      length: chapters.groups.length,
      vsync: this,
      initialIndex: index - 1,
    );
    initialGroupName = chapters.groups.elementAt(index - 1);
    final epIndexAtGroup = _visibleChapters(
      initialGroupName,
    ).indexOf(widget.reader.chapter);
    _scrollController = ScrollController(
      initialScrollOffset: (epIndexAtGroup * 48.0).clamp(0, double.infinity),
    );
    var local = LocalManager().find(widget.reader.cid, widget.reader.type);
    if (local != null) {
      downloaded = local.downloadedChapters;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Appbar(title: Text("Chapters".tl)),
        AppTabBar(
          controller: tabController,
          tabs: chapters.groups.map((e) => Tab(text: e)).toList(),
        ),
        Expanded(
          child: TabViewBody(
            controller: tabController,
            children: chapters.groups.map(buildGroup).toList(),
          ),
        ),
      ],
    );
  }

  List<int> _visibleChapters(String groupName) {
    var group = chapters.getGroup(groupName);
    // Flat 1-based chapter number of this group's first entry.
    var base = 1;
    for (var g in chapters.groups) {
      if (g == groupName) break;
      base += chapters.getGroup(g).length;
    }
    // Chapters of this group in reading order that survive "hide duplicate
    // chapters"; the current chapter is kept even when hidden.
    return [
      for (final chapter in widget.reader.chapterOrder)
        if (chapter >= base &&
            chapter < base + group.length &&
            (!widget.reader.isChapterHidden(chapter) ||
                widget.reader.chapter == chapter))
          chapter,
    ];
  }

  Widget buildGroup(String groupName) {
    final visible = _visibleChapters(groupName);
    return SmoothCustomScrollView(
      controller: initialGroupName == groupName ? _scrollController : null,
      slivers: [
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, position) {
              final i = visible[position];
              final name = chapters.titles.elementAt(i - 1);
              return _ChapterListTile(
                onTap: () {
                  widget.reader.toChapter(i);
                  context.pop();
                },
                title: name,
                isActive: widget.reader.chapter == i,
                isDownloaded: downloaded.contains(
                  chapters.ids.elementAt(i - 1),
                ),
              );
            },
            childCount: visible.length,
          ),
        ),
      ],
    );
  }
}

class _ChapterListTile extends StatelessWidget {
  const _ChapterListTile({
    required this.title,
    required this.isActive,
    required this.isDownloaded,
    required this.onTap,
  });

  final String title;

  final bool isActive;

  final bool isDownloaded;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color:
                  isActive ? context.colorScheme.primary : Colors.transparent,
              width: 4,
            ),
          ),
        ),
        child: Row(
          children: [
            Text(
              title,
              style: isActive
                  ? ts.withColor(context.colorScheme.primary).bold.s16
                  : ts.s16,
            ),
            const Spacer(),
            if (isDownloaded)
              Icon(
                Icons.download_done_rounded,
                color: context.colorScheme.secondary,
              ),
          ],
        ),
      ),
    );
  }
}
