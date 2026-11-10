import SwiftUI
import WidgetKit

@main
struct VeneraReadingWidgets: WidgetBundle {
    var body: some Widget {
        ReadingWidget(kind: .history)
        ReadingWidget(kind: .following)
        ReadingWidget(kind: .updates)
        ReadingWidget(kind: .local)
    }
}

private struct ReadingWidget: Widget {
    let kind: ReadingWidgetKind

    init() {
        self.init(kind: .history)
    }

    init(kind: ReadingWidgetKind) {
        self.kind = kind
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind.rawValue, provider: ReadingWidgetProvider(kind: kind)) { entry in
            ReadingWidgetView(entry: entry)
        }
        .configurationDisplayName(Text(kind.displayName))
        .description(Text(kind.widgetDescription))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct ReadingWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: ReadingWidgetSnapshot
}

private struct ReadingWidgetProvider: TimelineProvider {
    let kind: ReadingWidgetKind

    func placeholder(in context: Context) -> ReadingWidgetEntry {
        ReadingWidgetEntry(date: Date(), snapshot: .empty(kind))
    }

    func getSnapshot(in context: Context, completion: @escaping (ReadingWidgetEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ReadingWidgetEntry>) -> Void) {
        completion(Timeline(entries: [currentEntry()], policy: .never))
    }

    private func currentEntry() -> ReadingWidgetEntry {
        let snapshot = (try? ReadingWidgetStore())?.load(kind) ?? .empty(kind)
        return ReadingWidgetEntry(date: Date(), snapshot: snapshot)
    }
}

private struct ReadingWidgetView: View {
    let entry: ReadingWidgetEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color {
        colorScheme == .dark
            ? Color(red: 0.82, green: 0.74, blue: 1)
            : Color(red: 0.40, green: 0.31, blue: 0.64)
    }

    private var snapshot: ReadingWidgetSnapshot {
        guard let store = try? ReadingWidgetStore(), !store.isLocked else {
            return .empty(entry.snapshot.kind)
        }
        return entry.snapshot.locked ? .empty(entry.snapshot.kind) : entry.snapshot
    }

    var body: some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            content.containerBackground(for: .widget) { background }
        } else {
            content.padding(12).background(background)
        }
    }

    private var content: some View {
        let data = snapshot
        let destination = family == .systemSmall
            ? data.items.first.flatMap { data.kind.itemURL($0) } ?? data.kind.headerURL
            : data.kind.headerURL
        return VStack(alignment: .leading, spacing: 10) {
            if family == .systemSmall {
                header(data)
            } else {
                Link(destination: data.kind.headerURL) { header(data) }
                    .buttonStyle(.plain)
            }
            if data.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: data.locked ? "lock" : data.kind.symbol)
                        .font(.title2).foregroundStyle(accent).accessibilityHidden(true)
                    Text(data.emptyText.isEmpty ? data.kind.emptyText(locked: data.locked) : data.emptyText)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        .multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if family == .systemSmall {
                item(data.items[0], large: false)
                    .frame(maxHeight: .infinity, alignment: .center)
            } else if family == .systemMedium {
                HStack(alignment: .center, spacing: 14) {
                    ForEach(Array(data.items.prefix(2).enumerated()), id: \.offset) { _, book in
                        bookLink(book, kind: data.kind, large: false)
                    }
                }.frame(maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(data.items.prefix(4).enumerated()), id: \.offset) { _, book in
                        bookLink(book, kind: data.kind, large: true)
                    }
                }.frame(maxHeight: .infinity, alignment: .top)
            }
            if !data.subtitle.isEmpty && family != .systemSmall {
                Text(data.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .widgetURL(destination)
        .tint(accent)
        .privacySensitive()
    }

    private func header(_ data: ReadingWidgetSnapshot) -> some View {
        HStack(spacing: 6) {
            Image(systemName: data.kind.symbol).foregroundStyle(accent)
            Text(data.title.isEmpty ? data.kind.displayName : data.title)
                .font(.caption.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
        }.foregroundStyle(.primary)
    }

    private func bookLink(_ book: ReadingWidgetItem, kind: ReadingWidgetKind, large: Bool) -> some View {
        Link(destination: kind.itemURL(book) ?? kind.headerURL) { item(book, large: large) }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func item(_ book: ReadingWidgetItem, large: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 9) {
                ReadingWidgetCover(path: book.coverPath)
                    .frame(width: large ? 36 : 44, height: large ? 52 : 64)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(book.title).font(.caption.weight(.semibold))
                        .foregroundStyle(.primary).lineLimit(2)
                    if let badge = book.badge, !badge.isEmpty {
                        Text(badge).font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(colorScheme == .dark ? Color.orange : Color(red: 0.60, green: 0.35, blue: 0))
                            .lineLimit(1)
                    } else if let source = book.sourceName, !source.isEmpty, !large {
                        Text(source).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if large {
                        progress(book)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if !large {
                progress(book)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func progress(_ book: ReadingWidgetItem) -> some View {
        if !book.progress.isEmpty {
            Text(book.progress).font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.85)
        }
        if let percent = book.pageProgress, percent >= 0 {
            ProgressView(value: Double(min(percent, 100)), total: 100)
                .progressViewStyle(.linear).tint(accent).accessibilityHidden(true)
        }
    }

    private var background: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
}

private struct ReadingWidgetCover: View {
    let path: String

    private var image: Image? {
        guard let store = try? ReadingWidgetStore(), !store.isLocked,
              let url = store.coverURL(path) else { return nil }
        #if os(iOS)
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        return Image(uiImage: image)
        #else
        guard let image = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: image)
        #endif
    }

    var body: some View {
        if let image = image {
            image.resizable().scaledToFill()
        } else {
            ZStack {
                Color.secondary.opacity(0.12)
                Image(systemName: "book.closed").foregroundStyle(.secondary)
            }
        }
    }
}

private extension ReadingWidgetKind {
    var displayName: String {
        switch self {
        case .history: return NSLocalizedString("Recent reading", comment: "Widget name")
        case .following: return NSLocalizedString("Following", comment: "Widget name")
        case .updates: return NSLocalizedString("Comic updates", comment: "Widget name")
        case .local: return NSLocalizedString("Local comics", comment: "Widget name")
        }
    }

    var widgetDescription: String {
        switch self {
        case .history: return NSLocalizedString("Continue your recent reading.", comment: "Widget description")
        case .following: return NSLocalizedString("Open comics you follow.", comment: "Widget description")
        case .updates: return NSLocalizedString("See updates from your followed comics.", comment: "Widget description")
        case .local: return NSLocalizedString("Open comics stored on this device.", comment: "Widget description")
        }
    }

    var symbol: String {
        switch self {
        case .history: return "books.vertical"
        case .following: return "bookmark"
        case .updates: return "sparkles"
        case .local: return "internaldrive"
        }
    }

    func emptyText(locked: Bool) -> String {
        if locked { return NSLocalizedString("Open VeneraX to view this widget", comment: "Locked widget") }
        return NSLocalizedString("Open VeneraX to update this widget", comment: "Empty widget")
    }
}
