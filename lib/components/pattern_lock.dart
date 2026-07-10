import 'package:flutter/material.dart';

/// A 3x3 gesture pattern input. The drawn path is reported to [onComplete] as
/// the sequence of dot indices (0-8, row-major) once the finger lifts.
///
/// Rendering-only widget: it holds no notion of a "correct" pattern — callers
/// compare the reported sequence (e.g. via [patternToString]) against a stored
/// credential.
class PatternLock extends StatefulWidget {
  const PatternLock({
    super.key,
    required this.onComplete,
    this.size = 280,
    this.dimByDefault = false,
  });

  final void Function(List<int> pattern) onComplete;

  final double size;

  /// When true the dots and connecting lines are drawn in the error colour
  /// (used by the parent to signal a mismatch).
  final bool dimByDefault;

  @override
  State<PatternLock> createState() => _PatternLockState();
}

class _PatternLockState extends State<PatternLock> {
  final List<int> _selected = [];
  Offset? _currentPointer;

  static const _dots = 3;

  double get _cell => widget.size / _dots;

  Offset _dotCenter(int index) {
    var row = index ~/ _dots;
    var col = index % _dots;
    return Offset(_cell * col + _cell / 2, _cell * row + _cell / 2);
  }

  int? _hitDot(Offset pos) {
    for (var i = 0; i < _dots * _dots; i++) {
      if ((pos - _dotCenter(i)).distance < _cell * 0.3) {
        return i;
      }
    }
    return null;
  }

  void _addDot(Offset pos) {
    var dot = _hitDot(pos);
    if (dot != null && !_selected.contains(dot)) {
      // Auto-include the dot crossed on the straight line between the last
      // selected dot and this one (standard Android pattern behaviour).
      if (_selected.isNotEmpty) {
        var last = _selected.last;
        var mid = _dotBetween(last, dot);
        if (mid != null && !_selected.contains(mid)) {
          _selected.add(mid);
        }
      }
      _selected.add(dot);
    }
  }

  /// The dot lying exactly midway between [a] and [b], if any (e.g. 0->2 passes
  /// through 1, 0->8 through 4).
  int? _dotBetween(int a, int b) {
    var ra = a ~/ _dots, ca = a % _dots;
    var rb = b ~/ _dots, cb = b % _dots;
    if ((ra + rb) % 2 != 0 || (ca + cb) % 2 != 0) return null;
    var mr = (ra + rb) ~/ 2, mc = (ca + cb) ~/ 2;
    return mr * _dots + mc;
  }

  void _onPanEnd() {
    if (_selected.isNotEmpty) {
      widget.onComplete(List.of(_selected));
    }
    setState(() {
      _selected.clear();
      _currentPointer = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    var color = widget.dimByDefault
        ? context.theme.colorScheme.error
        : context.theme.colorScheme.primary;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: GestureDetector(
        onPanStart: (d) => setState(() {
          _selected.clear();
          _addDot(d.localPosition);
          _currentPointer = d.localPosition;
        }),
        onPanUpdate: (d) => setState(() {
          _addDot(d.localPosition);
          _currentPointer = d.localPosition;
        }),
        onPanEnd: (_) => _onPanEnd(),
        child: CustomPaint(
          painter: _PatternPainter(
            // Snapshot the selection: _selected is mutated in place, so passing
            // it by reference would make shouldRepaint's list compare useless.
            selected: List.of(_selected),
            pointer: _currentPointer,
            dotCenter: _dotCenter,
            color: color,
            baseColor: context.theme.colorScheme.outlineVariant,
          ),
        ),
      ),
    );
  }
}

class _PatternPainter extends CustomPainter {
  _PatternPainter({
    required this.selected,
    required this.pointer,
    required this.dotCenter,
    required this.color,
    required this.baseColor,
  });

  final List<int> selected;
  final Offset? pointer;
  final Offset Function(int) dotCenter;
  final Color color;
  final Color baseColor;

  @override
  void paint(Canvas canvas, Size size) {
    var cell = size.width / 3;
    var dotRadius = cell * 0.08;
    var selectedRadius = cell * 0.14;

    var linePaint = Paint()
      ..color = color
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // Connect selected dots in order.
    for (var i = 0; i < selected.length - 1; i++) {
      canvas.drawLine(
        dotCenter(selected[i]),
        dotCenter(selected[i + 1]),
        linePaint,
      );
    }
    // Trailing line to the current finger position.
    if (selected.isNotEmpty && pointer != null) {
      canvas.drawLine(dotCenter(selected.last), pointer!, linePaint);
    }

    for (var i = 0; i < 9; i++) {
      var isSelected = selected.contains(i);
      var paint = Paint()
        ..color = isSelected ? color : baseColor
        ..style = PaintingStyle.fill;
      canvas.drawCircle(
        dotCenter(i),
        isSelected ? selectedRadius : dotRadius,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_PatternPainter old) {
    if (old.pointer != pointer) return true;
    if (old.selected.length != selected.length) return true;
    for (var i = 0; i < selected.length; i++) {
      if (old.selected[i] != selected[i]) return true;
    }
    return false;
  }
}

/// Serialise a pattern to a stable string for hashing/comparison.
String patternToString(List<int> pattern) => pattern.join('-');

extension _ThemeContext on BuildContext {
  ThemeData get theme => Theme.of(this);
}
