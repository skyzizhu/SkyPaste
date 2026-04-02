import Foundation
import SQLite3

enum ClipboardDatabaseError: Error {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class ClipboardDatabase {
    private var db: OpaquePointer?

    init(fileURL: URL) throws {
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
              fingerprint TEXT NOT NULL UNIQUE,
              is_favorite INTEGER NOT NULL DEFAULT 0,
              source_kind INTEGER NOT NULL DEFAULT 0
            );
            """
        )

        // Migration for existing local DBs created before image_name existed.
        _ = try? execute("ALTER TABLE clipboard_items ADD COLUMN image_name TEXT;")
        _ = try? execute("ALTER TABLE clipboard_items ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0;")
        _ = try? execute("ALTER TABLE clipboard_items ADD COLUMN source_kind INTEGER NOT NULL DEFAULT 0;")

        try execute("CREATE INDEX IF NOT EXISTS idx_clipboard_created_at ON clipboard_items(created_at DESC);")
    }

    deinit {
        sqlite3_close(db)
    }

    func loadRecent(limit: Int) throws -> [ClipboardItem] {
        var statement: OpaquePointer?
        let sql =
            "SELECT id, created_at, kind, text_value, blob_value, image_name, file_urls_json, fingerprint, is_favorite, source_kind FROM clipboard_items ORDER BY created_at DESC LIMIT ?;"

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ClipboardDatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(limit))

        var result: [ClipboardItem] = []

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
            let source = ClipboardSource(rawValue: Int(sqlite3_column_int(statement, 9))) ?? .local

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
                    content = .fileURLs(Self.decodeURLs(from: json))
                } else {
                    content = nil
                }

            default:
                content = nil
            }

            if let content {
                result.append(ClipboardItem(id: id, createdAt: createdAt, content: content, fingerprint: fingerprint, source: source, isFavorite: isFavorite))
            }
        }

        return result
    }

    func loadItem(id: UUID) throws -> ClipboardItem? {
        var statement: OpaquePointer?
        let sql =
            "SELECT id, created_at, kind, text_value, blob_value, image_name, file_urls_json, fingerprint, is_favorite, source_kind FROM clipboard_items WHERE id = ? LIMIT 1;"

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
        let source = ClipboardSource(rawValue: Int(sqlite3_column_int(statement, 9))) ?? .local

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
                content = .fileURLs(Self.decodeURLs(from: json))
            } else {
                content = nil
            }
        default:
            content = nil
        }

        guard let content else { return nil }
        return ClipboardItem(id: resolvedID, createdAt: createdAt, content: content, fingerprint: fingerprint, source: source, isFavorite: isFavorite)
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
            "INSERT INTO clipboard_items (id, created_at, kind, text_value, blob_value, image_name, file_urls_json, fingerprint, is_favorite, source_kind) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);"

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

        case .fileURLs(let urls):
            sqlite3_bind_int(statement, 3, 2)
            sqlite3_bind_null(statement, 4)
            sqlite3_bind_null(statement, 5)
            sqlite3_bind_null(statement, 6)
            bindText(Self.encodeURLs(urls), statement: statement, index: 7)
        }

        bindText(item.fingerprint, statement: statement, index: 8)
        sqlite3_bind_int(statement, 9, item.isFavorite ? 1 : 0)
        sqlite3_bind_int(statement, 10, Int32(item.source.rawValue))

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ClipboardDatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func trim(maxItems: Int) throws {
        var statement: OpaquePointer?
        let sql =
            "DELETE FROM clipboard_items WHERE id NOT IN (SELECT id FROM clipboard_items ORDER BY created_at DESC LIMIT ?);"

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
}
