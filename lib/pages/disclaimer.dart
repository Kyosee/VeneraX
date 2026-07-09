import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/pages/main_page.dart';
import 'package:venera/utils/translations.dart';

/// Ordered list of disclaimer paragraphs. Each entry is a translation key
/// resolved via `.tl`; English falls back to the key text itself.
const List<String> kDisclaimerParagraphs = [
  "The software in this repository is provided \"AS IS\", without warranty of any kind, express or implied. The maintainers do not guarantee its accuracy, completeness, or fitness for any particular purpose; use it at your own risk.",
  "This project is for personal learning and research only, and its feature development and maintenance are AI-driven. This repository maintains only the comic reader application itself; it does not contain, provide, bundle, host, or distribute any comic source or source-site content, nor does it recommend or endorse any comic source. For any third-party content that users access, obtain, or process through or by modifying this software, the project makes no guarantee as to its legality, accuracy, or completeness and assumes no liability for it. Users are solely responsible for their own use and must comply with all applicable laws and regulations in their jurisdiction.",
  "The software's online reading capability is implemented as a JavaScript-extension-compatible API; whether and which comic source extensions are loaded is entirely up to the user to configure lawfully and at their own responsibility. Search results, chapter loading, image availability, and content copyright all depend on the implementation of the respective source sites and extensions, and are unrelated to this project.",
  "All data is by default stored only on the user's local device; WebDAV sync is an optional feature, and data is transmitted only to a server configured by the user. This project operates no server of its own and does not collect or upload any user data.",
  "You must not use this project for any illegal activity, to distribute malware or viruses, or to interfere with the normal operation or lawful rights and interests of any company or individual. This is a non-profit, open-source project; using it for profit is prohibited, and any third-party profiteering is unrelated to this project.",
  "Do not promote or advertise this project on any public or official platforms or official account areas (including but not limited to Weibo, WeChat Official Accounts, X, etc.).",
  "Matters concerning comic source configuration, source-site content, the availability of specific works, or copyright ownership are outside the scope of this project's maintenance; please do not submit related issues to this repository.",
  "By downloading, copying, modifying, or using this project, you are deemed to have read and accepted this disclaimer. The maintainers reserve the right to modify or supplement this disclaimer at any time.",
];

/// Renders the disclaimer body as a column of paragraphs.
class DisclaimerBody extends StatelessWidget {
  const DisclaimerBody({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < kDisclaimerParagraphs.length; i++)
          Padding(
            padding: EdgeInsets.only(
              bottom: i == kDisclaimerParagraphs.length - 1 ? 0 : 12,
            ),
            child: Text(
              kDisclaimerParagraphs[i].tl,
              style: const TextStyle(fontSize: 14, height: 1.5),
            ),
          ),
      ],
    );
  }
}

/// Shows the disclaimer in a scrollable read-only dialog.
void showDisclaimerDialog(BuildContext context) {
  showDialog(
    context: context,
    builder: (context) {
      return ContentDialog(
        title: "Disclaimer".tl,
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
                "Disclaimer".tl,
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
