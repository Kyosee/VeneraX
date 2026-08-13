import "package:flutter/material.dart";
import "package:venera/components/components.dart";
import "package:venera/foundation/app.dart";
import "package:venera/foundation/comic_source/comic_source.dart";
import "package:venera/utils/translations.dart";

class RankingPage extends StatefulWidget {
  const RankingPage({required this.categoryKey, super.key});

  final String categoryKey;

  @override
  State<RankingPage> createState() => _RankingPageState();
}

class _RankingPageState extends State<RankingPage> {
  late final CategoryComicsData data;
  late final Map<String, String> options;
  late String optionValue;

  void Function()? _enterSelection;
  bool _selecting = false;

  void findData() {
    for (final source in ComicSource.all()) {
      if (source.categoryData?.key == widget.categoryKey) {
        data = source.categoryComicsData!;
        options = data.rankingData!.options;
        optionValue = options.keys.first;
        return;
      }
    }
    throw "${widget.categoryKey} Not found";
  }

  @override
  void initState() {
    findData();
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    var topPadding = context.padding.top + 56;
    return Scaffold(
      extendBodyBehindAppBar: true,
      // The grid renders its own selection bar; hide this one while selecting.
      appBar: _selecting
          ? null
          : Appbar(
              title: Text("Ranking".tl),
              actions: [
                Tooltip(
                  message: "Multi-Select".tl,
                  child: IconButton(
                    icon: const Icon(Icons.checklist),
                    onPressed: () => _enterSelection?.call(),
                  ),
                ),
              ],
            ),
      body: ComicList(
        key: Key(optionValue),
        enableSelection: true,
        selectionHandlerCallback: (fn) => _enterSelection = fn,
        onSelectionStateChanged: (s) => setState(() => _selecting = s),
        errorLeading: SizedBox(height: topPadding),
        leadingSliver:
            buildOptions().sliverPadding(EdgeInsets.only(top: topPadding)),
        scrollbarTopPadding: topPadding,
        loadPage: data.rankingData!.load == null
            ? null
            : (i) => data.rankingData!.load!(optionValue, i),
        loadNext: data.rankingData!.loadWithNext == null
            ? null
            : (i) => data.rankingData!.loadWithNext!(optionValue, i),
      ),
    );
  }

  Widget buildOptionItem(String text, String value, BuildContext context) {
    return OptionChip(
      text: text,
      isSelected: value == optionValue,
      onTap: () {
        if (value == optionValue) return;
        setState(() {
          optionValue = value;
        });
      },
    );
  }

  Widget buildOptions() {
    List<Widget> children = [];
    children.add(Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var option in options.entries)
          buildOptionItem(option.value.tl, option.key, context)
      ],
    ));
    return SliverToBoxAdapter(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [...children, const Divider()],
      ).paddingLeft(8).paddingRight(8),
    );
  }
}
