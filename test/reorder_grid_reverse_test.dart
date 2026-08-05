import 'package:flutter/material.dart';
import 'package:flutter_reorderable_grid_view/widgets/reorderable_builder.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression guard for the reorder page's "Reverse" action.
///
/// [ReorderableBuilder] caches every item's on-screen rectangle and only
/// refreshes the entries whose children it rebuilds. Replacing the whole list
/// in place therefore leaves the off-screen items pointing at stale rectangles,
/// and collision detection during the next drag compares against those, so
/// neighbours stop making way. Remounting the builder rebuilds the cache.
class _ReorderPage extends StatefulWidget {
  const _ReorderPage({
    super.key,
    required this.items,
    required this.remountAfterReverse,
  });

  final List<String> items;

  /// Mirrors the fix: assign a new key when the list is replaced wholesale.
  final bool remountAfterReverse;

  @override
  State<_ReorderPage> createState() => _ReorderPageState();
}

class _ReorderPageState extends State<_ReorderPage> {
  final _gridKey = GlobalKey();
  final _scrollController = ScrollController();
  var _builderKey = UniqueKey();
  late var items = [...widget.items];

  void reverse() {
    setState(() {
      items = items.reversed.toList();
      if (widget.remountAfterReverse) {
        _builderKey = UniqueKey();
      }
    });
  }

  void jumpToTop() {
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tiles = items
        .map(
          (e) => SizedBox(
            key: Key(e),
            height: _rowHeight,
            child: Center(child: Text(e)),
          ),
        )
        .toList();
    return Scaffold(
      body: ReorderableBuilder<String>(
        key: _builderKey,
        scrollController: _scrollController,
        longPressDelay: const Duration(milliseconds: 500),
        onReorder: (reorderFunc) {
          setState(() => items = reorderFunc(items));
        },
        builder: (children) => GridView(
          key: _gridKey,
          controller: _scrollController,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 1,
            mainAxisExtent: _rowHeight,
          ),
          children: children,
        ),
        children: tiles,
      ),
    );
  }
}

const _rowHeight = 200.0;

/// Drags the tile on row 1 down onto row 2. Both rows sit far from the
/// viewport edges, so the package's autoscroll never kicks in and the gesture
/// always lands on a real tile.
Future<void> _dragRow1ToRow2(WidgetTester tester) async {
  const from = Offset(200, _rowHeight * 1.5);
  final gesture = await tester.startGesture(from);
  await tester.pump(const Duration(milliseconds: 600));
  for (var i = 1; i <= 12; i++) {
    await gesture.moveTo(Offset(from.dx, from.dy + _rowHeight * i / 12));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pumpAndSettle();
}

/// Reverses the list once, then performs [rounds] identical drags and returns
/// the rounds whose resulting order was wrong.
Future<List<int>> _reverseThenDrag(
  WidgetTester tester, {
  required bool remountAfterReverse,
  int rounds = 6,
}) async {
  final key = GlobalKey<_ReorderPageState>();
  await tester.pumpWidget(
    MaterialApp(
      home: _ReorderPage(
        key: key,
        // Many more items than fit on screen, so most are never built.
        items: List.generate(40, (i) => 'c$i'),
        remountAfterReverse: remountAfterReverse,
      ),
    ),
  );
  await tester.pumpAndSettle();

  final state = key.currentState!;
  state.reverse();
  await tester.pumpAndSettle();

  final wrongRounds = <int>[];
  for (var round = 1; round <= rounds; round++) {
    state.jumpToTop();
    await tester.pumpAndSettle();

    final expected = [...state.items];
    expected.insert(2, expected.removeAt(1));

    await _dragRow1ToRow2(tester);

    // Only the head is compared: that is where the drag happened, and it is
    // what the user sees fail to make way.
    if (state.items.take(6).join(',') != expected.take(6).join(',')) {
      wrongRounds.add(round);
    }
  }
  return wrongRounds;
}

void main() {
  setUp(() => TestWidgetsFlutterBinding.ensureInitialized());

  testWidgets('drags keep working after the list is reversed', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final wrongRounds = await _reverseThenDrag(
      tester,
      remountAfterReverse: true,
    );
    expect(wrongRounds, isEmpty);
  });

  testWidgets('reversing in place is what broke the following drags', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // Proves the remount above is load-bearing rather than decorative: without
    // it the stale position cache misplaces the dragged item.
    //
    // This asserts on flutter_reorderable_grid_view's current behaviour. If a
    // future version of the package refreshes its cache on wholesale list
    // changes, this expectation flips and both this test and the UniqueKey in
    // _ReorderComicsPageState can be dropped.
    final wrongRounds = await _reverseThenDrag(
      tester,
      remountAfterReverse: false,
    );
    expect(wrongRounds, isNotEmpty);
  });

  testWidgets('repeated drags without any reverse stay correct', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final key = GlobalKey<_ReorderPageState>();
    await tester.pumpWidget(
      MaterialApp(
        home: _ReorderPage(
          key: key,
          items: List.generate(40, (i) => 'c$i'),
          remountAfterReverse: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final state = key.currentState!;
    for (var round = 1; round <= 8; round++) {
      final expected = [...state.items];
      expected.insert(2, expected.removeAt(1));

      await _dragRow1ToRow2(tester);

      expect(
        state.items.take(6).toList(),
        expected.take(6).toList(),
        reason: 'round $round moved the wrong item',
      );
    }
  });
}
