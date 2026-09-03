import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Exercises the scroll-view mechanics the continuous reader relies on when it
/// re-pivots onto a far page: two slivers around a center key, both re-keyed on
/// every pivot move, children carrying GlobalKeys that migrate between the
/// slivers, and a jumpTo(0) issued before the new layout.
void main() {
  const viewport = 800.0;
  const placeholder = 300.0;
  const loadedExtent = 1200.0;

  testWidgets('re-pivot puts the target at the leading edge', (tester) async {
    final harness = _Harness(count: 100);
    await tester.pumpWidget(harness.build(viewport));
    await harness.state.repivot(60);
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(harness.topOf(tester, 60), 0.0);
  });

  testWidgets('placeholders above the pivot growing do not move it', (
    tester,
  ) async {
    final harness = _Harness(count: 100);
    await tester.pumpWidget(harness.build(viewport));
    await harness.state.repivot(60);
    await tester.pump();

    harness.state.markLoaded(List.generate(10, (i) => 50 + i));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(harness.topOf(tester, 60), 0.0);
    expect(harness.topOf(tester, 59), -loadedExtent);
  });

  testWidgets('scrolling to a non-pivot target drifts as pages above load', (
    tester,
  ) async {
    // The failure mode the re-pivot replaces: with the pivot left at page 0,
    // scrolling so that page 4 sits at the top holds only until pages 1..3
    // resolve their real heights — then page 1 is what fills the viewport.
    final harness = _Harness(count: 100);
    await tester.pumpWidget(harness.build(viewport));
    harness.state.controller.jumpTo(4 * placeholder);
    await tester.pump();
    expect(harness.topOf(tester, 4), 0.0);

    harness.state.markLoaded([1, 2, 3]);
    await tester.pump();

    expect(harness.topOf(tester, 4), 3 * (loadedExtent - placeholder));
    expect(harness.topOf(tester, 1), placeholder - 4 * placeholder);
  });

  testWidgets('re-pivot backwards and forwards keeps working', (tester) async {
    final harness = _Harness(count: 100);
    await tester.pumpWidget(harness.build(viewport));
    await harness.state.repivot(60);
    await tester.pump();
    await harness.state.repivot(10);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(harness.topOf(tester, 10), 0.0);

    await harness.state.repivot(99);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(harness.topOf(tester, 99), 0.0);
  });

  testWidgets('re-pivot within the laid-out window keeps child states', (
    tester,
  ) async {
    final harness = _Harness(count: 100);
    await tester.pumpWidget(harness.build(viewport));
    final before = Map.of(_ProbeState.initCounts);

    // Page 1 is on screen for both pivots; it must migrate between the
    // slivers instead of being rebuilt from scratch.
    await harness.state.repivot(2);
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(harness.topOf(tester, 2), 0.0);
    expect(_ProbeState.initCounts[1], before[1]);
  });
}

class _Harness {
  _Harness({required this.count});

  final int count;
  final key = GlobalKey<_PivotListState>();

  _PivotListState get state => key.currentState!;

  Widget build(double viewport) {
    return MaterialApp(
      home: Center(
        child: SizedBox(
          width: 400,
          height: viewport,
          child: _PivotList(key: key, count: count),
        ),
      ),
    );
  }

  /// Top of item [index] relative to the list's own top edge. Sliver children
  /// outside the visible area count as offstage, so don't skip them.
  double topOf(WidgetTester tester, int index) {
    final listTop = tester.getTopLeft(find.byType(_PivotList)).dy;
    final item = find.byKey(state.keys[index], skipOffstage: false);
    return tester.getTopLeft(item).dy - listTop;
  }
}

class _PivotList extends StatefulWidget {
  const _PivotList({super.key, required this.count});

  final int count;

  @override
  State<_PivotList> createState() => _PivotListState();
}

class _PivotListState extends State<_PivotList> {
  final controller = ScrollController();
  late final keys = List.generate(
    widget.count,
    (i) => GlobalKey<_ProbeState>(),
  );
  final loaded = <int>{};
  int anchor = 0;
  int generation = 0;
  GlobalKey centerKey = GlobalKey();

  Future<void> repivot(int index) async {
    setState(() {
      anchor = index;
      generation++;
      centerKey = GlobalKey();
    });
    controller.jumpTo(0);
  }

  void markLoaded(Iterable<int> indexes) {
    setState(() => loaded.addAll(indexes));
  }

  Widget _item(int i) => _Probe(
    key: keys[i],
    index: i,
    extent: loaded.contains(i) ? 1200.0 : 300.0,
  );

  @override
  Widget build(BuildContext context) {
    final before = anchor;
    return CustomScrollView(
      controller: controller,
      center: centerKey,
      anchor: 0.0,
      // The reader keeps about four viewports built ahead; the placeholders
      // that later grow and drift a scrolled-to page live in that window.
      scrollCacheExtent: const ScrollCacheExtent.pixels(3200),
      slivers: [
        SliverList(
          key: ValueKey('lead$generation'),
          delegate: SliverChildBuilderDelegate(
            (context, i) => _item(before - 1 - i),
            childCount: before,
            addAutomaticKeepAlives: false,
          ),
        ),
        SliverList(
          key: centerKey,
          delegate: SliverChildBuilderDelegate(
            (context, i) => _item(before + i),
            childCount: widget.count - before,
            addAutomaticKeepAlives: false,
          ),
        ),
      ],
    );
  }
}

class _Probe extends StatefulWidget {
  const _Probe({super.key, required this.index, required this.extent});

  final int index;
  final double extent;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  static final initCounts = <int, int>{};

  @override
  void initState() {
    super.initState();
    initCounts.update(widget.index, (n) => n + 1, ifAbsent: () => 1);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(height: widget.extent, child: Text('${widget.index}'));
  }
}
