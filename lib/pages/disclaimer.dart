import 'package:flutter/material.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/disclaimer_content.dart';
import 'package:venera/foundation/onboarding.dart';
import 'package:venera/utils/translations.dart';

/// Shared text, including the emphasis approved in the preview.
class DisclaimerBody extends StatelessWidget {
  const DisclaimerBody({super.key, this.sectionKeys, this.wide = false});
  final List<GlobalKey>? sectionKeys;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var section = 0; section < kDisclaimerSections.length; section++)
          Padding(
            key: sectionKeys?[section],
            padding: EdgeInsets.only(top: section == 0 ? 0 : 9, bottom: 15),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  kDisclaimerSections[section].$1.tl,
                  style: TextStyle(
                    fontSize: wide ? 15 : 14,
                    fontWeight: FontWeight.w600,
                    height: 1.8,
                  ),
                ),
                const SizedBox(height: 12),
                for (
                  var row = 0;
                  row < kDisclaimerSections[section].$2.length;
                  row++
                )
                  Container(
                    margin: const EdgeInsets.only(bottom: 15),
                    padding: section == 6 || (section == 8 && row == 2)
                        ? const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          )
                        : section == 4 && row == 4
                        ? const EdgeInsets.only(left: 14)
                        : EdgeInsets.zero,
                    decoration: section == 6 || (section == 8 && row == 2)
                        ? BoxDecoration(
                            color: colors.primaryContainer,
                            border: Border(
                              left: BorderSide(color: colors.primary, width: 3),
                            ),
                          )
                        : section == 4 && row == 4
                        ? const BoxDecoration(
                            border: Border(
                              left: BorderSide(
                                color: Color(0xffb28d48),
                                width: 3,
                              ),
                            ),
                          )
                        : null,
                    child: Text(
                      kDisclaimerSections[section].$2[row].tl,
                      style: TextStyle(
                        fontSize: wide ? 14 : 13,
                        height: 2.05,
                        fontWeight: section == 6 || (section == 8 && row == 2)
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

String agreementReadingLanguage() {
  final locale = App.locale;
  if (locale.languageCode == 'zh' && locale.countryCode == 'TW') return 'zh-TW';
  if (locale.languageCode == 'zh' && locale.countryCode == 'CN') return 'zh-CN';
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
    final colors = Theme.of(context).colorScheme;
    return IntrinsicWidth(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 146),
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.language, size: 14, color: colors.onSurfaceVariant),
            const SizedBox(width: 5),
            Flexible(
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: appdata.settings['language'],
                  isDense: true,
                  isExpanded: true,
                  borderRadius: BorderRadius.circular(12),
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.onSurfaceVariant,
                  ),
                  icon: Icon(
                    Icons.expand_more,
                    size: 14,
                    color: colors.onSurfaceVariant,
                  ),
                  items: [
                    DropdownMenuItem(
                      value: 'system',
                      child: Text('Follow system'.tl),
                    ),
                    const DropdownMenuItem(value: 'zh-CN', child: Text('简体中文')),
                    const DropdownMenuItem(value: 'zh-TW', child: Text('繁體中文')),
                    const DropdownMenuItem(
                      value: 'en-US',
                      child: Text('English'),
                    ),
                  ],
                  onChanged: !enabled
                      ? null
                      : (value) async {
                          if (value == null) return;
                          appdata.settings['language'] = value;
                          onChanged();
                          App.forceRebuild();
                          await appdata.saveData(false);
                        },
                ),
              ),
            ),
          ],
        ),
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
    this.showLanguagePicker = true,
  });
  final Future<void> Function() onAccepted;
  final VoidCallback onDeclined;
  final bool isUpdate;
  final int previousVersion;
  final bool showLanguagePicker;

  @override
  State<AgreementPanel> createState() => _AgreementPanelState();
}

