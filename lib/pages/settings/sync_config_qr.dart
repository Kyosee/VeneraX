import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart' show App;
import 'package:venera/foundation/context.dart';
import 'package:venera/foundation/widget_utils.dart';
import 'package:venera/utils/sync_config_transfer.dart';
import 'package:venera/utils/translations.dart';

/// UI for transferring WebDAV sync configuration between devices via a
/// PIN-encrypted QR code. The pure encode/decode + crypto lives in
/// `utils/sync_config_transfer.dart`; this file is only presentation.

/// Renders [payload] as a QR code locked behind a freshly-generated one-time
/// PIN, shown alongside the PIN and a plain-text-password warning. Works on
/// every platform (the "generate" side, including desktop).
Future<void> showSyncConfigQrDialog(
  BuildContext context,
  SyncConfigPayload payload,
) {
  return showDialog(
    context: context,
    builder: (ctx) => _SyncConfigQrDialog(payload: payload),
  );
}

class _SyncConfigQrDialog extends StatefulWidget {
  const _SyncConfigQrDialog({required this.payload});

  final SyncConfigPayload payload;

  @override
  State<_SyncConfigQrDialog> createState() => _SyncConfigQrDialogState();
}

class _SyncConfigQrDialogState extends State<_SyncConfigQrDialog> {
  String? _pin;
  String? _uri;

