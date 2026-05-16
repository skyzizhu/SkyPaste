import Foundation
import SQLite3

enum ClipboardDatabaseError: Error {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case corruptionDetected(String)
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class ClipboardDatabase {
    private var db: OpaquePointer?
    let fileURL: URL

    init(fileURL: URL) throws {
        self.fileURL = fileURL

        if sqlite3_open(fileURL.path, &db) != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(db))
            throw ClipboardDatabaseError.openFailed(message)
        }

        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = NORMAL;")
        try execute(
            """
            CREATE TABLE IF NOT EXISTS clipboard_items (
              id TEXT PRIMARY KEY,
              created_at REAL NOT NULL,
              kind INTEGER NOT NULL,
              text_value TEXT,
              blob_value BLOB,
              image_name TEXT,
              file_urls_json TEXT,
              pasteboard_payload BLOB,
              fingerprint TEXT NOT NULL UNIQUE,
              is_favorite INTEGER NOT NULL DEFAULT 0,
              is_snippet INTEGER NOT NULL DEFAULT 0,
              source_kind INTEGER NOT NULL DEFAULT 0
            );
            """
        )

        try migrateSchemaIfNeeded()

        try execute("CREATE INDEX IF NOT EXISTS idx_clipboard_created_at ON clipboard_items(created_at DESC);")
        try validateIntegrity()
    }

    deinit {
        sqlite3_close(db)
    }

    func loadRecent(limit: Int) throws -> [ClipboardItem] {
        guard limit > 0 else { return [] }

        var statement: OpaquePointer?
        let sql =
            "SELECT id, created_at, kind, text_value, blob_value, image_name, file_urls_json, fingerprint, is_favorite, is_snippet, source_kind, pasteboard_payload FROM clipboard_items ORDER BY created_at DESC LIMIT ?;"

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ClipboardDatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(limit))

        var result: [ClipboardItem] = []
        result.reserveCapacity(limit)

        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idC = sqlite3_column_text(statement, 0),
                let id = UUID(uuidString: String(cString: idC)),
                let fingerprintC = sqlite3_column_text(statement, 7)
            else {
                continue
            }

            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            let kind = sqlite3_column_int(statement, 2)
            let fingerprint = String(cString: fingerprintC)
            let isFavorite = sqlite3_column_int(statement, 8) != 0
            let source = ClipboardSource(rawValue: Int(sqlite3_column_int(statement, 10))) ?? .local

            let content: ClipboardContent?
            switch kind {
            case 0:
                if let textC = sqlite3_column_text(statement, 3) {
                    content = .text(String(cString: textC))
                } else {
                    content = nil
                }

            case 1:
                if let bytes = sqlite3_column_blob(statement, 4) {
                    let count = Int(sqlite3_column_bytes(statement, 4))
                    let name = sqlite3_column_text(statement, 5).map { String(cString: $0) }
                    let data = Data(bytes: bytes, count: count)
                    content = .image(data: data, name: name, originalByteCount: data.count, previewOnly: false)
                } else {
                    content = nil
                }

            case 2:
                if let jsonC = sqlite3_column_text(statement, 6) {
                    let json = String(cString: jsonC)
                    let payload = Self.decodePasteboardPayload(from: statement, column: 11)
                    content = .fileURLs(urls: Self.decodeURLs(from: json), pasteboardPayload: payload)
                } else {
                    content = nil
                }

            default:
                content = nil
            }

            if let content {
                result.append(ClipboardItem(id: id, createdAt: createdAt, content: content, fingerprint: fingerprint, source: source, isFavorite: isFavorite, isSnippet: false))
            }
        }

        return result
    }

    func loadItem(id: UUID) throws -> ClipboardItem? {
        var statement: OpaquePointer?
        let sql =
            "SELECT id, created_at, kind, text_value, blob_value, image_name, file_urls_json, fingerprint, is_favorite, is_snippet, source_kind, pasteboard_payload FROM clipboard_items WHERE id = ? LIMIT 1;"

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ClipboardDatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        bindText(id.uuidString, statement: statement, index: 1)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        guard
            let idC = sqlite3_column_text(statement, 0),
            let resolvedID = UUID(uuidString: String(cString: idC)),
            let fingerprintC = sqlite3_column_text(statement, 7)
        else {
            return nil
        }

        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
        let kind = sqlite3_column_int(statement, 2)
        let fingerprint = String(cString: fingerprintC)
        let isFavorite = sqlite3_column_int(statement, 8) != 0
        let source = ClipboardSource(rawValue: Int(sqlite3_column_int(statement, 10))) ?? .local

        let content: ClipboardContent?
        switch kind {
        case 0:
            if let textC = sqlite3_column_text(statement, 3) {
                content = .text(String(cString: textC))
            } else {
                content = nil
            }
        case 1:
            if let bytes = sqlite3_column_blob(statement, 4) {
                let count = Int(sqlite3_column_bytes(statement, 4))
                let data = Data(bytes: bytes, count: count)
                let name = sqlite3_column_text(statement, 5).map { String(cString: $0) }
                content = .image(data: data, name: name, originalByteCount: data.count, previewOnly: false)
            } else {
                content = nil
            }
        case 2:
            if let jsonC = sqlite3_column_text(statement, 6) {
                let json = String(cString: jsonC)
                let payload = Self.decodePasteboardPayload(from: statement, column: 11)
                content = .fileURLs(urls: Self.decodeURLs(from: json), pasteboardPayload: payload)
            } else {
                content = nil
            }
        default:
            content = nil
        }

        guard let content else { return nil }
        return ClipboardItem(id: resolvedID, createdAt: createdAt, content: content, fingerprint: fingerprint, source: source, isFavorite: isFavorite, isSnippet: false)
    }

    func save(_ item: ClipboardItem, maxItems: Int) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")

        do {
            try removeByFingerprint(item.fingerprint)
            try insert(item)
            try trim(maxItems: maxItems)
            try execute("COMMIT;")
        } catch {
            _ = try? execute("ROLLBACK;")
            throw error
        }
    }

    func trimToLimit(_ maxItems: Int) throws {
        try trim(maxItems: maxItems)
    }

    func deleteCreatedAtRange(from: Date, to: Date) throws {
        var statement: OpaquePointer?
        let sql = "DELETE FROM clipboard_items WHERE created_at >= ? AND created_at < ?;"

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ClipboardDatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, from.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, to.timeIntervalSince1970)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ClipboardDatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    func deleteItem(id: UUID) throws {
        var statement: OpaquePointer?
        let sql = "DELETE FROM clipboard_items WHERE id = ?;"

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ClipboardDatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        bindText(id.uuidString, statement: statement, index: 1)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ClipboardDatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    func favoriteState(forFingerprint fingerprint: String) throws -> Bool? {
        var statement: OpaquePointer?
        let sql = "SELECT is_favorite FROM clipboard_items WHERE fingerprint = ? LIMIT 1;"

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ClipboardDatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        bindText(fingerprint, statement: statement, index: 1)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return sqlite3_column_int(statement, 0) != 0
        case SQLITE_DONE:
            return nil
        default:
            throw ClipboardDatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    func setFavorite(_ isFavorite: Bool, forID id: UUID) throws {
        var statement: OpaquePointer?
        let sql = "UPDATE clipboard_items SET is_favorite = ? WHERE id = ?;"

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ClipboardDatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, isFavorite ? 1 : 0)
        bindText(id.uuidString, statement: statement, index: 2)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ClipboardDatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func removeByFingerprint(_ fingerprint: String) throws {
        var statement: OpaquePointer?
        let sql = "DELETE FROM clipboard_items WHERE fingerprint = ?;"

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ClipboardDatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        bindText(fingerprint, statement: statement, index: 1)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ClipboardDatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func insert(_ item: ClipboardItem) throws {
        var statement: OpaquePointer?
        let sql =
            "INSERT INTO clipboard_items (id, created_at, kind, text_value, blob_value, image_name, file_urls_json, fingerprint, is_favorite, is_snippet, source_kind, pasteboard_payload) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);"

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ClipboardDatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        bindText(item.id.uuidString, statement: statement, index: 1)
        sqlite3_bind_double(statement, 2, item.createdAt.timeIntervalSince1970)

        switch item.content {
        case .text(let value):
            sqlite3_bind_int(statement, 3, 0)
            bindText(value, statement: statement, index: 4)
            sqlite3_bind_null(statement, 5)
            sqlite3_bind_null(statement, 6)
            sqlite3_bind_null(statement, 7)
            sqlite3_bind_null(statement, 12)

        case .image(let data, let name, _, _):
            sqlite3_bind_int(statement, 3, 1)
            sqlite3_bind_null(statement, 4)
            if data.isEmpty {
                sqlite3_bind_null(statement, 5)
            } else {
                data.withUnsafeBytes { rawBuffer in
                    if let baseAddress = rawBuffer.baseAddress {
                        sqlite3_bind_blob(statement, 5, baseAddress, Int32(data.count), sqliteTransient)
                    }
                }
            }

            if let name, !name.isEmpty {
                bindText(name, statement: statement, index: 6)
            } else {
                sqlite3_bind_null(statement, 6)
            }
            sqlite3_bind_null(statement, 7)
            sqlite3_bind_null(statement, 12)

        case .fileURLs(let urls, let pasteboardPayload):
            sqlite3_bind_int(statement, 3, 2)
            sqlite3_bind_null(statement, 4)
            sqlite3_bind_null(statement, 5)
            sqlite3_bind_null(statement, 6)
            bindText(Self.encodeURLs(urls), statement: statement, index: 7)
            Self.bindData(Self.encodePasteboardPayload(pasteboardPayload), statement: statement, index: 12)
        }

        bindText(item.fingerprint, statement: statement, index: 8)
        sqlite3_bind_int(statement, 9, item.isFavorite ? 1 : 0)
        sqlite3_bind_int(statement, 10, 0)
        sqlite3_bind_int(statement, 11, Int32(item.source.rawValue))

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ClipboardDatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func trim(maxItems: Int) throws {
        var statement: OpaquePointer?
        let sql =
            """
            DELETE FROM clipboard_items
            WHERE id NOT IN (
              SELECT id FROM clipboard_items
              ORDER BY created_at DESC
              LIMIT ?
            );
            """

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ClipboardDatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(maxItems))

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ClipboardDatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw ClipboardDatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    func clearAllSnippets() throws {
        try execute("UPDATE clipboard_items SET is_snippet = 0 WHERE is_snippet != 0;")
    }

    private func migrateSchemaIfNeeded() throws {
        if !hasColumn(named: "image_name") {
            try execute("ALTER TABLE clipboard_items ADD COLUMN image_name TEXT;")
        }

        if !hasColumn(named: "is_favorite") {
            try execute("ALTER TABLE clipboard_items ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0;")
        }

        if !hasColumn(named: "is_snippet") {
            try execute("ALTER TABLE clipboard_items ADD COLUMN is_snippet INTEGER NOT NULL DEFAULT 0;")
        }

        if !hasColumn(named: "source_kind") {
            try execute("ALTER TABLE clipboard_items ADD COLUMN source_kind INTEGER NOT NULL DEFAULT 0;")
        }

        if !hasColumn(named: "pasteboard_payload") {
            try execute("ALTER TABLE clipboard_items ADD COLUMN pasteboard_payload BLOB;")
        }
    }

    private func hasColumn(named columnName: String) -> Bool {
        var statement: OpaquePointer?
        let sql = "PRAGMA table_info(clipboard_items);"

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 1) else { continue }
            if String(cString: name) == columnName {
                return true
            }
        }

        return false
    }

    private func validateIntegrity() throws {
        var statement: OpaquePointer?
        let sql = "PRAGMA quick_check(1);"

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            if Self.looksLikeCorruption(message) {
                throw ClipboardDatabaseError.corruptionDetected(message)
            }
            throw ClipboardDatabaseError.prepareFailed(message)
        }
        defer { sqlite3_finalize(statement) }

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            if let result = sqlite3_column_text(statement, 0) {
                let text = String(cString: result)
                guard text == "ok" else {
                    throw ClipboardDatabaseError.corruptionDetected(text)
                }
            } else {
                throw ClipboardDatabaseError.corruptionDetected("quick_check returned no result")
            }
        case SQLITE_DONE:
            throw ClipboardDatabaseError.corruptionDetected("quick_check returned no rows")
        default:
            let message = String(cString: sqlite3_errmsg(db))
            if Self.looksLikeCorruption(message) {
                throw ClipboardDatabaseError.corruptionDetected(message)
            }
            throw ClipboardDatabaseError.stepFailed(message)
        }
    }

    private func bindText(_ value: String, statement: OpaquePointer?, index: Int32) {
        _ = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, sqliteTransient)
        }
    }

    private static func encodeURLs(_ urls: [URL]) -> String {
        let values = urls.map(\.absoluteString)
        let data = try? JSONSerialization.data(withJSONObject: values)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    private static func decodeURLs(from json: String) -> [URL] {
        guard
            let data = json.data(using: .utf8),
            let values = try? JSONSerialization.jsonObject(with: data) as? [String]
        else {
            return []
        }

        return values.compactMap(URL.init(string:))
    }

    private static func bindData(_ data: Data?, statement: OpaquePointer?, index: Int32) {
        guard let data, !data.isEmpty else {
            sqlite3_bind_null(statement, index)
            return
        }

        data.withUnsafeBytes { rawBuffer in
            if let baseAddress = rawBuffer.baseAddress {
                sqlite3_bind_blob(statement, index, baseAddress, Int32(data.count), sqliteTransient)
            }
        }
    }

    private static func encodePasteboardPayload(_ payload: ClipboardFilePasteboardPayload?) -> Data? {
        guard let payload, payload.hasEntries else { return nil }
        return try? JSONEncoder().encode(payload)
    }

    private static func decodePasteboardPayload(from statement: OpaquePointer?, column: Int32) -> ClipboardFilePasteboardPayload? {
        guard
            let bytes = sqlite3_column_blob(statement, column)
        else {
            return nil
        }

        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0 else { return nil }
        let data = Data(bytes: bytes, count: count)
        return try? JSONDecoder().decode(ClipboardFilePasteboardPayload.self, from: data)
    }

    static func looksLikeCorruption(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("database disk image is malformed") ||
            lowered.contains("database corruption") ||
            lowered.contains("malformed") ||
            lowered.contains("not a database") ||
            lowered.contains("file is not a database") ||
            lowered.contains("corrupt")
    }
}
