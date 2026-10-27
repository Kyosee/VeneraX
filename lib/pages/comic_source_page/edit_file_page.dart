part of '../comic_source_page.dart';

class _EditFilePage extends StatefulWidget {
  const _EditFilePage(this.path, this.onExit);

  final String path;

  final void Function() onExit;

  @override
  State<_EditFilePage> createState() => __EditFilePageState();
}

class __EditFilePageState extends State<_EditFilePage> {
  var current = '';
  var _initial = '';

  @override
  void initState() {
    super.initState();
    current = File(widget.path).readAsStringSync();
    _initial = current;
  }

  @override
  void dispose() {
    if (current != _initial) {
      // Atomic replace: dispose can race an app kill; a truncated script
      // would fail to parse at next startup and lose the source.
      writeStringAtomicSync(widget.path, current);
    }
    widget.onExit();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(title: Text("Edit".tl)),
      body: Column(
        children: [
          Container(height: 0.6, color: context.colorScheme.outlineVariant),
          Expanded(
            child: CodeEditor(
              initialValue: current,
              onChanged: (value) => current = value,
            ),
          ),
        ],
      ),
    );
  }
}
