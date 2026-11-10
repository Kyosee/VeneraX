import batteryInfo from '@ohos.batteryInfo';
import common from '@ohos.app.ability.common';
import commonEventManager from '@ohos.commonEventManager';
import connection from '@ohos.net.connection';
import power from '@ohos.power';
import window from '@ohos.window';
import hidebug from '@ohos.hidebug';
import inputConsumer from '@ohos.multimodalInput.inputConsumer';
import { KeyEvent } from '@ohos.multimodalInput.keyEvent';
import { KeyCode } from '@ohos.multimodalInput.keyCode';
import { BusinessError } from '@ohos.base';
import { StartupTheme } from './StartupTheme';
import {
  Any, EventChannel, EventSink, FlutterEngine, MethodCall, MethodCallHandler, MethodChannel, MethodResult, StreamHandler
} from '@ohos/flutter_ohos';

export class DeviceServices {
  private battery = new BatteryService();
  private connectivity = new ConnectivityService();
  private batteryMethods: MethodChannel;
  private batteryEvents: EventChannel;
  private connectivityMethods: MethodChannel;
  private connectivityEvents: EventChannel;
  private memoryMethods: MethodChannel;
  private volumeEvents: EventChannel;
  private volume = new VolumeService();
  private context: common.UIAbilityContext;
  private screenWindow?: window.Window;
  private screenRequest = 0;
  private disposed = false;

  constructor(engine: FlutterEngine, context: common.UIAbilityContext) {
    this.context = context;
    const messenger = engine.getDartExecutor().getBinaryMessenger();
    this.batteryMethods = new MethodChannel(messenger, 'dev.fluttercommunity.plus/battery');
    this.batteryMethods.setMethodCallHandler(this.battery);
    this.batteryEvents = new EventChannel(messenger, 'dev.fluttercommunity.plus/charging');
    this.batteryEvents.setStreamHandler(this.battery);
    this.connectivityMethods = new MethodChannel(messenger, 'dev.fluttercommunity.plus/connectivity');
    this.connectivityMethods.setMethodCallHandler(this.connectivity);
    this.connectivityEvents = new EventChannel(messenger, 'dev.fluttercommunity.plus/connectivity_status');
    this.connectivityEvents.setStreamHandler(this.connectivity);
    this.memoryMethods = new MethodChannel(messenger, 'flutter_memory_info');
    this.memoryMethods.setMethodCallHandler(new MemoryService());
    this.volumeEvents = new EventChannel(messenger, 'venera/volume');
    this.volumeEvents.setStreamHandler(this.volume);
  }

  // Route the shared venera channel here without replacing its other handlers.
  handleMethodCall(call: MethodCall, result: MethodResult): boolean {
    if (call.method !== 'getProxy' && call.method !== 'setScreenOn' && call.method !== 'setThemeMode') return false;
    if (this.disposed) {
      result.error('DEVICE_SERVICES_CLOSED', 'Device services have been disposed.', null);
      return true;
    }
    if (call.method === 'getProxy') {
      this.getProxy(result);
    } else if (call.method === 'setThemeMode') {
      const mode: Any = call.args;
      if (typeof mode !== 'string' || !['light', 'dark', 'system'].includes(mode as string)) {
        result.error('INVALID_ARGUMENT', 'Unknown theme mode.', null);
        return true;
      }
      StartupTheme.setMode(this.context, mode as string).then(() => {
        result.success(null);
      }).catch((_error: BusinessError) => {
        result.error('THEME_UNAVAILABLE', 'Unable to save the startup theme.', null);
      });
    } else {
      this.setScreenOn(call, result);
    }
    return true;
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.batteryMethods.setMethodCallHandler(null);
    this.batteryEvents.setStreamHandler(null);
    this.connectivityMethods.setMethodCallHandler(null);
    this.connectivityEvents.setStreamHandler(null);
    this.memoryMethods.setMethodCallHandler(null);
    this.volumeEvents.setStreamHandler(null);
    this.volume.dispose();
    this.battery.dispose();
    this.connectivity.dispose();
    this.screenWindow?.setWindowKeepScreenOn(false).catch((error: BusinessError) => {
      console.warn(`Venera: releasing screen wake request failed (${error.code}).`);
    });
    this.screenWindow = undefined;
  }

  private async getProxy(result: MethodResult): Promise<void> {
    try {
      const proxy = await connection.getDefaultHttpProxy();
      const host = proxy.host.trim();
      if (host.length === 0 || proxy.port <= 0 || proxy.port > 65535 ||
        (proxy.exclusionList.length === 1 && proxy.exclusionList[0] === '*')) {
        result.success('No Proxy');
        return;
      }
      const address = host.includes(':') && !host.startsWith('[') ? `[${host}]` : host;
      result.success(`${address}:${proxy.port}`);
    } catch (error) {
      const failure = error as BusinessError;
      result.error('PROXY_UNAVAILABLE', failure.message, failure.code);
    }
  }

