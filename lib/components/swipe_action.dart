part of "components.dart";

/// The pair of swipe panes for a tile: [start] reveals on a right swipe,
/// [end] reveals on a left swipe. Either may be null.
typedef SwipePanes = ({SwipePane? start, SwipePane? end});

/// One actionable item shown when a tile is swiped open.
class SwipeAction {
  const SwipeAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.backgroundColor,
    this.foregroundColor,
  });

  final IconData icon;

  final String label;

  /// Runs when the user taps the revealed action.
  final VoidCallback onPressed;

  final Color? backgroundColor;

  final Color? foregroundColor;
}

/// Configuration for one side (start = right-swipe, end = left-swipe) of a
/// swipeable tile.
class SwipePane {
  const SwipePane({
    required this.actions,
    this.dismissOnFullSwipe = false,
    this.onFullSwipe,
    this.extentRatio = 0.28,
    this.dismissThreshold = 0.55,
  }) : assert(
          !dismissOnFullSwipe || onFullSwipe != null,
          'dismissOnFullSwipe requires onFullSwipe',
        );

  /// Actions revealed by a light swipe. Each is tap-to-execute.
  final List<SwipeAction> actions;

  /// When true, a large swipe past [dismissThreshold] dismisses the tile and
  /// runs [onFullSwipe] without a tap. When false, the pane only ever reveals
  /// [actions] and the user must tap one.
  final bool dismissOnFullSwipe;

  /// Runs on a large swipe when [dismissOnFullSwipe] is true.
  final VoidCallback? onFullSwipe;

  /// Fraction of tile width the pane occupies when fully revealed.
  final double extentRatio;

  /// Fraction of tile width the user must cross for a full-swipe dismissal.
  final double dismissThreshold;
}

/// Wraps [child] so it can be swiped open to reveal [startPane] (right swipe)
/// and/or [endPane] (left swipe). Reusable across any list/grid tile.
///
/// Supports the spectrum of patterns the app needs:
/// - light swipe reveals one or more tap-to-run actions;
/// - large swipe auto-runs a primary action (opt in via
///   [SwipePane.dismissOnFullSwipe]).
class SwipeActionTile extends StatelessWidget {
  const SwipeActionTile({
    super.key,
    required this.child,
    this.startPane,
    this.endPane,
    this.groupTag = 'swipe-action-tile',
  });

  final Widget child;

  /// Revealed by a right swipe (from the leading edge).
  final SwipePane? startPane;

  /// Revealed by a left swipe (from the trailing edge).
  final SwipePane? endPane;

  /// Slidables sharing a tag auto-close when another in the group opens.
  final Object groupTag;

  ActionPane? _buildPane(BuildContext context, SwipePane? pane) {
    if (pane == null || pane.actions.isEmpty) return null;
    return ActionPane(
      motion: const StretchMotion(),
      extentRatio: pane.extentRatio,
      dismissible: pane.dismissOnFullSwipe
          ? DismissiblePane(
              dismissThreshold: pane.dismissThreshold,
              onDismissed: pane.onFullSwipe!,
            )
          : null,
      children: [
        for (final action in pane.actions)
          SlidableAction(
            onPressed: (_) => action.onPressed(),
            backgroundColor:
                action.backgroundColor ?? context.colorScheme.error,
            foregroundColor:
                action.foregroundColor ?? context.colorScheme.onError,
            icon: action.icon,
            label: action.label,
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Slidable(
      // DismissiblePane requires the Slidable to carry a Key so list items are
      // synced by identity, not index, when one is dismissed and removed.
      key: key,
      groupTag: groupTag,
      startActionPane: _buildPane(context, startPane),
      endActionPane: _buildPane(context, endPane),
      child: child,
    );
  }
}
