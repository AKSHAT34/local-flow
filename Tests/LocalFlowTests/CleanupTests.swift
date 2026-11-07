import XCTest
@testable import LocalFlowCore

final class CleanupTests: XCTestCase {
    private let cleaner = RuleCleaner()

    func testStripsFillersAndRepeats() {
        let out = cleaner.clean("um hello uh world world", context: CleanupContext())
        XCTAssertFalse(out.lowercased().contains("um"))
        XCTAssertFalse(out.lowercased().contains("uh"))
        XCTAssertEqual(out.lowercased().components(separatedBy: "world").count - 1, 1)
    }

    func testSpokenCommandsAndPunctuation() {
        let out = cleaner.clean("hello comma world period new line next", context: CleanupContext())
        XCTAssertTrue(out.contains("Hello, world."))
        XCTAssertTrue(out.contains("\nnext") || out.contains("Next"))
    }

    func testBacktrackShortToken() {
        let out = cleaner.clean("meet at 3, actually 4 pm", context: CleanupContext())
        XCTAssertTrue(out.contains("4 pm") || out.contains("4 PM") || out.contains("4 p.m."))
        XCTAssertFalse(out.contains("3,"))
    }

    func testNumbersAndPercent() {
        let out = cleaner.clean("we grew twenty five percent", context: CleanupContext())
        XCTAssertTrue(out.contains("25%"))
    }

    func testSnippetExpansion() {
        let context = CleanupContext(snippets: ["my email": "aki@example.com"])
        XCTAssertEqual(cleaner.clean("my email", context: context), "aki@example.com")
    }

    func testLiteralModePreservesText() {
        let context = CleanupContext(literalMode: true)
        let out = cleaner.clean("print hello world", context: context)
        XCTAssertEqual(out, "print hello world")
    }
}
