import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera/foundation/disclaimer_content.dart';
import 'package:venera/pages/disclaimer.dart';
import 'package:venera/utils/translations.dart';

class TvAgreement extends StatefulWidget {
  const TvAgreement({super.key, required this.accept, required this.decline});
  final Future<void> Function() accept;
  final VoidCallback decline;
  @override
  State<TvAgreement> createState() => _TvAgreementState();
}

class _TvAgreementState extends State<TvAgreement> {
  final document = FocusNode();
  final checkbox = FocusNode();
  final scroll = ScrollController();
  bool checked = false;
  bool busy = false;

  @override
  void dispose() {
    document.dispose();
    checkbox.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> accept() async {
    if (busy || !checked) return;
    setState(() => busy = true);
    try {
      await widget.accept();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  KeyEventResult read(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter) {
      if (event is KeyDownEvent) checkbox.requestFocus();
      return KeyEventResult.handled;
    }
    if (key != LogicalKeyboardKey.arrowDown &&
        key != LogicalKeyboardKey.arrowUp) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyUpEvent && scroll.hasClients) {
      final pos = scroll.position;
      final delta =
          pos.viewportDimension *
          (key == LogicalKeyboardKey.arrowDown ? .78 : -.78);
      scroll.jumpTo((pos.pixels + delta).clamp(0, pos.maxScrollExtent));
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'User Agreement & Disclaimer'.tl,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  AgreementLanguagePicker(
                    enabled: !busy,
                    onChanged: () => setState(() {}),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: 3,
                      child: Focus(
                        focusNode: document,
                        autofocus: true,
                        onKeyEvent: read,
                        onFocusChange: (_) => setState(() {}),
                        child: Container(
                          decoration: BoxDecoration(
                            color: colors.surfaceContainerLow,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: document.hasFocus
                                  ? colors.primary
                                  : colors.outlineVariant,
                              width: 2,
                            ),
                          ),
                          child: Scrollbar(
                            controller: scroll,
                            thumbVisibility: true,
                            child: SingleChildScrollView(
                              controller: scroll,
                              primary: false,
                              padding: const EdgeInsets.all(16),
                              child: const DisclaimerBody(wide: true),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      flex: 2,
                      child: Focus(
                        onKeyEvent: (_, event) {
                          if (event.logicalKey !=
                              LogicalKeyboardKey.arrowLeft) {
                            return KeyEventResult.ignored;
                          }
                          if (event is KeyDownEvent) document.requestFocus();
                          return KeyEventResult.handled;
                        },
                        skipTraversal: true,
                        child: ListView(
                          padding: EdgeInsets.zero,
                          children: [
                            Text(
                              'VeneraX TV',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            Text('v$kDisclaimerVersion · $kDisclaimerDate'),
                            const SizedBox(height: 8),
                            CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              controlAffinity: ListTileControlAffinity.leading,
                              focusNode: checkbox,
                              value: checked,
                              title: Text(
                                'I have read and agree to the User Agreement & Disclaimer.'
                                    .tl,
                              ),
                              onChanged: busy
                                  ? null
                                  : (value) =>
                                        setState(() => checked = value == true),
                            ),
                            FilledButton(
                              onPressed: checked && !busy ? accept : null,
                              child: Text('Agree and Continue'.tl),
                            ),
                            TextButton(
                              onPressed: busy ? null : widget.decline,
                              child: Text('Disagree and exit'.tl),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '↑ ↓ Read   → Options   OK Select'.tl,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
