// Serializes SQLite access and indexes Chinese text with unicode61-compatible character boundaries.
import Foundation
import SQLite3

extension Notification.Name { static let captureHistoryChanged = Notification.Name("com.n1ko.niko-shot.history.changed") }

struct HistoryRecord: Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let path: String
    let thumbnail: Data
    let width: Int
    let height: Int
    let appBundleID: String
    let captureKind: String
    var ocrText: String = ""
}

actor HistoryStore {
    // SQLite owns this FULLMUTEX C handle; actor methods serialize reads/writes and deinit closes synchronously.
    nonisolated(unsafe) private let database: OpaquePointer
    private let capturesDirectory: URL
    /// Opens an isolated database with FTS5 and transactional OCR index updates.
    init(url: URL) throws {
        capturesDirectory = url.deletingLastPathComponent().appendingPathComponent("Captures", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }; throw AppError.file("无法打开截图历史数据库。")
        }
        database = connection
        sqlite3_busy_timeout(connection, 3000)
        let sql = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS captures(id TEXT PRIMARY KEY, created_at REAL NOT NULL, path TEXT NOT NULL, thumbnail BLOB NOT NULL, width INTEGER, height INTEGER, app_bundleid TEXT, capture_kind TEXT, ocr_text TEXT NOT NULL DEFAULT '');
        CREATE INDEX IF NOT EXISTS captures_date ON captures(created_at DESC);
        CREATE VIRTUAL TABLE IF NOT EXISTS captures_fts USING fts5(id UNINDEXED, ocr_text, tokenize='unicode61');
        """
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { sqlite3_close(connection); throw AppError.file("历史表或 FTS5 初始化失败。") }
    }
    deinit { sqlite3_close(database) }

    private func statement(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }
    private func failure() -> AppError { .file(String(cString: sqlite3_errmsg(database))) }
    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }
    private func execute(_ statement: OpaquePointer) throws { guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() } }

    /// Inserts a capture; history image files are owned by the app's Application Support directory.
    func insert(_ record: HistoryRecord) throws {
        let stmt = try statement("INSERT INTO captures VALUES(?,?,?,?,?,?,?,?,?)"); defer { sqlite3_finalize(stmt) }
        bind(record.id.uuidString, at: 1, to: stmt); sqlite3_bind_double(stmt, 2, record.createdAt.timeIntervalSince1970)
        bind(record.path, at: 3, to: stmt)
        _ = record.thumbnail.withUnsafeBytes { sqlite3_bind_blob(stmt, 4, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        sqlite3_bind_int64(stmt, 5, Int64(record.width)); sqlite3_bind_int64(stmt, 6, Int64(record.height))
        bind(record.appBundleID, at: 7, to: stmt); bind(record.captureKind, at: 8, to: stmt); bind(record.ocrText, at: 9, to: stmt)
        try execute(stmt)
        if !record.ocrText.isEmpty { try updateOCR(id: record.id, text: record.ocrText) }
    }

    /// Replaces OCR text and its search tokens in one transaction.
    func updateOCR(id: UUID, text: String) throws {
        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw failure() }
        do {
            let update = try statement("UPDATE captures SET ocr_text=? WHERE id=?"); defer { sqlite3_finalize(update) }
            bind(text, at: 1, to: update); bind(id.uuidString, at: 2, to: update); try execute(update)
            let delete = try statement("DELETE FROM captures_fts WHERE id=?"); defer { sqlite3_finalize(delete) }
            bind(id.uuidString, at: 1, to: delete); try execute(delete)
            let insert = try statement("INSERT INTO captures_fts(id,ocr_text) VALUES(?,?)"); defer { sqlite3_finalize(insert) }
            bind(id.uuidString, at: 1, to: insert); bind(Self.searchTokens(text), at: 2, to: insert); try execute(insert)
            guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw failure() }
        } catch { sqlite3_exec(database, "ROLLBACK", nil, nil, nil); throw error }
    }

    /// Paginates newest-first with parameterized FTS searches, including Chinese substrings.
    func list(query: String = "", limit: Int = 50, offset: Int = 0) throws -> [HistoryRecord] {
        let filtering = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let stmt = try statement("SELECT * FROM captures \(filtering ? "WHERE id IN (SELECT id FROM captures_fts WHERE captures_fts MATCH ?)" : "") ORDER BY created_at DESC,id DESC LIMIT ? OFFSET ?")
        defer { sqlite3_finalize(stmt) }
        if filtering { bind("\"" + Self.searchTokens(query).replacingOccurrences(of: "\"", with: "\"\"") + "\"", at: 1, to: stmt) }
        let base: Int32 = filtering ? 2 : 1
        sqlite3_bind_int(stmt, base, Int32(min(200, max(1, limit)))); sqlite3_bind_int64(stmt, base + 1, Int64(max(0, offset)))
        var result: [HistoryRecord] = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw failure() }
            func string(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
            guard let id = UUID(uuidString: string(0)) else { continue }
            let length = Int(sqlite3_column_bytes(stmt, 3))
            let thumbnail = sqlite3_column_blob(stmt, 3).map { Data(bytes: $0, count: length) } ?? Data()
            result.append(HistoryRecord(id: id, createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)), path: string(2), thumbnail: thumbnail, width: Int(sqlite3_column_int64(stmt, 4)), height: Int(sqlite3_column_int64(stmt, 5)), appBundleID: string(6), captureKind: string(7), ocrText: string(8)))
        }
        return result
    }

    func delete(id: UUID) throws {
        let lookup = try statement("SELECT path FROM captures WHERE id=?")
        bind(id.uuidString, at: 1, to: lookup)
        var path: String?
        if sqlite3_step(lookup) == SQLITE_ROW, let text = sqlite3_column_text(lookup, 0) { path = String(cString: text) }
        sqlite3_finalize(lookup)
        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw failure() }
        do {
            for sql in ["DELETE FROM captures WHERE id=?", "DELETE FROM captures_fts WHERE id=?"] {
                let stmt = try statement(sql); defer { sqlite3_finalize(stmt) }
                bind(id.uuidString, at: 1, to: stmt); try execute(stmt)
            }
            guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw failure() }
        } catch { sqlite3_exec(database, "ROLLBACK", nil, nil, nil); throw error }
        if let path, URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(capturesDirectory.path + "/") { try? FileManager.default.removeItem(atPath: path) }
    }
    /// Removes expired app-owned capture records and files on demand rather than using a resident timer.
    func prune(days: Int) throws {
        guard days > 0 else { return }
        let cutoff = Date.now.addingTimeInterval(-Double(days) * 86400)
        let stmt = try statement("SELECT id,path FROM captures WHERE created_at < ?"); defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, cutoff.timeIntervalSince1970)
        var expired: [(UUID, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let raw = sqlite3_column_text(stmt, 0), let id = UUID(uuidString: String(cString: raw)), let path = sqlite3_column_text(stmt, 1) { expired.append((id, String(cString: path))) }
        }
        for (id, _) in expired { try delete(id: id) }
    }
    nonisolated static func searchTokens(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            if (0x3400...0x9fff).contains(scalar.value) || (0x20000...0x3134f).contains(scalar.value) { result += " " + String(scalar) + " " }
            else { result.unicodeScalars.append(scalar) }
        }
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
