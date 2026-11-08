import { bundleManager } from '@kit.AbilityKit';
import { FlutterAbility, FlutterEngine, MethodCall, MethodCallHandler, MethodChannel, MethodResult } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import { DeviceServices } from '../bridge/DeviceServices';
import { PdfService } from '../bridge/PdfService';
import { FileServices } from '../bridge/FileServices';
import { AuthService } from '../bridge/AuthService';

export default class EntryAbility extends FlutterAbility {
  private channels: MethodChannel[] = [];
  private deviceServices?: DeviceServices;
  private fileServices?: FileServices;
  private authServices?: AuthService;
  private pdf?: PdfService;

  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine);
    GeneratedPluginRegistrant.registerWith(flutterEngine);
    const messenger = flutterEngine.getDartExecutor().getBinaryMessenger();
    const paths = new MethodChannel(messenger, 'plugins.flutter.io/path_provider');
    paths.setMethodCallHandler(new SandboxPaths(this.context.filesDir, this.context.cacheDir));
    const packageInfo = new MethodChannel(messenger, 'dev.fluttercommunity.plus/package_info');
    packageInfo.setMethodCallHandler(new PackageInfo());
    this.deviceServices = new DeviceServices(flutterEngine, this.context);
    this.fileServices = new FileServices(this.context, flutterEngine);
    this.authServices = new AuthService(flutterEngine);
    const system = new MethodChannel(messenger, 'venera/method_channel');
    system.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        if (this.deviceServices?.handleMethodCall(call, result)) return;
        if (this.fileServices?.handleMethodCall(call, result)) return;
        result.notImplemented();
      }
    });
    const pdf = new MethodChannel(messenger, 'venera/pdf');
    this.pdf = new PdfService();
    pdf.setMethodCallHandler(this.pdf);
    this.channels = [paths, packageInfo, system, pdf];
  }

  cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
    this.authServices?.dispose();
    this.authServices = undefined;
    this.deviceServices?.dispose();
    this.deviceServices = undefined;
    this.fileServices?.dispose();
    this.fileServices = undefined;
    this.pdf?.dispose();
    this.pdf = undefined;
    this.channels.forEach((channel: MethodChannel) => channel.setMethodCallHandler(null));
    this.channels = [];
    super.cleanUpFlutterEngine(flutterEngine);
  }

  onBackground(): void {
    this.authServices?.cancel();
    super.onBackground();
  }
}

class SandboxPaths implements MethodCallHandler {
  private filesDir: string;
  private cacheDir: string;

  constructor(filesDir: string, cacheDir: string) {
    this.filesDir = filesDir;
    this.cacheDir = cacheDir;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'getApplicationSupportDirectory':
      case 'getApplicationDocumentsDirectory':
        result.success(this.filesDir);
        break;
      case 'getTemporaryDirectory':
      case 'getApplicationCacheDirectory':
        result.success(this.cacheDir);
        break;
      default:
        result.notImplemented();
    }
  }
}

class PackageInfo implements MethodCallHandler {
  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method !== 'getAll') {
      result.notImplemented();
      return;
    }
    try {
      const info = bundleManager.getBundleInfoForSelfSync(0);
      result.success(new Map<string, string>([
        ['appName', 'Venera'],
        ['packageName', info.name],
        ['version', info.versionName],
        ['buildNumber', info.versionCode.toString()]
      ]));
    } catch (error) {
      result.error('PACKAGE_INFO_UNAVAILABLE', 'Unable to read bundle information.', null);
    }
  }
}
