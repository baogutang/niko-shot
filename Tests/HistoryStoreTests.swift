// Exercises an isolated real SQLite/FTS5 database, Chinese substring search, updates and pagination.
import XCTest
@testable import NikoShot

final class HistoryStoreTests: XCTestCase {
    func testLastOCRSurvivesReopeningAndSkipsNewUnrecognizedCaptures() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = folder.appendingPathComponent("history.sqlite")
        let first = try HistoryStore(url: database)
        let empty = try await first.lastOCRText()
        XCTAssertEqual(empty, "")
        for index in 0..<3 {
            try await first.insert(HistoryRecord(id: UUID(), createdAt: Date(timeIntervalSince1970: Double(index)),
                path: "", thumbnail: Data(repeating: 9, count: 1024), width: 40, height: 20,
                appBundleID: "test", captureKind: "region", ocrText: index == 2 ? "" : "结果 \(index)"))
        }
        let reopened = try HistoryStore(url: database)
        let text = try await reopened.lastOCRText()
        XCTAssertEqual(text, "结果 1")
    }

    func testChineseSearchAndPagination() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try HistoryStore(url: folder.appendingPathComponent("history.sqlite"))
        var ids: [UUID] = []
        for index in 0..<6 {
            let id = UUID(); ids.append(id)
            try await store.insert(HistoryRecord(id: id, createdAt: Date(timeIntervalSince1970: Double(index)), path: "", thumbnail: Data([1]), width: 40, height: 20, appBundleID: "test", captureKind: "region"))
        }
        try await store.updateOCR(id: ids[0], text: "这是中文银行卡截图 English")
        let chinese = try await store.list(query: "银行卡")
        XCTAssertEqual(chinese.map(\.id), [ids[0]])
        let english = try await store.list(query: "English")
        XCTAssertEqual(english.count, 1)
        let first = try await store.list(limit: 2), second = try await store.list(limit: 2, offset: 2)
        XCTAssertEqual(first.map(\.id), [ids[5], ids[4]]); XCTAssertEqual(second.map(\.id), [ids[3], ids[2]])
        try await store.updateOCR(id: ids[0], text: "新结果")
        let old = try await store.list(query: "银行卡"); XCTAssertTrue(old.isEmpty)
        try await store.delete(id: ids[0])
        let new = try await store.list(query: "新结果"); XCTAssertTrue(new.isEmpty)
    }
}
