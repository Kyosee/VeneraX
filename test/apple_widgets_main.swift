import Darwin
import XCTest

// Run the same store tests on a Mac without building or signing the Flutter app.
@main
enum WidgetStoreTestRunner {
    static func main() {
        let suite = RunnerTests.defaultTestSuite
        suite.run()
        guard let run = suite.testRun, run.executionCount > 0 else {
            print("No widget store tests ran.")
            exit(1)
        }
        print("Executed \(run.executionCount) widget store tests, \(run.failureCount) failures.")
        exit(run.hasSucceeded ? 0 : 1)
    }
}
