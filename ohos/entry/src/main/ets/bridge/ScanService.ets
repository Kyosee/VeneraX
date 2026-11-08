import common from '@ohos.app.ability.common';
import { BusinessError } from '@kit.BasicServicesKit';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { Any, FlutterEngine, MethodCall, MethodCallHandler, MethodChannel, MethodResult } from '@ohos/flutter_ohos';

export class ScanService implements MethodCallHandler {
  private channel: MethodChannel;
  private context: common.UIAbilityContext;
  private pending?: MethodResult;
  private disposed = false;

  constructor(context: common.UIAbilityContext, engine: FlutterEngine) {
    this.context = context;
    this.channel = new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), 'venera/scan');
    this.channel.setMethodCallHandler(this);
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (this.disposed) {
      result.error('SCAN_CLOSED', 'Camera unavailable', null);
    } else if (call.method !== 'scan') {
      result.notImplemented();
    } else if (this.pending !== undefined) {
      result.error('SCAN_BUSY', 'Camera unavailable', null);
    } else {
      this.pending = result;
      this.scan(result);
    }
  }

  private async scan(result: MethodResult): Promise<void> {
    try {
      if (!canIUse('SystemCapability.Multimedia.Scan.ScanBarcode')) {
        this.pending = undefined;
        result.error('SCAN_UNAVAILABLE', 'Camera unavailable', null);
        return;
      }
      // The official default UI already owns camera permission.
      const scanned = await scanBarcode.startScanForResult(this.context, {
        scanTypes: [scanCore.ScanType.QR_CODE],
        enableMultiMode: false,
        enableAlbum: true
      });
      if (this.disposed || this.pending !== result) return;
      const value: Any = scanned?.originalValue;
      this.pending = undefined;
      if (typeof value !== 'string' || value.trim().length === 0 || value.length > 16 * 1024) {
        result.error('SCAN_INVALID_RESULT', 'The QR code is damaged or invalid', null);
      } else {
        result.success(value);
      }
    } catch (error) {
      if (this.pending !== result) return;
      this.pending = undefined;
      const failure = error as BusinessError;
      if (failure?.code === 1000500002) {
        result.success(null);
      } else {
        // Native errors may contain scanned data; expose no error details.
        result.error('SCAN_UNAVAILABLE', 'Camera unavailable', null);
      }
    }
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    const result = this.pending;
    this.pending = undefined;
    try {
      this.channel.setMethodCallHandler(null);
    } finally {
      result?.error('SCAN_CLOSED', 'Camera unavailable', null);
    }
    // Scan Kit has no cancel API; ignore late completion after engine teardown.
  }
}
