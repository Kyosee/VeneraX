import Foundation
import WidgetKit
#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif

enum ReadingWidgetBridge {
    private static let queue = DispatchQueue(label: "io.github.kyosee.venera.widgets")

    static func register(messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: "venera/reading_widget", binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in
            switch call.method {
            case "hasWidgets":
                guard let name = call.arguments as? String, let kind = ReadingWidgetKind(rawValue: name) else {
                    result(FlutterError(code: "INVALID_WIDGET_KIND", message: "Unknown widget kind.", details: nil))
                    return
                }
                WidgetCenter.shared.getCurrentConfigurations { configurations in
                    DispatchQueue.main.async {
                        switch configurations {
                        case .success(let widgets): result(widgets.contains { $0.kind == kind.rawValue })
                        case .failure:
                            result(FlutterError(code: "WIDGET_UNAVAILABLE", message: "Unable to read widgets.", details: nil))
                        }
                    }
                }
            case "update":
                guard let json = call.arguments as? String else {
                    result(FlutterError(code: "INVALID_SNAPSHOT", message: "Expected widget JSON.", details: nil))
                    return
                }
                queue.async {
                    var kind: ReadingWidgetKind?
                    var reloadAll = false
                    var failure: FlutterError?
                    do {
                        let snapshot = try ReadingWidgetSnapshot.decode(json)
                        let store = try ReadingWidgetStore()
                        kind = snapshot.kind
                        reloadAll = snapshot.locked || store.isLocked
                        try store.update(snapshot, sourceDirectory:
                            snapshot.locked ? store.container : applicationSupportDirectory())
                    } catch ReadingWidgetError.containerUnavailable {
                        failure = FlutterError(code: "WIDGET_APP_GROUP_UNAVAILABLE",
                            message: "The widget App Group is unavailable.", details: nil)
                    } catch {
                        failure = FlutterError(code: "WIDGET_UPDATE_FAILED",
                            message: "Unable to save widget data.", details: nil)
                    }
                    DispatchQueue.main.async {
                        // Reload even if clearing files failed after privacy was persisted.
                        if reloadAll {
                            WidgetCenter.shared.reloadAllTimelines()
                        } else if let kind = kind {
                            WidgetCenter.shared.reloadTimelines(ofKind: kind.rawValue)
                        }
                        result(failure)
                    }
                }
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private static func applicationSupportDirectory() throws -> URL {
        var directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )
        #if os(macOS)
        // Match path_provider_foundation's macOS application support directory.
        if let identifier = Bundle.main.bundleIdentifier {
            directory.appendPathComponent(identifier, isDirectory: true)
        }
        #endif
        return directory
    }
}
