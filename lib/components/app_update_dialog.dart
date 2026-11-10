import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/app_update.dart';
import 'package:venera/foundation/guide_document.dart';
import 'package:venera/utils/translations.dart';

typedef PrepareAppUpdate =
    Future<PreparedAppUpdate> Function(
      CancelToken cancelToken,
      ValueChanged<double?> onProgress,
    );

class PreparedAppUpdate {
  const PreparedAppUpdate({required this.install, required this.discard});

  final AsyncCallback install;
  final AsyncCallback discard;
}

/// Presents release notes while keeping update actions outside the scroll area.
class AppUpdateDialog extends StatefulWidget {
  const AppUpdateDialog({
    super.key,
    required this.currentVersion,
    required this.latestVersion,
    required this.changelog,
    required this.onReleasePage,
    this.prepareUpdate,
    this.restartsAfterInstall = false,
  });

  final String currentVersion;
  final String latestVersion;
  final List<GuideBlock> changelog;
  final AsyncCallback onReleasePage;
  final PrepareAppUpdate? prepareUpdate;
  final bool restartsAfterInstall;

  @override
  State<AppUpdateDialog> createState() => _AppUpdateDialogState();
}

enum _UpdatePhase { available, downloading, ready, failed }

class _AppUpdateDialogState extends State<AppUpdateDialog> {
  final _scrollController = ScrollController();
  _UpdatePhase _phase = _UpdatePhase.available;
  CancelToken? _cancelToken;
  PreparedAppUpdate? _preparedUpdate;
  double? _progress;
  String? _error;

