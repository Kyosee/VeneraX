import Foundation

enum ReadingWidgetKind: String, Codable, CaseIterable {
    case history, following, updates, local

    var headerURL: URL {
        var components = URLComponents()
        components.scheme = "venerax"
        components.host = "reading-widget"
        components.path = "/\(rawValue)"
        return components.url!
    }

    func itemURL(_ item: ReadingWidgetItem) -> URL? {
        var components = URLComponents(url: headerURL, resolvingAgainstBaseURL: false)!
        components.path = self == .history ? "/read" : "/\(rawValue)/read"
        components.queryItems = [
            URLQueryItem(name: "id", value: item.id),
            URLQueryItem(name: "type", value: String(item.type))
        ]
        // Dart queryParameters treats a literal plus as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}

struct ReadingWidgetItem: Codable {
    let id: String
    let type: Int64
    let title: String
    let progress: String
    var coverPath: String
    var sourceName: String? = nil
    var badge: String? = nil
    var pageProgress: Int? = nil
}

struct ReadingWidgetSnapshot: Codable {
    let kind: ReadingWidgetKind
    let locked: Bool
    let title: String
    let emptyText: String
    let subtitle: String
    var items: [ReadingWidgetItem]

    static func empty(_ kind: ReadingWidgetKind, locked: Bool = true) -> Self {
        Self(kind: kind, locked: locked, title: "", emptyText: "", subtitle: "", items: [])
    }

    static func decode(_ json: String) throws -> Self {
        guard let data = json.data(using: .utf8), data.count <= 256 * 1024 else {
            throw ReadingWidgetError.invalidSnapshot
        }
        var snapshot = try JSONDecoder().decode(Self.self, from: data)
        snapshot.items = Array(snapshot.items.filter {
            !$0.id.isEmpty && $0.id.utf8.count <= 1024
        }.prefix(6))
        return snapshot
    }
}

enum ReadingWidgetError: Error {
    case invalidSnapshot, containerUnavailable
}

private struct ReadingWidgetPrivacy: Codable {
    let locked: Bool
}

final class ReadingWidgetStore {
    static let appGroup = "group.io.github.kyosee.venera"
    let container: URL
    private let files = FileManager.default

    init(container: URL? = nil) throws {
        guard let url = container ?? FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroup
        ) else {
            throw ReadingWidgetError.containerUnavailable
        }
        self.container = url
    }

    var isLocked: Bool {
        guard let data = try? Data(contentsOf: container.appendingPathComponent("widget_privacy.json")),
              let privacy = try? JSONDecoder().decode(ReadingWidgetPrivacy.self, from: data) else {
            return true
        }
        return privacy.locked
    }

    func load(_ kind: ReadingWidgetKind) -> ReadingWidgetSnapshot {
        guard !isLocked, let snapshot = savedSnapshot(kind), !snapshot.locked, !isLocked else {
            return .empty(kind)
        }
        return snapshot
    }

    func coverURL(_ relativePath: String) -> URL? {
        let prefix = "widget_covers/"
        guard relativePath.hasPrefix(prefix),
              Self.isCoverName(String(relativePath.dropFirst(prefix.count))) else { return nil }
        let directory = container.appendingPathComponent("widget_covers", isDirectory: true)
            .standardizedFileURL
        let url = container.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
        guard url.deletingLastPathComponent() == directory.resolvingSymlinksInPath() else { return nil }
        return url
    }

    func update(_ input: ReadingWidgetSnapshot, sourceDirectory: URL) throws {
        try files.createDirectory(at: container, withIntermediateDirectories: true)
        let wasLocked = isLocked
        if input.locked {
            // Mask every family before touching snapshots or images.
            try writePrivacy(true)
            for kind in ReadingWidgetKind.allCases {
                try write(.empty(kind))
            }
            removeUnusedCovers()
            return
        }
        if wasLocked {
            // A process may have stopped after masking but before clearing all kinds.
            for kind in ReadingWidgetKind.allCases {
                try write(.empty(kind, locked: false))
            }
        }
        var snapshot = input
        snapshot.items = input.items.map { item in
            var copied = item
            copied.coverPath = copyCover(item.coverPath, sourceDirectory: sourceDirectory)
            return copied
        }
        try write(snapshot)
        try writePrivacy(false)
        removeUnusedCovers()
    }

    private func snapshotURL(_ kind: ReadingWidgetKind) -> URL {
        container.appendingPathComponent("widget_\(kind.rawValue).json")
    }

    private func savedSnapshot(_ kind: ReadingWidgetKind) -> ReadingWidgetSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL(kind)), data.count <= 256 * 1024,
              let snapshot = try? JSONDecoder().decode(ReadingWidgetSnapshot.self, from: data),
              snapshot.kind == kind else { return nil }
        return snapshot
    }

    private func write(_ snapshot: ReadingWidgetSnapshot) throws {
        try JSONEncoder().encode(snapshot).write(to: snapshotURL(snapshot.kind), options: .atomic)
    }

    private func writePrivacy(_ locked: Bool) throws {
        try JSONEncoder().encode(ReadingWidgetPrivacy(locked: locked)).write(
            to: container.appendingPathComponent("widget_privacy.json"), options: .atomic
        )
    }

    private static func isCoverName(_ name: String) -> Bool {
        guard name.hasSuffix(".png") else { return false }
        return UUID(uuidString: String(name.dropLast(4))) != nil
    }

    private func copyCover(_ path: String, sourceDirectory: URL) -> String {
        let source = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let allowed = sourceDirectory.resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent("reading_widget_covers", isDirectory: true)
        guard source.deletingLastPathComponent() == allowed, Self.isCoverName(source.lastPathComponent) else {
            return ""
        }
        let relative = "widget_covers/\(source.lastPathComponent)"
        let target = container.appendingPathComponent(relative)
        if files.fileExists(atPath: target.path) { return relative }
        do {
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size <= 2 * 1024 * 1024 else {
                return ""
            }
            let data = try Data(contentsOf: source)
            guard data.count <= 2 * 1024 * 1024,
                  data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) else { return "" }
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            return relative
        } catch {
            return ""
        }
    }

    private func removeUnusedCovers() {
        let used = Set(ReadingWidgetKind.allCases.flatMap { savedSnapshot($0)?.items.map(\.coverPath) ?? [] })
        let directory = container.appendingPathComponent("widget_covers", isDirectory: true)
        guard let children = try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in children where Self.isCoverName(file.lastPathComponent) {
            if !used.contains("widget_covers/\(file.lastPathComponent)") {
                try? files.removeItem(at: file)
            }
        }
    }
}
