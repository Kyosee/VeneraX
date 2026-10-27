part of 'comic_page.dart';

class _SelectDownloadChapter extends StatefulWidget {
  const _SelectDownloadChapter(
    this.eps,
    this.finishSelect,
    this.downloadedEps, {
    required this.chapterOrder,
    this.hiddenEps = const {},
  });

  final List<String> eps;
  final void Function(List<int>) finishSelect;
  final List<int> downloadedEps;
  final List<int> chapterOrder;

  /// Indices collapsed by the comic's "hide duplicate chapters" switch. They are
  /// dropped from the list AND from "Download All": the picker returns indices
  /// into [eps], so a hidden entry left in the result would silently download a
  /// chapter the user cannot see.
  final Set<int> hiddenEps;

  @override
  State<_SelectDownloadChapter> createState() => _SelectDownloadChapterState();
}

class _SelectDownloadChapterState extends State<_SelectDownloadChapter> {
  List<int> selected = [];

  /// Original indices into [widget.eps] that are rendered, in list order.
  List<int> get _visible => [
    for (final i in widget.chapterOrder)
      if (!widget.hiddenEps.contains(i)) i,
  ];

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    return Scaffold(
      appBar: Appbar(
        title: Text("Download".tl),
        backgroundColor: context.colorScheme.surfaceContainerLow,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: visible.length,
              itemBuilder: (context, slot) {
                final i = visible[slot];
                return CheckboxListTile(
                  title: Text(widget.eps[i]),
                  value:
                      selected.contains(i) || widget.downloadedEps.contains(i),
                  onChanged: widget.downloadedEps.contains(i)
                      ? null
                      : (v) {
                          setState(() {
                            if (selected.contains(i)) {
                              selected.remove(i);
                            } else {
                              selected.add(i);
                            }
                          });
                        },
                );
              },
            ),
          ),
          Container(
            height: 50,
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: context.colorScheme.outlineVariant),
              ),
            ),
            child: Row(
              children: [
                const SizedBox(width: 16),
                Expanded(
                  child: TextButton(
                    onPressed: () {
                      var res = <int>[];
                      for (final i in visible) {
                        if (!widget.downloadedEps.contains(i)) {
                          res.add(i);
                        }
                      }
                      widget.finishSelect(res);
                      context.pop();
                    },
                    child: Text("Download All".tl),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: FilledButton(
                    onPressed: selected.isEmpty
                        ? null
                        : () {
                            widget.finishSelect(
                              visible.where(selected.contains).toList(),
                            );
                            context.pop();
                          },
                    child: Text("Download Selected".tl),
                  ),
                ),
                const SizedBox(width: 16),
              ],
            ),
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
  }
}
