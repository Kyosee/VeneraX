import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/disclaimer_content.dart';
import 'package:venera/pages/main_page.dart';
import 'package:venera/utils/translations.dart';


/// Renders the disclaimer body as titled sections of paragraphs.
class DisclaimerBody extends StatelessWidget {
  const DisclaimerBody({super.key});

  @override
  Widget build(BuildContext context) {
    var children = <Widget>[];
    for (var (title, paragraphs) in kDisclaimerSections) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            title.tl,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              height: 1.5,
            ),
          ),
        ),
      );
      for (var paragraph in paragraphs) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              paragraph.tl,
              style: const TextStyle(fontSize: 14, height: 1.5),
            ),
          ),
        );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}

/// Shows the disclaimer in a scrollable read-only dialog.
void showDisclaimerDialog(BuildContext context) {
  showDialog(
    context: context,
    builder: (context) {
      return ContentDialog(
        title: "User Agreement & Disclaimer".tl,
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: SingleChildScrollView(
            child: const DisclaimerBody().paddingHorizontal(16).paddingVertical(4),
          ),
        ),
        actions: [
          Button.filled(
            onPressed: () => Navigator.pop(context),
            child: Text("OK".tl),
          ),
        ],
      );
    },
  );
}

/// Full-screen consent gate. Shown before the main UI when the consent flow is
/// enabled and consent has not yet been recorded. The user must tick the
/// checkbox to enable the accept button.
class DisclaimerConsentPage extends StatefulWidget {
  const DisclaimerConsentPage({super.key});

  @override
  State<DisclaimerConsentPage> createState() => _DisclaimerConsentPageState();
}

class _DisclaimerConsentPageState extends State<DisclaimerConsentPage> {
  bool _checked = false;

  void _accept() {
    appdata.settings['disclaimerConsented'] = true;
    appdata.saveData(false);
    App.rootContext.toReplacement(() => const MainPage());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              Text(
                "User Agreement & Disclaimer".tl,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: Scrollbar(
                  child: SingleChildScrollView(
                    child: const DisclaimerBody(),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              InkWell(
                onTap: () => setState(() => _checked = !_checked),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Checkbox(
                        value: _checked,
                        onChanged: (v) => setState(() => _checked = v ?? false),
                      ),
                      Expanded(
                        child: Text("I have read and agree to the disclaimer above".tl),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Opacity(
                opacity: _checked ? 1 : 0.5,
                child: Button.filled(
                  onPressed: () {
                    if (_checked) _accept();
                  },
                  child: Text("Agree and Continue".tl),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
