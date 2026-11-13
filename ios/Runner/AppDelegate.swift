import Flutter
import UIKit
import UniformTypeIdentifiers
import Foundation // 添加此行

@main
@objc class AppDelegate: FlutterAppDelegate, UIDocumentPickerDelegate, FlutterImplicitEngineDelegate {
  var flutterResult: FlutterResult?
  var directoryPath: URL!
  private var flutterRegistrar: FlutterPluginRegistrar?
  private var flutterViewController: FlutterViewController? {
    // The implicit engine attaches its controller after initialization.
    flutterRegistrar?.viewController as? FlutterViewController
  }

  // 定义插件通道名称
  private var directoryPicker: DirectoryPicker?
  // Scene delegates are held weakly by the engine.
  private let appShortcuts = AppShortcutBridge()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    ReadingWidgetBridge.register(messenger: engineBridge.applicationRegistrar.messenger())
    flutterRegistrar = engineBridge.pluginRegistry
      .registrar(forPlugin: "VeneraAppDelegate")
    FlutterEventChannel(
      name: "venera/notification_route",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    ).setStreamHandler(appShortcuts)
    flutterRegistrar?.addSceneDelegate(appShortcuts)

    let methodChannel = FlutterMethodChannel(
      name: "venera/method_channel",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    methodChannel.setMethodCallHandler { (call, result) in
      if call.method == "getProxy" {
        if let proxySettings = CFNetworkCopySystemProxySettings()?.takeUnretainedValue() as NSDictionary?,
          let dict = proxySettings.object(forKey: kCFNetworkProxiesHTTPProxy) as? NSDictionary,
          let host = dict.object(forKey: kCFNetworkProxiesHTTPProxy) as? String,
          let port = dict.object(forKey: kCFNetworkProxiesHTTPPort) as? Int {
          let proxyConfig = "\(host):\(port)"
          result(proxyConfig)
        } else {
          result("")
        }
      } else if call.method == "setScreenOn" {
        if let arguments = call.arguments as? Bool {
          let screenOn = arguments
          UIApplication.shared.isIdleTimerDisabled = screenOn
        }
        result(nil)
      } else if call.method == "getDirectoryPath" {
        self.flutterResult = result
        self.getDirectoryPath()
      } else if call.method == "stopAccessingSecurityScopedResource" {
        self.directoryPath?.stopAccessingSecurityScopedResource()
        self.directoryPath = nil
        result(nil)
      } else if call.method == "selectDirectory" {
        self.directoryPicker = DirectoryPicker()
        self.directoryPicker?.selectDirectory(
          result: result,
          presenter: self.flutterViewController
        )
      } else if call.method == "supportsAlternateIcons" {
        result(UIApplication.shared.supportsAlternateIcons)
      } else if call.method == "setLauncherIcon" {
        // Alias name from CFBundleAlternateIcons, or nil/empty to restore the
        // primary icon. iOS shows its own "icon changed" alert; we deliberately
        // do not suppress it, since that requires a private selector.
        let args = call.arguments as? [String: Any]
        let alias = args?["alias"] as? String
        self.setAlternateIcon(alias?.isEmpty == false ? alias : nil, result: result)
      } else if call.method == "setAppShortcuts" {
        result(self.appShortcuts.publish(call.arguments))
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

  }

  /// Swap the home-screen launcher icon to an alternate declared in
  /// CFBundleAlternateIcons. Reports false (not an error) when the device
  /// refuses, matching the Android handler's boolean contract.
  private func setAlternateIcon(_ alias: String?, result: @escaping FlutterResult) {
    guard UIApplication.shared.supportsAlternateIcons else {
      result(false)
      return
    }
    UIApplication.shared.setAlternateIconName(alias) { error in
      // setAlternateIconName may call back off the main thread.
      DispatchQueue.main.async {
        if let error = error {
          NSLog("Venera: set launcher icon failed: \(error.localizedDescription)")
          result(false)
        } else {
          result(true)
        }
      }
    }
  }

  func getDirectoryPath() {
    guard let presenter = flutterViewController else {
      flutterResult?(nil)
      flutterResult = nil
      return
    }

    let documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
    documentPicker.delegate = self
    documentPicker.allowsMultipleSelection = false
    documentPicker.directoryURL = nil
    documentPicker.modalPresentationStyle = .formSheet

    presenter.present(documentPicker, animated: true, completion: nil)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    self.directoryPath = urls.first
    if self.directoryPath == nil {
      flutterResult?(nil)
      return
    }

    let success = self.directoryPath.startAccessingSecurityScopedResource()

    if success {
      flutterResult?(self.directoryPath.path)
    } else {
      flutterResult?(nil)
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    flutterResult?(nil)
  }
}

/// Home-screen quick actions. A tap is sent to Dart as a route, the same way
/// Android and HarmonyOS deliver notification and shortcut taps.
final class AppShortcutBridge: NSObject, FlutterStreamHandler, FlutterSceneLifeCycleDelegate {
  private static let symbols = [
    "favorites": "star",
    "follow_updates": "bell.badge",
    "history": "clock.arrow.circlepath",
    "search": "magnifyingglass",
  ]
  private var sink: FlutterEventSink?
  // A cold-start tap arrives before Dart listens.
  private var pending: String?

  /// Arguments are `{route, label}` maps in display order.
  func publish(_ arguments: Any?) -> Bool {
    guard let items = arguments as? [[String: Any]] else { return false }
    UIApplication.shared.shortcutItems = items.compactMap { item in
      guard let route = item["route"] as? String,
        let symbol = Self.symbols[route],
        let label = item["label"] as? String, !label.isEmpty
      else { return nil }
      return UIApplicationShortcutItem(
        type: route,
        localizedTitle: label,
        localizedSubtitle: nil,
        icon: UIApplicationShortcutIcon(systemImageName: symbol),
        userInfo: nil
      )
    }
    return true
  }

  private func deliver(_ item: UIApplicationShortcutItem) -> Bool {
    guard Self.symbols[item.type] != nil else { return false }
    if let sink = sink {
      sink(item.type)
    } else {
      pending = item.type
    }
    return true
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    if let route = pending {
      pending = nil
      events(route)
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    if let item = connectionOptions?.shortcutItem {
      _ = deliver(item)
    }
    // A shortcut launch carries no URL; leave the options to other delegates.
    return false
  }

  @objc(windowScene:performActionForShortcutItem:completionHandler:)
  func windowScene(
    _ windowScene: UIWindowScene,
    performActionFor shortcutItem: UIApplicationShortcutItem,
    completionHandler: @escaping (Bool) -> Void
  ) -> Bool {
    guard deliver(shortcutItem) else { return false }
    completionHandler(true)
    return true
  }
}
