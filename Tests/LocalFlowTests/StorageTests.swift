import XCTest
@testable import LocalFlowCore

final class StorageTests: XCTestCase {
    func testHistoryAndVocabularyRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try HistoryStore(directory: dir)
        let entry = HistoryEntry(appName: "Notes", bundleID: "com.apple.Notes", rawText: "um hi", cleanText: "Hi.", engine: "appleSpeech", cleanupMode: "rulesOnly", durationMilliseconds: 1234)
        _ = try await store.insertHistory(entry)
        let history = try await store.recentHistory(limit: 10)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.cleanText, "Hi.")

        try await store.upsertDictionary(VocabularyItem(term: "acme", replacement: "ACME"))
        XCTAssertEqual(try await store.loadDictionary()["acme"], "ACME")

        try await store.upsertSnippet(VocabularyItem(term: "my email", replacement: "a@b.com"))
        XCTAssertEqual(try await store.loadSnippets()["my email"], "a@b.com")

        try await store.deleteHistory(olderThanDays: 0)
        XCTAssertTrue(try await store.recentHistory().isEmpty)
    }
}
