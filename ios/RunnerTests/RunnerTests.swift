import XCTest
#if !WIDGET_STORE_STANDALONE
import Flutter
import UIKit
@testable import Runner
#endif

class RunnerTests: XCTestCase {
  private var directory: URL!
  private var source: URL!
  private var store: ReadingWidgetStore!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    source = directory.appendingPathComponent("app", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    store = try ReadingWidgetStore(container: directory.appendingPathComponent("group", isDirectory: true))
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: directory)
  }

  private func snapshot(_ kind: ReadingWidgetKind, cover: String = "", locked: Bool = false) -> ReadingWidgetSnapshot {
    ReadingWidgetSnapshot(kind: kind, locked: locked, title: "Title", emptyText: "Empty", subtitle: "",
      items: [ReadingWidgetItem(id: "book/一?x=1+2&y=2", type: 42, title: "Book", progress: "Page 3", coverPath: cover)])
  }

  func testLockedUpdateClearsAllKindsAndMasksPersistedEntries() throws {
    for kind in ReadingWidgetKind.allCases {
      try store.update(snapshot(kind), sourceDirectory: source)
    }
    try store.update(snapshot(.history, locked: true), sourceDirectory: source)
    XCTAssertTrue(store.isLocked)
    for kind in ReadingWidgetKind.allCases {
      XCTAssertTrue(store.load(kind).items.isEmpty)
      let data = try Data(contentsOf: store.container.appendingPathComponent("widget_\(kind.rawValue).json"))
      XCTAssertTrue(try JSONDecoder().decode(ReadingWidgetSnapshot.self, from: data).items.isEmpty)
    }
  }

  func testUnlockAfterInterruptedClearCannotRestoreOtherKinds() throws {
    try store.update(snapshot(.following), sourceDirectory: source)
    try Data("{\"locked\":true}".utf8).write(to: store.container.appendingPathComponent("widget_privacy.json"), options: .atomic)
    try store.update(snapshot(.history), sourceDirectory: source)
    XCTAssertFalse(store.isLocked)
    XCTAssertEqual(store.load(.history).items.count, 1)
    XCTAssertTrue(store.load(.following).items.isEmpty)
  }

  func testSharedCoverSurvivesWhileAnotherKindReferencesIt() throws {
    let covers = source.appendingPathComponent("reading_widget_covers", isDirectory: true)
    try FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
    let cover = covers.appendingPathComponent("\(UUID().uuidString).png")
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jJ1kAAAAASUVORK5CYII=")!
    try png.write(to: cover)
    try store.update(snapshot(.history, cover: cover.path), sourceDirectory: source)
    try store.update(snapshot(.following, cover: cover.path), sourceDirectory: source)
    let relative = store.load(.history).items[0].coverPath
    let shared = try XCTUnwrap(store.coverURL(relative))
    XCTAssertEqual(try Data(contentsOf: shared), png)
    try store.update(.empty(.history, locked: false), sourceDirectory: source)
    XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path))
    try store.update(.empty(.following, locked: false), sourceDirectory: source)
    XCTAssertFalse(FileManager.default.fileExists(atPath: shared.path))
  }

  func testForeignCoverAndMalformedPrivacyFailClosed() throws {
    try store.update(snapshot(.history, cover: "/outside/\(UUID().uuidString).png"), sourceDirectory: source)
    XCTAssertEqual(store.load(.history).items[0].coverPath, "")
    XCTAssertNil(store.coverURL("widget_covers/../widget_history.json"))
    try Data("invalid".utf8).write(to: store.container.appendingPathComponent("widget_privacy.json"))
    XCTAssertTrue(store.load(.history).items.isEmpty)
  }

  func testDestinationsKeepComicIdentityAndRejectUnknownKind() throws {
    for kind in ReadingWidgetKind.allCases {
      let book = snapshot(kind).items[0]
      let url = try XCTUnwrap(kind.itemURL(book))
      let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
      XCTAssertEqual(components.scheme, "venerax")
      XCTAssertEqual(components.host, "reading-widget")
      XCTAssertEqual(components.path, kind == .history ? "/read" : "/\(kind.rawValue)/read")
      XCTAssertEqual(components.queryItems?.first(where: { $0.name == "id" })?.value, book.id)
      XCTAssertTrue(url.absoluteString.contains("%2B"))
    }
    XCTAssertThrowsError(try ReadingWidgetSnapshot.decode("{\"kind\":\"unknown\",\"locked\":false}"))
  }

  func testOldSnapshotDecodesWithoutNewDisplayMetadata() throws {
    let json = """
    {"kind":"history","locked":false,"title":"Recent","emptyText":"","subtitle":"","items":[{"id":"book","type":42,"title":"Book","progress":"Page 3","coverPath":""}]}
    """
    let legacy = try ReadingWidgetSnapshot.decode(json)
    XCTAssertNil(legacy.items[0].sourceName)
    XCTAssertNil(legacy.items[0].pageProgress)
    var enriched = legacy
    enriched.items[0].sourceName = "My source"
    enriched.items[0].badge = "New"
    enriched.items[0].pageProgress = 35
    try store.update(enriched, sourceDirectory: source)
    let restored = store.load(.history).items[0]
    XCTAssertEqual(restored.sourceName, "My source")
    XCTAssertEqual(restored.badge, "New")
    XCTAssertEqual(restored.pageProgress, 35)
  }
}
