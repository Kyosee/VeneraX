import 'package:flutter/material.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/disclaimer_content.dart';
import 'package:venera/foundation/onboarding.dart';
import 'package:venera/utils/translations.dart';

/// Renders the shared agreement used by startup and Settings.
class DisclaimerBody extends StatelessWidget {
  const DisclaimerBody({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (
          var section = 0;
          section < kDisclaimerSections.length;
          section++
        ) ...[
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 10),
            child: Text(
              kDisclaimerSections[section].$1.tl,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                height: 1.6,
              ),
            ),
          ),
          for (var row = 0; row < kDisclaimerSections[section].$2.length; row++)
            Container(
              margin: const EdgeInsets.only(bottom: 14),
              padding: section == 6 || (section == 8 && row == 2)
                  ? const EdgeInsets.all(14)
                  : EdgeInsets.zero,
              decoration: section == 6 || (section == 8 && row == 2)
                  ? BoxDecoration(
                      color: colors.primaryContainer.withValues(alpha: .35),
                      border: Border(
                        left: BorderSide(color: colors.primary, width: 3),
                      ),
                    )
                  : null,
              child: Text(
                kDisclaimerSections[section].$2[row].tl,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.85,
                  fontWeight: section == 6 || (section == 8 && row == 2)
                      ? FontWeight.w600
                      : FontWeight.normal,
                ),
              ),
            ),
        ],
      ],
    );
  }
}

String agreementReadingLanguage() {
  final locale = App.locale;
  if (locale.languageCode == 'zh' && locale.countryCode == 'TW') {
    return 'zh-TW';
  }
  if (locale.languageCode == 'zh' && locale.countryCode == 'CN') {
    return 'zh-CN';
  }
  return 'en-US';
}

class AgreementLanguagePicker extends StatelessWidget {
  const AgreementLanguagePicker({
    super.key,
    required this.onChanged,
    this.enabled = true,
  });
  final VoidCallback onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: appdata.settings['language'],
        borderRadius: BorderRadius.circular(16),
        icon: const Icon(Icons.expand_more, size: 18),
        items: [
          DropdownMenuItem(value: 'system', child: Text('Follow system'.tl)),
          const DropdownMenuItem(value: 'zh-CN', child: Text('简体中文')),
          const DropdownMenuItem(value: 'zh-TW', child: Text('繁體中文')),
          const DropdownMenuItem(value: 'en-US', child: Text('English')),
        ],
        onChanged: !enabled
            ? null
            : (value) async {
                if (value == null) return;
                appdata.settings['language'] = value;
                await appdata.saveData(false);
                App.forceRebuild();
                onChanged();
              },
      ),
    );
  }
}

class AgreementPanel extends StatefulWidget {
  const AgreementPanel({
    super.key,
    required this.onAccepted,
    required this.onDeclined,
    this.isUpdate = false,
    this.previousVersion = 0,
  });
  final Future<void> Function() onAccepted;
  final VoidCallback onDeclined;
  final bool isUpdate;
  final int previousVersion;

  @override
  State<AgreementPanel> createState() => _AgreementPanelState();
}

class _AgreementPanelState extends State<AgreementPanel> {
  bool _checked = false;
  bool _saving = false;
  bool _failed = false;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _accept() async {
    if (!_checked || _saving) return;
    setState(() {
      _saving = true;
      _failed = false;
    });
    try {
      await widget.onAccepted();
    } catch (_) {
      if (mounted) {
        setState(() => _failed = true);
        _scroll.jumpTo(0);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 18,
          runSpacing: 4,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.isUpdate)
                    Text(
                      (widget.previousVersion > 0
                              ? 'Please review the updated agreement'
                              : 'A one-time notice after updating')
                          .tl,
                      style: TextStyle(color: colors.primary, fontSize: 12),
                    ),
                  Text(
                    'User Agreement & Disclaimer'.tl,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'v$kDisclaimerVersion · $kDisclaimerDate',
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            AgreementLanguagePicker(
              enabled: !_saving,
              onChanged: () {
                if (mounted) setState(() => _checked = false);
              },
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: colors.outlineVariant),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Scrollbar(
              controller: _scroll,
              child: SingleChildScrollView(
                controller: _scroll,
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_failed)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'Unable to save your acceptance. Please check available storage and try again.'
                              .tl,
                          style: TextStyle(color: colors.error),
                        ),
                      ),
                    Text(
                      'Notifications, sync, and translation are separate choices and are not enabled by accepting this agreement.'
                          .tl,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.5,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 14),
                    if (widget.isUpdate) ...[
                      Text(
                        (widget.previousVersion > 0
                                ? 'The agreement has changed. Please review the changes and full text, then confirm the new version.'
                                : 'Earlier versions did not show a separate agreement prompt. Please review and confirm this notice.')
                            .tl,
                        style: const TextStyle(height: 1.7),
                      ),
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: colors.primaryContainer.withValues(alpha: .35),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'What to review'.tl,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            for (final change in kDisclaimerChanges)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                  '• ${change.tl}',
                                  style: const TextStyle(height: 1.6),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Your library, reading history, and settings remain intact. Acceptance takes you straight to Home.'
                            .tl,
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.onSurfaceVariant,
                          height: 1.7,
                        ),
                      ),
                      const Divider(height: 28),
                    ],
                    const DisclaimerBody(),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        CheckboxListTile(
          key: const ValueKey('agreement-consent'),
          value: _checked,
          onChanged: _saving
              ? null
              : (v) => setState(() => _checked = v ?? false),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(
            'I have read and agree to the legally valid and applicable terms, and acknowledge the risk notices and liability limits.'
                .tl,
            style: const TextStyle(fontSize: 12, height: 1.6),
          ),
        ),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  textStyle: const TextStyle(fontSize: 12, height: 1.5),
                ),
                onPressed: _saving ? null : widget.onDeclined,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Text(
                    'Disagree and exit'.tl,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  textStyle: const TextStyle(fontSize: 12, height: 1.5),
                ),
                key: const ValueKey('agreement-accept'),
                onPressed: _checked && !_saving ? _accept : null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: _saving
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          (widget.isUpdate
                                  ? 'Agree and go to Home'
                                  : 'Agree and Continue')
                              .tl,
                          textAlign: TextAlign.center,
                        ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// Reading this dialog does not change the saved acceptance record.
void showDisclaimerDialog(BuildContext context) {
  final state = OnboardingStore.instance.state;
  showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 760),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                kDisclaimerTitle.tl,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Text('v$kDisclaimerVersion · $kDisclaimerDate'),
              if (state.acceptedAt != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Accepted on this device: v@version · @date'.tlParams({
                      'version': state.acceptedVersion,
                      'date': DateTime.parse(
                        state.acceptedAt!,
                      ).toLocal().toString().split('.').first,
                    }),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              const SizedBox(height: 12),
              const Expanded(
                child: SingleChildScrollView(child: DisclaimerBody()),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text('OK'.tl),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
