import Cocoa
import FlutterMacOS
import MetricKit

@main
class AppDelegate: FlutterAppDelegate {
  var flutterResult: FlutterResult?
  var directoryPath: URL!
  // Held for the life of the app; MetricKit does not promise to retain it.
  private let systemDiagnostics = SystemDiagnosticsKeeper()

  override func applicationDidFinishLaunching(_ notification: Notification) {
      MXMetricManager.shared.add(systemDiagnostics)
      let controller: FlutterViewController = mainFlutterWindow?.contentViewController as! FlutterViewController
      ReadingWidgetBridge.register(messenger: controller.engine.binaryMessenger)
      let methodChannel = FlutterMethodChannel(name: "venera/method_channel", binaryMessenger: controller.engine.binaryMessenger)

      methodChannel.setMethodCallHandler { (call, result) in
        switch call.method {
        case "getProxy":
            if let proxySettings = CFNetworkCopySystemProxySettings()?.takeUnretainedValue() as NSDictionary? {
                if let httpProxy = proxySettings[kCFNetworkProxiesHTTPProxy] as? String,
                   let httpPort = proxySettings[kCFNetworkProxiesHTTPPort] as? Int {
                    let proxyConfig = "\(httpProxy):\(httpPort)"
                    result(proxyConfig)
                } else if let socksProxy = proxySettings[kCFNetworkProxiesSOCKSProxy] as? String,
                          let socksPort = proxySettings[kCFNetworkProxiesSOCKSPort] as? Int {
                    let proxyConfig = "\(socksProxy):\(socksPort)"
                    result(proxyConfig)
                } else {
                    result("")
                }
            } else {
                result("")
            }
        case "getDirectoryPath":
          self.flutterResult = result
          self.getDirectoryPath()
        case "stopAccessingSecurityScopedResource":
          self.directoryPath?.stopAccessingSecurityScopedResource()
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }

      let clipboardChannel = FlutterMethodChannel(name: "venera/clipboard", binaryMessenger: controller.engine.binaryMessenger)

      clipboardChannel.setMethodCallHandler { (call, result) in
        switch call.method {
        case "writeImageToClipboard":
          guard let arguments = call.arguments as? [String: Any],
            let data = arguments["data"] as? FlutterStandardTypedData else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Invalid arguments", details: nil))
            return
          }

          guard let image = NSImage(data: data.data) else {
            result(FlutterError(code: "INVALID_IMAGE", message: "Could not create image from data", details: nil))
            return
          }

          let pasteboard = NSPasteboard.general
          pasteboard.clearContents()
          pasteboard.writeObjects([image])
          result(true)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

  func getDirectoryPath() {
      let openPanel = NSOpenPanel()
      openPanel.canChooseDirectories = true
      openPanel.canChooseFiles = false
      openPanel.allowsMultipleSelection = false

      openPanel.begin { (result) in
          if result == .OK {
              self.directoryPath = openPanel.urls.first
              if let directoryPath = self.directoryPath, !directoryPath.startAccessingSecurityScopedResource() {
                  self.flutterResult?(nil)
                  return
              }
              self.flutterResult?(self.directoryPath?.path)
          } else {
              self.flutterResult?(nil)
          }
      }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }
}

/// Keeps the crash and hang reports MetricKit delivers on a later launch, as
/// `diagnostics/system-<ms>-<n>.json` under the directory path_provider gives
/// Dart as application support. The diagnostic report reads them from there.
final class SystemDiagnosticsKeeper: NSObject, MXMetricManagerSubscriber {
  private static let maxFiles = 8

  // Same lookup as path_provider_foundation, which on macOS adds the bundle id.
  private static var directory: URL? {
    guard let base = NSSearchPathForDirectoriesInDomains(
      .applicationSupportDirectory, .userDomainMask, true
    ).first else { return nil }
    var url = URL(fileURLWithPath: base)
    if let bundleIdentifier = Bundle.main.bundleIdentifier {
      url = url.appendingPathComponent(bundleIdentifier)
    }
    return url.appendingPathComponent("diagnostics", isDirectory: true)
  }

  // Called on a background queue.
  func didReceive(_ payloads: [MXDiagnosticPayload]) {
    guard let directory = Self.directory else { return }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      return
    }
    let time = Int64(Date().timeIntervalSince1970 * 1000)
    for (index, payload) in payloads.enumerated() {
      let data = payload.jsonRepresentation()
      // Other kinds of report would push crashes out of the few kept.
      guard Self.hasCrashOrHang(data) else { continue }
      try? data.write(to: directory.appendingPathComponent("system-\(time)-\(index).json"), options: .atomic)
    }
    Self.prune(directory)
  }

  private static func hasCrashOrHang(_ data: Data) -> Bool {
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
    return (json["crashDiagnostics"] as? [Any])?.isEmpty == false
      || (json["hangDiagnostics"] as? [Any])?.isEmpty == false
  }

  private static func prune(_ directory: URL) {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
    let kept = names.compactMap { name -> (Int64, Int, String)? in
      guard name.hasPrefix("system-"), name.hasSuffix(".json") else { return nil }
      let parts = name.dropFirst(7).dropLast(5).split(separator: "-")
      guard parts.count == 2, let time = Int64(parts[0]), let index = Int(parts[1]) else { return nil }
      return (time, index, name)
    }.sorted { ($0.0, $0.1) > ($1.0, $1.1) }
    for (_, _, name) in kept.dropFirst(Self.maxFiles) {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
  }
}
