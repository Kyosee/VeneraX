import XCTest

// Run the same store tests on a Mac without building or signing the Flutter app.
@main
enum WidgetStoreTestRunner {
    static func main() {
        XCTMain([testCase([
            ("lock clears all kinds", RunnerTests.testLockedUpdateClearsAllKindsAndMasksPersistedEntries),
            ("unlock after interrupted clear", RunnerTests.testUnlockAfterInterruptedClearCannotRestoreOtherKinds),
            ("shared cover references", RunnerTests.testSharedCoverSurvivesWhileAnotherKindReferencesIt),
            ("invalid paths and privacy", RunnerTests.testForeignCoverAndMalformedPrivacyFailClosed),
            ("encoded comic destinations", RunnerTests.testDestinationsKeepComicIdentityAndRejectUnknownKind)
        ])])
    }
}
