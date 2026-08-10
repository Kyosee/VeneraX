part of 'components.dart';

/// The one search-input look used across the app: a pill-shaped filled box with
/// a leading search icon and an inline clear button.
///
/// Passing [onTap] turns it into a read-only entry point that opens a real
/// search page instead of accepting text.
class AppSearchField extends StatefulWidget {
  const AppSearchField({
    super.key,
    this.controller,
    this.hintText,
    this.autofocus = false,
    this.onChanged,
    this.onTap,
    this.height,
  });

  final TextEditingController? controller;

  final String? hintText;

  final bool autofocus;

  final ValueChanged<String>? onChanged;

  /// Renders the field as a button instead of a text input.
  final VoidCallback? onTap;

  /// Defaults to [defaultHeight].
  final double? height;

  static double get defaultHeight => App.isMobile ? 52 : 46;

  /// For a field hosted in an app bar title, where 52px would leave no margin.
  static const double toolbarHeight = 40;

  @override
  State<AppSearchField> createState() => _AppSearchFieldState();
}

class _AppSearchFieldState extends State<AppSearchField> {
  TextEditingController? _ownedController;

  TextEditingController get _controller =>
      widget.controller ?? (_ownedController ??= TextEditingController());

  @override
  void dispose() {
    _ownedController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var height = widget.height ?? AppSearchField.defaultHeight;
    var radius = BorderRadius.circular(height / 2);
    var hint = widget.hintText ?? "Search".tl;

    Widget content;
    if (widget.onTap != null) {
      content = InkWell(
        borderRadius: radius,
        onTap: widget.onTap,
        child: Row(
          children: [
            const SizedBox(width: 16),
            const Icon(Icons.search),
            const SizedBox(width: 8),
            Expanded(
              // Matches the hint colour an editable field would use, so the
              // home entry point and a real search box read the same.
              child: Text(
                hint,
                style: ts.s16.withColor(context.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      );
    } else {
      content = Row(
        children: [
          const SizedBox(width: 16),
          const Icon(Icons.search),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _controller,
              autofocus: widget.autofocus,
              decoration: InputDecoration(
                hintText: hint,
                border: InputBorder.none,
                isCollapsed: true,
              ),
              onChanged: widget.onChanged,
            ),
          ),
          ListenableBuilder(
            listenable: _controller,
            builder: (context, child) {
              if (_controller.text.isEmpty) {
                return const SizedBox(width: 16);
              }
              return IconButton(
                iconSize: 20,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.clear),
                tooltip: "Clear".tl,
                onPressed: () {
                  _controller.clear();
                  widget.onChanged?.call("");
                },
              );
            },
          ),
          const SizedBox(width: 4),
        ],
      );
    }

    return Material(
      color: context.colorScheme.surfaceContainerHigh,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: SizedBox(height: height, child: content),
    );
  }
}