  private async setScreenOn(call: MethodCall, result: MethodResult): Promise<void> {
    const request = ++this.screenRequest;
    try {
      const enabled = typeof call.args === 'boolean' ? call.args as boolean : call.argument('set') as boolean;
      if (typeof enabled !== 'boolean') {
        result.error('INVALID_ARGUMENT', 'setScreenOn requires a boolean or a boolean set argument.', null);
        return;
      }
      const target = this.screenWindow ?? await window.getLastWindow(this.context);
      if (this.disposed) {
        result.error('DEVICE_SERVICES_CLOSED', 'Device services have been disposed.', null);
        return;
      }
      if (request !== this.screenRequest) {
        result.success(null);
        return;
      }
      this.screenWindow = target;
      await target.setWindowKeepScreenOn(enabled);
      if (this.disposed) await target.setWindowKeepScreenOn(false);
      result.success(null);
    } catch (error) {
      const failure = error as BusinessError;
      result.error('SCREEN_ON_FAILED', failure.message, failure.code);
    }
  }
}

class MemoryService implements MethodCallHandler {
  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method !== 'getFreePhysicalMemorySize') {
      result.notImplemented();
      return;
    }
    try {
      const available = hidebug.getSystemMemInfo().availableMem;
      const bytes = typeof available === 'bigint' ? Number(available) * 1024 : -1;
      result.success(Number.isSafeInteger(bytes) && bytes >= 0 ? bytes : null);
    } catch (_) {
      result.success(null);
    }
  }
}

class VolumeService implements StreamHandler {
  private events?: EventSink;
  private up?: (event: KeyEvent) => void;
  private down?: (event: KeyEvent) => void;

  onListen(_args: Any, events: EventSink): void {
    this.dispose();
    this.events = events;
    const up = (_event: KeyEvent): void => {
      if (this.up === up && this.events === events) events.success(1);
    };
    const down = (_event: KeyEvent): void => {
      if (this.down === down && this.events === events) events.success(2);
    };
    try {
      inputConsumer.on('keyPressed', { key: KeyCode.KEYCODE_VOLUME_UP, action: 1, isRepeat: false }, up);
      this.up = up;
      inputConsumer.on('keyPressed', { key: KeyCode.KEYCODE_VOLUME_DOWN, action: 1, isRepeat: false }, down);
      this.down = down;
    } catch (error) {
      this.dispose();
      const failure = error as BusinessError;
      events.error('VOLUME_UNAVAILABLE', failure.message, failure.code);
    }
  }

  onCancel(_args: Any): void {
    this.dispose();
  }

  dispose(): void {
    this.events = undefined;
    const callbacks = [this.up, this.down];
    this.up = undefined;
    this.down = undefined;
    for (const callback of callbacks) {
      if (callback === undefined) continue;
      try {
        inputConsumer.off('keyPressed', callback);
      } catch (_) {
        console.warn('Venera: releasing a volume key listener failed.');
      }
    }
  }
}

class BatteryService implements MethodCallHandler, StreamHandler {
  private subscriber?: commonEventManager.CommonEventSubscriber;
  private events?: EventSink;
  private lastState = '';

  onMethodCall(call: MethodCall, result: MethodResult): void {
    try {
      switch (call.method) {
        case 'getBatteryLevel':
          const level = batteryInfo.batterySOC;
          if (level < 0 || level > 100) {
            result.error('BATTERY_UNAVAILABLE', 'The system did not provide a valid battery level.', null);
          } else {
            result.success(level);
          }
          break;
        case 'getBatteryState':
          result.success(this.state());
          break;
        case 'isInBatterySaveMode':
          const mode = power.getPowerMode();
          result.success(mode === power.DevicePowerMode.MODE_POWER_SAVE ||
            mode === power.DevicePowerMode.MODE_EXTREME_POWER_SAVE ||
            mode === power.DevicePowerMode.MODE_CUSTOM_POWER_SAVE);
          break;
        default:
          result.notImplemented();
      }
    } catch (error) {
      const failure = error as BusinessError;
      result.error('BATTERY_UNAVAILABLE', failure.message, failure.code);
    }
  }

  onListen(_args: Any, events: EventSink): void {
    this.dispose();
    this.events = events;
    try {
      const subscriber = commonEventManager.createSubscriberSync({
        events: [commonEventManager.Support.COMMON_EVENT_BATTERY_CHANGED]
      });
      this.subscriber = subscriber;
      commonEventManager.subscribe(subscriber, (error: BusinessError) => {
        if (this.subscriber !== subscriber) return;
        if (error) {
          events.error('BATTERY_UNAVAILABLE', error.message, error.code);
        } else {
          this.publishState();
        }
      });
      this.publishState();
    } catch (error) {
      const failure = error as BusinessError;
      events.error('BATTERY_UNAVAILABLE', failure.message, failure.code);
      this.dispose();
    }
  }

  onCancel(_args: Any): void {
    this.dispose();
  }

