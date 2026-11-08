import { userAuth } from '@kit.UserAuthenticationKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Any, FlutterEngine, MethodCall, MethodCallHandler, MethodChannel, MethodResult } from '@ohos/flutter_ohos';

export class AuthService implements MethodCallHandler {
  private channel: MethodChannel;
  private active?: userAuth.UserAuthInstance;
  private pending?: MethodResult;
  private disposed = false;

  constructor(engine: FlutterEngine) {
    this.channel = new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), 'plugins.flutter.io/local_auth');
    this.channel.setMethodCallHandler(this);
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (this.disposed) {
      result.error('AUTH_CLOSED', 'Authentication service is closed.', null);
      return;
    }
    try {
      switch (call.method) {
        case 'getAvailableBiometrics':
          const types: string[] = [];
          if (this.available(userAuth.UserAuthType.FACE)) types.push('face');
          if (this.available(userAuth.UserAuthType.FINGERPRINT)) types.push('fingerprint');
          result.success(types);
          break;
        case 'isDeviceSupported':
          result.success(this.authTypes(false).length > 0);
          break;
        case 'authenticate':
          this.authenticate(call, result);
          break;
        case 'stopAuthentication':
          result.success(this.cancel());
          break;
        default:
          result.notImplemented();
      }
    } catch (error) {
      const failure = error as BusinessError;
      result.error('AUTH_ERROR', failure.message, failure.code ?? null);
    }
  }

  private available(type: userAuth.UserAuthType): boolean {
    try {
      userAuth.getAvailableStatus(type, userAuth.AuthTrustLevel.ATL2);
      return true;
    } catch (error) {
      const failure = error as BusinessError;
      if (failure.code === userAuth.UserAuthResultCode.TYPE_NOT_SUPPORT ||
        failure.code === userAuth.UserAuthResultCode.TRUST_LEVEL_NOT_SUPPORT ||
        failure.code === userAuth.UserAuthResultCode.NOT_ENROLLED || failure.code === 12500013) return false;
      throw new Error(failure.message);
    }
  }

  private authTypes(biometricOnly: boolean): userAuth.UserAuthType[] {
    const types: userAuth.UserAuthType[] = [];
    if (this.available(userAuth.UserAuthType.FACE)) types.push(userAuth.UserAuthType.FACE);
    if (this.available(userAuth.UserAuthType.FINGERPRINT)) types.push(userAuth.UserAuthType.FINGERPRINT);
    if (!biometricOnly && this.available(userAuth.UserAuthType.PIN)) types.push(userAuth.UserAuthType.PIN);
    return types;
  }

  private authenticate(call: MethodCall, result: MethodResult): void {
    if (this.pending !== undefined) {
      result.error('AUTH_BUSY', 'An authentication is already in progress.', null);
      return;
    }
    const title: Any = call.argument('localizedReason');
    if (typeof title !== 'string' || title.length === 0 || title.length > 500) {
      result.error('AUTH_ARGUMENT', 'Authentication requires a nonempty reason.', null);
      return;
    }
    const types = this.authTypes(call.argument('biometricOnly') === true);
    if (types.length === 0) {
      result.error('AUTH_UNAVAILABLE', 'No enrolled device authentication is available.', null);
      return;
    }
    const instance = userAuth.getUserAuthInstance({
      challenge: cryptoFramework.createRandom().generateRandomSync(32).data,
      authType: types,
      authTrustLevel: userAuth.AuthTrustLevel.ATL2
    }, { title: title });
    this.active = instance;
    this.pending = result;
    try {
      instance.on('result', {
        onResult: (info: userAuth.UserAuthResult): void => {
          if (this.active !== instance || this.pending !== result) return;
          this.active = undefined;
          this.pending = undefined;
          this.unsubscribe(instance);
          result.success(!this.disposed && info.result === userAuth.UserAuthResultCode.SUCCESS);
        }
      });
      instance.start();
    } catch (error) {
      this.active = undefined;
      this.pending = undefined;
      this.unsubscribe(instance);
      throw new Error((error as BusinessError).message);
    }
  }

  cancel(): boolean {
    const instance = this.active;
    const result = this.pending;
    this.active = undefined;
    this.pending = undefined;
    if (instance === undefined) return false;
    let cancelled = false;
    try {
      instance.cancel();
      cancelled = true;
    } catch (_) {
      console.warn('Venera: system authentication cancellation failed.');
    } finally {
      this.unsubscribe(instance);
      result?.success(false);
    }
    return cancelled;
  }

  private unsubscribe(instance: userAuth.UserAuthInstance): void {
    try {
      instance.off('result');
    } catch (_) {
      console.warn('Venera: removing authentication listener failed.');
    }
  }

  dispose(): void {
    this.disposed = true;
    this.cancel();
    this.channel.setMethodCallHandler(null);
  }
}