class _AgreementPanelState extends State<AgreementPanel> {
  bool _checked = false;
  bool _saving = false;
  bool _failed = false;
  final _scroll = ScrollController();
  final _sections = List.generate(
    kDisclaimerSections.length,
    (_) => GlobalKey(),
  );

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
        if (_scroll.hasClients) _scroll.jumpTo(0);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _jump(int section) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 220);
    if (section == 0 && _scroll.hasClients) {
      if (duration == Duration.zero) {
        _scroll.jumpTo(0);
      } else {
        _scroll.animateTo(0, duration: duration, curve: Curves.easeOut);
      }
      return;
    }
    final target = _sections[section].currentContext;
    if (target != null) {
      Scrollable.ensureVisible(target, duration: duration);
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) {
      final colors = Theme.of(context).colorScheme;
      final wide = size.maxWidth >= 600;
      final narrow = size.maxWidth <= 360;
      final inset = widget.isUpdate
          ? 0.0
          : wide
          ? 30.0
          : size.maxWidth <= 360
          ? 18.0
          : 24.0;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              inset,
              widget.isUpdate ? 0 : 3,
              inset,
              widget.isUpdate ? 14 : 8,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: widget.isUpdate && wide
                            ? 440
                            : size.maxWidth - inset * 2,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (widget.isUpdate) ...[
                            Text(
                              (widget.previousVersion > 0
                                      ? 'Please review the updated agreement'
                                      : 'A one-time notice after updating')
                                  .tl,
                              style: TextStyle(
                                color: colors.primary,
                                fontSize: 11,
                                height: 1.6,
                              ),
                            ),
                            const SizedBox(height: 4),
                          ],
                          Text(
                            'User Agreement & Disclaimer'.tl,
                            style: TextStyle(
                              fontSize: widget.isUpdate
                                  ? (wide
                                        ? 22
                                        : narrow
                                        ? 17
                                        : 19)
                                  : (wide ? 24 : 20),
                              fontWeight: FontWeight.w600,
                              height: 1.4,
                              letterSpacing: -.5,
                            ),
                          ),
                          if (widget.isUpdate)
                            Text(
                              'v$kDisclaimerVersion · $kDisclaimerDate',
                              style: TextStyle(
                                fontSize: 10,
                                height: 1.6,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (widget.showLanguagePicker)
                      AgreementLanguagePicker(
                        enabled: !_saving,
                        onChanged: () {
                          if (mounted) setState(() => _checked = false);
                        },
                      ),
                  ],
                ),
                if (!widget.isUpdate) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Please review the risks, liability limits, and data practices.'
                        .tl,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.6,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final item in [
                          (6, 'Risks & liability'),
                          (4, 'Privacy & data'),
                          (8, 'Acceptance & changes'),
                          (0, 'Back to top'),
                        ])
                          Padding(
                            padding: const EdgeInsets.only(right: 13),
                            child: TextButton(
                              onPressed: () => _jump(item.$1),
                              style: TextButton.styleFrom(
                                foregroundColor: colors.primary,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 6,
                                ),
                                minimumSize: const Size(0, 30),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(7),
                                ),
                                textStyle: const TextStyle(
                                  fontSize: 11,
                                  height: 1.5,
                                ),
                              ),
                              child: Text(item.$2.tl),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                inset,
                0,
                inset,
                widget.isUpdate ? 0 : 10,
              ),
              child: Container(
                decoration: widget.isUpdate
                    ? null
                    : BoxDecoration(
                        color: colors.surfaceContainerLowest,
                        border: Border.all(color: colors.outlineVariant),
                        borderRadius: BorderRadius.circular(14),
                      ),
                clipBehavior: widget.isUpdate ? Clip.none : Clip.antiAlias,
                child: Scrollbar(
                  controller: _scroll,
                  child: SingleChildScrollView(
                    controller: _scroll,
                    padding: widget.isUpdate
                        ? EdgeInsets.zero
                        : EdgeInsets.fromLTRB(
                            wide ? 28 : 18,
                            wide ? 24 : 18,
                            wide ? 28 : 18,
                            24,
                          ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_failed)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 14),
                            child: Text(
                              'Unable to save your acceptance. Please check available storage and try again.'
                                  .tl,
                              style: TextStyle(
                                color: colors.error,
                                fontSize: 12,
                                height: 1.8,
                              ),
                            ),
                          ),
                        if (widget.isUpdate) ...[
                          Text(
                            (widget.previousVersion > 0
                                    ? 'The agreement has changed. Please review the changes and full text, then confirm the new version.'
                                    : 'Earlier versions did not show a separate agreement prompt. Please review and confirm this notice.')
                                .tl,
                            style: const TextStyle(fontSize: 13, height: 1.9),
                          ),
                          const SizedBox(height: 15),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 17,
                              vertical: 14,
                            ),
                            decoration: BoxDecoration(
                              color: colors.primaryContainer,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'What to review'.tl,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                for (final change in kDisclaimerChanges)
                                  Text(
                                    '• ${change.tl}',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      height: 2,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(top: 12, bottom: 18),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  Icons.lock_outline,
                                  size: 15,
                                  color: colors.onSurfaceVariant,
                                ),
                                const SizedBox(width: 7),
                                Expanded(
                                  child: Text(
                                    'Your library, reading history, and settings remain intact. Acceptance takes you straight to Home.'
                                        .tl,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: colors.onSurfaceVariant,
                                      height: 1.8,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Divider(height: 1, color: colors.outlineVariant),
                          const SizedBox(height: 20),
                        ],
                        DisclaimerBody(
                          sectionKeys: _sections,
                          wide: wide && !widget.isUpdate,
                        ),
                        Text(
                          'End of terms'.tl,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 10,
                            color: colors.onSurfaceVariant,
                            height: 1.8,
                          ),
                        ),
                        if (!widget.isUpdate)
                          Text(
                            'v$kDisclaimerVersion · $kDisclaimerDate',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 10,
                              color: colors.onSurfaceVariant,
                              height: 1.8,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          Container(
            margin: EdgeInsets.only(top: widget.isUpdate ? 12 : 0),
            padding: EdgeInsets.fromLTRB(
              inset,
              10,
              inset,
              widget.isUpdate ? 0 : 8,
            ),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: colors.outlineVariant)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                InkWell(
                  key: const ValueKey('agreement-consent'),
                  onTap: _saving
                      ? null
                      : () => setState(() => _checked = !_checked),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 21,
                        height: 25,
                        child: Checkbox(
                          value: _checked,
                          onChanged: _saving
                              ? null
                              : (value) =>
                                    setState(() => _checked = value ?? false),
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                          side: BorderSide(color: colors.outlineVariant),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          'I have read and agree to the User Agreement & Disclaimer.'
                              .tl,
                          style: TextStyle(
                            fontSize: narrow ? 10 : 11,
                            height: narrow ? 1.7 : 1.8,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: wide ? 370 : double.infinity,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: OutlinedButton(
                            onPressed: _saving ? null : widget.onDeclined,
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(0, 46),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 10,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(11),
                              ),
                              textStyle: TextStyle(
                                fontSize: narrow ? 11 : 12,
                                height: 1.6,
                              ),
                            ),
                            child: Text(
                              'Disagree and exit'.tl,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          flex: 3,
                          child: FilledButton(
                            key: const ValueKey('agreement-accept'),
                            onPressed: _checked && !_saving ? _accept : null,
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(0, 46),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 10,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(11),
                              ),
                              textStyle: TextStyle(
                                fontSize: narrow ? 11 : 12,
                                height: 1.6,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            child: _saving
                                ? const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Flexible(
                                        child: Text(
                                          (widget.isUpdate
                                                  ? 'Agree and go to Home'
                                                  : 'Agree and Continue')
                                              .tl,
                                          textAlign: TextAlign.center,
                                        ),
                                      ),
                                      const SizedBox(width: 7),
                                      const Icon(Icons.arrow_forward, size: 17),
                                    ],
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 9),
                Text(
                  'Notifications, sync and translation require separate choices.'
                      .tl,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: narrow ? 9 : 10,
                    height: 1.65,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    },
  );
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
