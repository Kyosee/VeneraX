import { bundleManager } from '@kit.AbilityKit';
import { FlutterAbility, FlutterEngine, MethodCall, MethodCallHandler, MethodChannel, MethodResult } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';

export default class EntryAbility extends FlutterAbility {
  private channels: MethodChannel[] = [];

  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine);
    GeneratedPluginRegistrant.registerWith(flutterEngine);
    const messenger = flutterEngine.getDartExecutor().getBinaryMessenger();
    const paths = new MethodChannel(messenger, 'plugins.flutter.io/path_provider');
    paths.setMethodCallHandler(new SandboxPaths(this.context.filesDir, this.context.cacheDir));
    const packageInfo = new MethodChannel(messenger, 'dev.fluttercommunity.plus/package_info');
    packageInfo.setMethodCallHandler(new PackageInfo());
    this.channels = [paths, packageInfo];
  }

  cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
    this.channels.forEach((channel: MethodChannel) => channel.setMethodCallHandler(null));
    this.channels = [];
    super.cleanUpFlutterEngine(flutterEngine);
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