  @override
  void initState() {
    super.initState();
    // Encoding runs a 200k-round PBKDF2 (~hundreds of ms on mobile). Doing it
    // before showDialog froze the UI; instead show the dialog immediately with
    // a spinner and derive the QR one frame later so the spinner paints first.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final pin = generateSyncPin();
      final uri = await Future(() => encodeSyncConfigToUri(widget.payload, pin));
      if (!mounted) return;
      setState(() {
        _pin = pin;
        _uri = uri;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final uri = _uri;
    final pin = _pin;
    return ContentDialog(
      title: "Sync Config QR".tl,
      // Explicit width: ContentDialog wraps content in IntrinsicWidth, and
      // QrImageView uses a LayoutBuilder internally which has no intrinsic
      // width — measuring it crashes on desktop ("render box with no size").
      // A fixed-width box short-circuits the intrinsic-width pass.
      content: SizedBox(
        width: 280,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // QR card. Fixed both dimensions so neither intrinsic-width nor
            // intrinsic-height measurement (ContentDialog's IntrinsicWidth)
            // descends into QrImageView's LayoutBuilder, which throws on
            // intrinsic queries.
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.12),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: SizedBox(
                width: 220,
                height: 220,
                child: uri == null
                    ? const Center(child: CircularProgressIndicator())
                    : QrImageView(
                        data: uri,
                        version: QrVersions.auto,
                        size: 220,
                        backgroundColor: Colors.white,
                        eyeStyle: const QrEyeStyle(
                          eyeShape: QrEyeShape.circle,
                          color: Colors.black,
                        ),
                        dataModuleStyle: const QrDataModuleStyle(
                          dataModuleShape: QrDataModuleShape.circle,
                          color: Colors.black,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 20),
            // PIN chip.
            Text(
              "PIN".tl,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: context.colorScheme.outline,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              decoration: BoxDecoration(
                color: context.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                pin == null ? '— — — — — —' : _spacedPin(pin),
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 4,
                  color: context.colorScheme.onPrimaryContainer,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(height: 20),
            // Warning row.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 18,
                  color: context.colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "Contains your password in plain text. Do not screenshot or share it; the other device needs this PIN to restore the config."
                        .tl,
                    style: TextStyle(
                      fontSize: 12,
                      color: context.colorScheme.error,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        Button.filled(
          onPressed: () => Navigator.of(context).pop(),
          child: Text("Done".tl),
        ),
      ],
    );
  }
}

/// Opens the camera scanner, then prompts for the PIN and decrypts. Returns the
/// recovered [SyncConfigPayload], or null if the user cancelled or any step
/// failed (a precise message is shown to the user on failure). Mobile only —
/// callers should hide the entry point on desktop.
Future<SyncConfigPayload?> scanAndDecodeSyncConfig(BuildContext context) async {
  final String? raw;
  if (App.isOhos) {
    Object? scanned;
    try {
      scanned = await const MethodChannel(
        'venera/scan',
      ).invokeMethod<Object?>('scan');
    } catch (error) {
      if (context.mounted) {
        context.showMessage(
          message:
              error is PlatformException && error.code == 'SCAN_INVALID_RESULT'
              ? _errorMessage(SyncConfigTransferError.malformed)
              : 'Camera unavailable'.tl,
        );
      }
      return null;
    }
    if (scanned == null || !context.mounted) return null;
    if (scanned is! String ||
        scanned.trim().isEmpty ||
        scanned.length > 16 * 1024) {
      context.showMessage(
        message: _errorMessage(SyncConfigTransferError.malformed),
      );
      return null;
    }
    raw = scanned;
  } else {
    raw = await Navigator.of(context, rootNavigator: true).push<String>(
      MaterialPageRoute(builder: (_) => const _SyncConfigScanPage()),
    );
  }
  if (raw == null || !context.mounted) return null;
  final String scannedUri = raw;
  if (!isSyncConfigUri(scannedUri)) {
    context.showMessage(
      message: _errorMessage(SyncConfigTransferError.notSyncConfig),
    );
    return null;
  }

  final pin = await _promptPin(context);
  if (pin == null || pin.isEmpty || !context.mounted) return null;

  final loading = showLoadingDialog(context, barrierDismissible: false);
  SyncConfigPayload? payload;
  SyncConfigTransferError? errorKind;
  try {
    // Defer one microtask so the loading spinner paints before the
    // (CPU-bound) PBKDF2 key derivation runs on this isolate.
    payload = await Future(() => decodeSyncConfigFromUri(scannedUri, pin));
  } on SyncConfigTransferException catch (e) {
    errorKind = e.kind;
  } catch (_) {
    errorKind = SyncConfigTransferError.malformed;
  } finally {
    loading.close();
  }

  if (!context.mounted) return null;
  if (errorKind != null) {
    context.showMessage(message: _errorMessage(errorKind));
    return null;
  }
  return payload;
}

Future<String?> _promptPin(BuildContext context) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) {
      return ContentDialog(
        title: "Enter PIN".tl,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Enter the 6-digit PIN shown on the other device".tl,
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                counterText: '',
              ),
              style: const TextStyle(fontSize: 24, letterSpacing: 6),
              textAlign: TextAlign.center,
              onSubmitted: (v) {
                if (v.trim().isNotEmpty) Navigator.of(ctx).pop(v.trim());
              },
            ),
          ],
        ).paddingHorizontal(16),
        actions: [
          Button.text(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text("Cancel".tl),
          ),
          Button.filled(
            onPressed: () {
              final v = controller.text.trim();
              if (v.isEmpty) return;
              Navigator.of(ctx).pop(v);
            },
            child: Text("Confirm".tl),
          ),
        ],
      );
    },
  );
}

String _errorMessage(SyncConfigTransferError kind) {
  switch (kind) {
    case SyncConfigTransferError.notSyncConfig:
      return "Not a sync config QR code".tl;
    case SyncConfigTransferError.unsupportedVersion:
      return "This QR code needs a newer app version".tl;
    case SyncConfigTransferError.malformed:
      return "The QR code is damaged or invalid".tl;
    case SyncConfigTransferError.wrongPinOrTampered:
      return "Wrong PIN, or the QR code was altered".tl;
  }
}

String _spacedPin(String pin) => pin.split('').join(' ');

class _SyncConfigScanPage extends StatefulWidget {
  const _SyncConfigScanPage();

  @override
  State<_SyncConfigScanPage> createState() => _SyncConfigScanPageState();
}

class _SyncConfigScanPageState extends State<_SyncConfigScanPage> {
  bool _handled = false;

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw != null && isSyncConfigUri(raw)) {
        _handled = true;
        Navigator.of(context).pop(raw);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Scan Sync QR".tl)),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            onDetect: _onDetect,
            errorBuilder: (context, error, child) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    "${"Camera unavailable".tl}\n${error.errorDetails?.message ?? ''}",
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            },
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              margin: const EdgeInsets.only(bottom: 48),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                "Point the camera at the sync QR code on the other device".tl,
                style: const TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