  @override
  void dispose() {
    _cancelToken?.cancel();
    final prepared = _preparedUpdate;
    if (prepared != null) unawaited(prepared.discard());
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _download() async {
    if (_phase == _UpdatePhase.downloading) return;
    final token = CancelToken();
    _cancelToken = token;
    setState(() {
      _phase = _UpdatePhase.downloading;
      _progress = null;
      _error = null;
    });
    try {
      final prepared = await widget.prepareUpdate!(token, (value) {
        if (!mounted || token.isCancelled || _cancelToken != token) return;
        setState(() => _progress = value?.clamp(0, 1));
      });
      if (!mounted || token.isCancelled || _cancelToken != token) {
        await prepared.discard();
        return;
      }
      setState(() {
        _preparedUpdate = prepared;
        _phase = _UpdatePhase.ready;
      });
    } catch (error) {
      if (!mounted || token.isCancelled || _cancelToken != token) return;
      setState(() {
        _phase = _UpdatePhase.failed;
        _error = error is StateError
            ? error.message.toString()
            : 'Check your connection and try again'.tl;
      });
    }
  }

  void _cancelDownload() {
    _cancelToken?.cancel();
    _cancelToken = null;
    setState(() => _phase = _UpdatePhase.available);
  }

  void _close() {
    _cancelToken?.cancel();
    Navigator.of(context).pop();
  }

  Future<void> _openRelease() async {
    _close();
    await widget.onReleasePage();
  }

  Future<void> _primaryAction() async {
    if (widget.prepareUpdate == null) {
      await _openRelease();
    } else if (_phase == _UpdatePhase.ready) {
      final prepared = _preparedUpdate!;
      // Transfer ownership before the closing route is disposed.
      _preparedUpdate = null;
      _close();
      await prepared.install();
    } else {
      await _download();
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final colors = _UpdateColors(dark);
    final desktop = MediaQuery.sizeOf(context).width >= 600;
    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 3, sigmaY: 3),
      child: Dialog(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 12,
        shadowColor: const Color(0x300c1e44),
        insetPadding: const EdgeInsets.symmetric(horizontal: 17, vertical: 24),
        constraints: const BoxConstraints(maxWidth: 430, maxHeight: 680),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(27),
          side: const BorderSide(color: Color(0x18ffffff)),
        ),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact =
                constraints.maxWidth < 330 || constraints.maxHeight < 500;
            final padding = compact ? 18.0 : (desktop ? 28.0 : 23.0);
            return DefaultTextStyle.merge(
              style: TextStyle(color: colors.ink, fontSize: 12, height: 1.85),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      padding,
                      compact ? 18 : (desktop ? 25 : 22),
                      padding,
                      compact ? 14 : (desktop ? 18 : 17),
                    ),
                    child: _header(colors, compact, desktop),
                  ),
                  Flexible(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: padding),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border(top: BorderSide(color: colors.line)),
                        ),
                        child: Scrollbar(
                          controller: _scrollController,
                          child: SingleChildScrollView(
                            key: const ValueKey('update-notes-scroll'),
                            controller: _scrollController,
                            padding: const EdgeInsets.only(top: 3, bottom: 13),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (final block in widget.changelog)
                                  _changelogBlock(block, colors),
                                if (widget.changelog.isEmpty)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 13,
                                    ),
                                    child: Text(
                                      'Release notes are unavailable'.tl,
                                      style: TextStyle(color: colors.muted),
                                    ),
                                  ),
                                TextButton.icon(
                                  onPressed: _openRelease,
                                  style: TextButton.styleFrom(
                                    foregroundColor: colors.accent,
                                    minimumSize: const Size(0, 44),
                                    padding: EdgeInsets.zero,
                                    textStyle: Theme.of(context)
                                        .textTheme
                                        .labelLarge
                                        ?.copyWith(fontSize: 11),
                                  ),
                                  iconAlignment: IconAlignment.end,
                                  icon: const Icon(
                                    Icons.open_in_new_rounded,
                                    size: 13,
                                  ),
                                  label: Text('View this release on GitHub'.tl),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Container(
                    key: const ValueKey('update-actions'),
                    decoration: BoxDecoration(
                      border: Border(top: BorderSide(color: colors.line)),
                    ),
                    padding: EdgeInsets.fromLTRB(
                      padding,
                      _phase == _UpdatePhase.downloading
                          ? 18
                          : (desktop ? 17 : 13),
                      padding,
                      compact ? 18 : (desktop ? 22 : 20),
                    ),
                    child: _footer(colors),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _header(_UpdateColors colors, bool compact, bool desktop) {
    String version(String value) =>
        value.startsWith(RegExp('[vV]')) ? value : 'v$value';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              key: const ValueKey('update-app-icon'),
              width: compact ? 48 : 60,
              height: compact ? 48 : 60,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: colors.accentSoft,
                borderRadius: BorderRadius.circular(compact ? 14 : 17),
              ),
              child: Image.asset(
                'assets/app_icon.png',
                excludeFromSemantics: true,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Semantics(
                namesRoute: true,
                header: true,
                child: Text(
                  'New version available'.tl,
                  key: const ValueKey('update-title'),
                  style: TextStyle(
                    fontSize: compact ? 20 : (desktop ? 27 : 25),
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.8,
                  ),
                ),
              ),
            ),
            Transform.translate(
              offset: const Offset(8, 0),
              child: IconButton(
                onPressed: _close,
                tooltip: 'Close'.tl,
                iconSize: 17,
                color: colors.muted,
                constraints: const BoxConstraints.tightFor(
                  width: 44,
                  height: 44,
                ),
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.close_rounded),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    '${'Current'.tl} ${version(widget.currentVersion)}',
                    style: TextStyle(color: colors.muted, height: 1.2),
                  ),
                  Icon(
                    Icons.arrow_forward_rounded,
                    size: 13,
                    color: colors.muted,
                  ),
                  _badge(version(widget.latestVersion), colors),
                ],
              ),
              _badge('Stable'.tl, colors, dot: true),
            ],
          ),
        ),
      ],
    );
  }

  Widget _badge(String text, _UpdateColors colors, {bool dot = false}) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dot ? 8 : 7,
        vertical: dot ? 5 : 3,
      ),
      decoration: BoxDecoration(
        color: colors.accentSoft,
        borderRadius: BorderRadius.circular(dot ? 6 : 5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            Icon(Icons.circle, size: 4, color: colors.accent),
            const SizedBox(width: 5),
          ],
          Flexible(
            child: Text(
              text,
              style: TextStyle(
                color: colors.accent,
                fontSize: dot ? 10 : 11,
                fontWeight: dot ? FontWeight.w500 : FontWeight.w600,
                height: 1.2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _changelogBlock(GuideBlock block, _UpdateColors colors) {
    final heading = isChangelogHeading(block);
    final bullet = block.type == GuideBlockType.bullet;
    final numbered = block.type == GuideBlockType.numbered;
    final spans = [
      ...block.spans,
      if (block.trailingSpans.isNotEmpty) ...[
        const GuideSpan(' — ', GuideSpanStyle.plain),
        ...block.trailingSpans,
      ],
    ];
    Widget text = Text.rich(
      TextSpan(
        children: [
          for (final span in spans)
            TextSpan(
              text: span.text,
              style: TextStyle(
                fontWeight: heading || span.style == GuideSpanStyle.bold
                    ? FontWeight.w600
                    : FontWeight.w400,
                fontFamily:
                    span.style == GuideSpanStyle.code ||
                        block.type == GuideBlockType.codeBlock
                    ? 'monospace'
                    : null,
              ),
            ),
        ],
      ),
      style: TextStyle(color: heading ? colors.ink : colors.muted),
    );
    if (heading) text = Semantics(header: true, child: text);
    return Padding(
      padding: EdgeInsets.only(
        top: heading ? 13 : 0,
        bottom: heading ? 6 : 7,
        left: (bullet || numbered) ? block.indent.clamp(0, 3) * 10.0 : 0,
      ),
      child: bullet || numbered
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: numbered ? 24 : 18,
                  child: Text(
                    numbered ? '${block.number}.' : '•',
                    style: TextStyle(color: colors.muted),
                  ),
                ),
                Expanded(child: text),
              ],
            )
          : text,
    );
  }

  Widget _footer(_UpdateColors colors) {
    final downloading = _phase == _UpdatePhase.downloading;
    final ready = _phase == _UpdatePhase.ready;
    final failed = _phase == _UpdatePhase.failed;
    final external = widget.prepareUpdate == null;
    final secondary = downloading
        ? 'Cancel download'
        : (ready ? 'Install later' : 'Not now');
    final primary = external
        ? 'Go to release page'
        : (ready
              ? 'Install update'
              : (failed ? 'Download again' : 'Update Now'));
    Widget action(String label, VoidCallback callback, {bool filled = false}) {
      return FilledButton(
        key: ValueKey(filled ? 'update-primary' : 'update-secondary'),
        onPressed: callback,
        style: FilledButton.styleFrom(
          backgroundColor: filled ? colors.accent : colors.surfaceSoft,
          foregroundColor: filled ? colors.buttonInk : colors.muted,
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            height: 1.4,
            letterSpacing: 0,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (filled) ...[
              Icon(
                external
                    ? Icons.open_in_new_rounded
                    : (ready
                          ? Icons.check_circle_outline_rounded
                          : (failed
                                ? Icons.refresh_rounded
                                : Icons.file_download_outlined)),
                size: 16,
              ),
              const SizedBox(width: 7),
            ],
            Flexible(child: Text(label.tl, textAlign: TextAlign.center)),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (downloading) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  'Downloading update'.tl,
                  style: const TextStyle(fontSize: 11),
                ),
              ),
              if (_progress != null)
                Text(
                  '${(_progress! * 100).round()}%',
                  style: TextStyle(fontSize: 11, color: colors.accent),
                ),
            ],
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: _progress,
            minHeight: 5,
            color: colors.accent,
            backgroundColor: colors.accentSoft,
            borderRadius: BorderRadius.circular(9),
            semanticsLabel: 'Downloading update'.tl,
          ),
          const SizedBox(height: 15),
        ],
        if (ready || failed)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Semantics(
              liveRegion: true,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    ready
                        ? Icons.check_circle_outline_rounded
                        : Icons.error_outline_rounded,
                    color: ready ? colors.accent : const Color(0xffca6371),
                    size: 18,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          (ready
                                  ? 'Your update is ready'
                                  : 'Download interrupted')
                              .tl,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          ready
                              ? (widget.restartsAfterInstall
                                        ? 'The app will close to install, then restart'
                                        : 'The system installer will open next')
                                    .tl
                              : _error!,
                          style: TextStyle(color: colors.muted, fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        Row(
          children: [
            Expanded(
              flex: 100,
              child: action(secondary, downloading ? _cancelDownload : _close),
            ),
            if (!downloading) ...[
              const SizedBox(width: 9),
              Expanded(
                flex: 165,
                child: action(primary, _primaryAction, filled: true),
              ),
            ],
          ],
        ),
        if (external)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              'Get the version for your device on the release page'.tl,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.muted, fontSize: 10, height: 1.6),
            ),
          ),
      ],
    );
  }
}

/// Colors from the approved light and dark previews; the app supplies the font.
class _UpdateColors {
  _UpdateColors(bool dark)
    : surface = Color(dark ? 0xff202530 : 0xffffffff),
      surfaceSoft = Color(dark ? 0xff292f3d : 0xfff5f7fc),
      ink = Color(dark ? 0xffeef1f8 : 0xff202a3b),
      muted = Color(dark ? 0xffa3aec1 : 0xff657286),
      line = Color(dark ? 0xff353d4c : 0xffedf0f5),
      accent = Color(dark ? 0xffa9bcff : 0xff4265db),
      accentSoft = Color(dark ? 0xff2f3c5d : 0xffedf2ff),
      buttonInk = Color(dark ? 0xff1b2b56 : 0xffffffff);

  final Color surface,
      surfaceSoft,
      ink,
      muted,
      line,
      accent,
      accentSoft,
      buttonInk;
}