  dispose(): void {
    this.events = undefined;
    this.lastState = '';
    const subscriber = this.subscriber;
    this.subscriber = undefined;
    if (subscriber !== undefined) {
      try {
        commonEventManager.unsubscribe(subscriber, (error: BusinessError) => {
          if (error) console.warn(`Venera: battery listener cleanup failed (${error.code}).`);
        });
      } catch (error) {
        console.warn(`Venera: battery listener cleanup failed (${(error as BusinessError).code}).`);
      }
    }
  }

  private state(): string {
    switch (batteryInfo.chargingStatus) {
      case batteryInfo.BatteryChargeState.FULL:
        return 'full';
      case batteryInfo.BatteryChargeState.ENABLE:
        return 'charging';
      case batteryInfo.BatteryChargeState.DISABLE:
        return batteryInfo.pluggedType === batteryInfo.BatteryPluggedType.NONE ?
          'discharging' : 'connected_not_charging';
      default:
        return 'unknown';
    }
  }

  private publishState(): void {
    try {
      const state = this.state();
      if (state === this.lastState) return;
      this.lastState = state;
      this.events?.success(state);
    } catch (error) {
      const failure = error as BusinessError;
      this.events?.error('BATTERY_UNAVAILABLE', failure.message, failure.code);
    }
  }
}

class ConnectivityService implements MethodCallHandler, StreamHandler {
  private monitor?: connection.NetConnection;
  private registered = false;
  private events?: EventSink;
  private revision = 0;
  private lastTypes = '';

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method !== 'check') {
      result.notImplemented();
      return;
    }
    this.check().then((types: string[]) => result.success(types)).catch((error: BusinessError) => {
      result.error('CONNECTIVITY_UNAVAILABLE', error.message, error.code);
    });
  }

  onListen(_args: Any, events: EventSink): void {
    this.dispose();
    this.events = events;
    try {
      const monitor = connection.createNetConnection();
      this.monitor = monitor;
      monitor.on('netAvailable', () => this.publishTypes(monitor));
      monitor.on('netCapabilitiesChange', () => this.publishTypes(monitor));
      monitor.on('netLost', () => this.publishTypes(monitor));
      monitor.on('netUnavailable', () => this.publishTypes(monitor));
      monitor.register((error: BusinessError) => {
        if (this.monitor !== monitor) {
          if (!error) this.unregister(monitor);
          return;
        }
        if (error) {
          this.monitor = undefined;
          events.error('CONNECTIVITY_UNAVAILABLE', error.message, error.code);
          return;
        }
        this.registered = true;
        this.publishTypes(monitor);
      });
    } catch (error) {
      const failure = error as BusinessError;
      events.error('CONNECTIVITY_UNAVAILABLE', failure.message, failure.code);
      this.dispose();
    }
  }

  onCancel(_args: Any): void {
    this.dispose();
  }

  dispose(): void {
    const monitor = this.monitor;
    const registered = this.registered;
    this.monitor = undefined;
    this.registered = false;
    this.events = undefined;
    this.lastTypes = '';
    this.revision++;
    if (monitor !== undefined && registered) this.unregister(monitor);
  }

  private async check(): Promise<string[]> {
    try {
      if (!await connection.hasDefaultNet()) return ['none'];
      const network = await connection.getDefaultNet();
      const capabilities = await connection.getNetCapabilities(network);
      const types: string[] = [];
      capabilities.bearerTypes.forEach((bearer: connection.NetBearType) => {
        let type: string;
        switch (bearer) {
          case connection.NetBearType.BEARER_WIFI: type = 'wifi'; break;
          case connection.NetBearType.BEARER_CELLULAR: type = 'mobile'; break;
          case connection.NetBearType.BEARER_ETHERNET: type = 'ethernet'; break;
          case connection.NetBearType.BEARER_BLUETOOTH: type = 'bluetooth'; break;
          case connection.NetBearType.BEARER_VPN: type = 'vpn'; break;
          default: type = 'other';
        }
        if (!types.includes(type)) types.push(type);
      });
      return types.length === 0 ? ['other'] : types;
    } catch (error) {
      // The default network may disappear between the availability and capability queries.
      try {
        if (!await connection.hasDefaultNet()) return ['none'];
      } catch (_checkError) {
        throw new Error((error as BusinessError).message);
      }
      throw new Error((error as BusinessError).message);
    }
  }

  private async publishTypes(monitor: connection.NetConnection): Promise<void> {
    if (this.monitor !== monitor) return;
    const revision = ++this.revision;
    try {
      const types = await this.check();
      if (this.monitor !== monitor || revision !== this.revision) return;
      const key = types.join(',');
      if (key === this.lastTypes) return;
      this.lastTypes = key;
      this.events?.success(types);
    } catch (error) {
      if (this.monitor !== monitor || revision !== this.revision) return;
      const failure = error as BusinessError;
      this.events?.error('CONNECTIVITY_UNAVAILABLE', failure.message, failure.code);
    }
  }

  private unregister(monitor: connection.NetConnection): void {
    try {
      monitor.unregister((error: BusinessError) => {
        if (error) console.warn(`Venera: network listener cleanup failed (${error.code}).`);
      });
    } catch (error) {
      console.warn(`Venera: network listener cleanup failed (${(error as BusinessError).code}).`);
    }
  }
}
