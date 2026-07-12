import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/pages/main_page.dart';
import 'package:venera/utils/translations.dart';

/// Disclaimer content as ordered sections of (title, paragraphs). Titles and
/// paragraphs are translation keys resolved via `.tl`; English falls back to
/// the key text itself.
const List<(String, List<String>)> kDisclaimerSections = [
  (
    "1. Nature of the Software",
    [
      "This software is a user-configurable, local content reading tool that only provides technical capabilities such as network access, content parsing, reading layout, and local data management. The code is provided \"AS IS\", without warranty of any kind, express or implied; the maintainers do not guarantee its accuracy, completeness, or fitness for any particular purpose, and you use it at your own risk.",
      "By default, this software does not pre-configure, bundle, or provide any third-party website content, data resources, or parsing extensions; the maintainers do not provide any content operation, storage, publishing, or distribution services, nor do they recommend or endorse any third-party content.",
      "This project is for personal learning and research only, and its feature development and maintenance are AI-driven. It is a non-profit open-source project: the maintainers conduct no commercial operations and have not authorized any individual or organization to carry out paid distribution, resale, paid installation, traffic diversion, paid communities, or any other commercial activity in this project's name; any third-party commercial activity is unrelated to this project and undertaken at that party's own risk. The project may be suspended, changed, or discontinued at any time without notice.",
    ],
  ),
  (
    "2. Extensions and User Conduct",
    [
      "The software's online reading capability is implemented as a JavaScript-extension-compatible API. Users may create and edit extension scripts themselves, or import extension scripts shared by third parties; whether and which extensions are loaded is entirely up to the user to configure lawfully, and the user shall independently judge and bear full responsibility for their origin, legality, accuracy, and applicability.",
      "When a user accesses third-party websites through extensions, the network requests are initiated directly from the user's device to the target websites. This software only provides local parsing, layout, and display capabilities, and does not publicly disseminate or redistribute any third-party content. Search results, chapter loading, image availability, and content copyright all depend on the respective websites and extensions, and are unrelated to this project.",
      "Users must comply with the laws and regulations of their jurisdiction, network security requirements, and the terms of service and copyright policies of the relevant websites. Users must not use this software to infringe intellectual property rights, obtain data without authorization, distribute unlawful content or malware, disrupt any network service, or harm the lawful rights and interests of any company or individual.",
    ],
  ),
  (
    "3. Third-Party Platforms and Communities",
    [
      "Any extension-sharing platform, website, forum, or chat group established or maintained by third parties is an independently operated third party with no affiliation to this project. This project does not participate in the creation, publication, operation, maintenance, or distribution of such third-party extensions or communities, and assumes no obligation of proactive review; all risks and liabilities arising from using third-party extensions or accessing third-party websites shall be borne by the responsible parties in accordance with the law.",
      "This project has not established and does not operate any official community, group, or public account, nor has it authorized any third party to advertise, promote, or publish in its name.",
    ],
  ),
  (
    "4. Privacy and Data",
    [
      "All features of this software run on the user's local device. This project operates no server, does not collect or upload any user data (including reading content, extension lists, or browsing history), and integrates no analytics, crash-reporting, or telemetry components.",
      "Network and storage permissions are used only to implement the software's features such as online reading, local backup import/export, WebDAV sync, and app update checks, and for no other purpose; WebDAV sync transmits data only to a server configured by the user, and the maintainers cannot access, obtain, or control that server or any data stored on it.",
    ],
  ),
  (
    "5. Intellectual Property",
    [
      "This project respects intellectual property rights. If a rights holder believes that the code or files directly contained in this repository infringe their lawful rights, they may submit a valid notice with identity proof, ownership proof, and specific details to the maintainers, who will handle it within their reasonable technical capabilities.",
      "This project neither hosts nor controls any third-party extension or the third-party content parsed or presented by extensions, and is therefore unable to take removal, blocking, or other measures against them; rights holders should assert their rights against the publisher of the relevant extension or the party actually hosting the content.",
      "This project does not accept issues or technical-support requests concerning third-party website content, extension configuration, the availability of specific works, or copyright ownership.",
    ],
  ),
  (
    "6. Limitation of Liability",
    [
      "To the maximum extent permitted by applicable law, this project and its maintainers shall not be liable for any direct, indirect, incidental, special, punitive, or consequential losses arising from the use of or inability to use this software, or from third-party extensions, third-party websites, network conditions, data loss, device failure, account issues, copyright disputes, or similar causes. Users shall evaluate and bear all risks of using this software.",
      "This project does not guarantee compatibility with any third-party website, extension, or service, nor the continued availability of any feature.",
    ],
  ),
  (
    "7. Miscellaneous",
    [
      "Do not promote or advertise this project on any public or official platforms or official account areas (including but not limited to Weibo, WeChat Official Accounts, X, etc.).",
      "This software is licensed and distributed under the license set out in the LICENSE file at the root of the repository; this disclaimer does not modify or limit the rights granted by that license, and the license prevails in case of conflict.",
      "By downloading, copying, modifying, or using this project, you are deemed to have read and accepted this disclaimer in its entirety. The maintainers reserve the right to modify or supplement this disclaimer at any time, effective upon publication.",
    ],
  ),
];

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
