import 'package:flutter/material.dart';
import 'package:venera/components/app_slider_theme.dart';

class CustomSlider extends StatefulWidget {
  const CustomSlider({
    required this.min,
    required this.max,
    required this.value,
    required this.divisions,
    required this.onChanged,
    required this.focusNode,
    this.reversed = false,
    super.key,
  });

  final double min;
  final double max;
  final double value;
  final int divisions;
  final ValueChanged<double> onChanged;
  final FocusNode? focusNode;
  final bool reversed;

  @override
  State<CustomSlider> createState() => _CustomSliderState();
}

class _CustomSliderState extends State<CustomSlider> {
  // Ignore repeated positions beyond an edge during the same gesture.
  double? _reported;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: widget.max > widget.min
          ? Directionality(
              textDirection: widget.reversed
                  ? TextDirection.rtl
                  : TextDirection.ltr,
              child: SliderTheme(
                data: appSliderTheme(
                  Theme.of(context).colorScheme,
                ).copyWith(padding: EdgeInsets.zero),
                child: Slider(
                  min: widget.min,
                  max: widget.max,
                  value: widget.value.clamp(widget.min, widget.max),
                  divisions: widget.divisions,
                  focusNode: widget.focusNode,
                  onChangeStart: (_) => _reported = null,
                  onChanged: (value) {
                    if (value == _reported) return;
                    _reported = value;
                    widget.onChanged(value);
                  },
                ),
              ),
            )
          : null,
    );
  }
}
