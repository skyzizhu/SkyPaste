import Foundation
import SQLite3

enum ClipboardStatisticsCategory: Int, CaseIterable, Identifiable, Sendable {
    case text
    case image
    case file
    case folder
    case code
    case url
    case email

    var id: Int { rawValue }

    var filter: ClipboardFilter {
        switch self {
        case .text: .text
        case .image: .image
        case .file: .file
        case .folder: .folder
        case .code: .code
        case .url: .url
        case .email: .email
        }
    }

    init(item: ClipboardItem) {
        if item.containsFiles {
            self = .file
        } else if item.containsFolders {
            self = .folder
        } else if item.isImage {
            self = .image
        } else if item.isEmail {
            self = .email
        } else if item.isURL {
            self = .url
        } else if item.isCode {
            self = .code
        } else {
            self = .text
        }
    }
}

struct ClipboardStatisticsEntry: Sendable {
    let bucket: Date
    let category: ClipboardStatisticsCategory
    let count: Int
}

struct ClipboardStatisticsAppEntry: Sendable {
    let bundleID: String
    let name: String
    let count: Int
}

final class ClipboardStatisticsStore {
    private var db: OpaquePointer?

    init(fileURL: URL, readOnly: Bool = false) throws {
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(fileURL.path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            sqlite3_close(db)
            throw ClipboardDatabaseError.openFailed(message)
        }

        if readOnly { return }

        do {
            try execute("PRAGMA journal_mode = WAL;")
            try execute("PRAGMA synchronous = NORMAL;")
            try execute("CREATE TABLE IF NOT EXISTS daily_counts (bucket INTEGER NOT NULL, category INTEGER NOT NULL, count INTEGER NOT NULL, PRIMARY KEY (bucket, category));")
            try execute("CREATE TABLE IF NOT EXISTS hourly_counts (bucket INTEGER NOT NULL, category INTEGER NOT NULL, count INTEGER NOT NULL, PRIMARY KEY (bucket, category));")
            try execute("CREATE TABLE IF NOT EXISTS daily_app_counts (bucket INTEGER NOT NULL, bundle_id TEXT NOT NULL, name TEXT NOT NULL, count INTEGER NOT NULL, PRIMARY KEY (bucket, bundle_id));")
            try execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
        } catch {
            sqlite3_close(db)
            db = nil
            throw error
        }
    }

    deinit {
        sqlite3_close(db)
    }

    func seedRetainedHistoryIfNeeded(_ items: [ClipboardItem], calendar: Calendar = .current) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            if try !hasCompletedSeed("history_app_seed_v1") {
                let firstAppDay = try earliestRecordedDay(in: "daily_app_counts")
                for item in items {
                    guard let sourceApp = item.sourceApp else { continue }
                    let day = Int(calendar.startOfDay(for: item.createdAt).timeIntervalSince1970)
                    guard firstAppDay.map({ day < $0 }) ?? true else { continue }
                    try incrementApp(bucket: day, sourceApp: sourceApp)
                }
                try execute("INSERT INTO metadata (key, value) VALUES ('history_app_seed_v1', '1');")
            }
            guard try !hasCompletedHistorySeed() else {
                try execute("COMMIT;")
                return
            }

            // Existing statistics may already contain recent copies. Only older days can be
            // backfilled safely without counting those copies twice.
            let firstRecordedDay = try earliestRecordedDay()
            let hourlyCutoff = Int(Date().timeIntervalSince1970) - 72 * 3600
            for item in items {
                let day = Int(calendar.startOfDay(for: item.createdAt).timeIntervalSince1970)
                guard firstRecordedDay.map({ day < $0 }) ?? true else { continue }
                let category = ClipboardStatisticsCategory(item: item)
                try increment(table: "daily_counts", bucket: day, category: category)
                let hour = Int((calendar.dateInterval(of: .hour, for: item.createdAt)?.start ?? item.createdAt).timeIntervalSince1970)
                if hour >= hourlyCutoff {
                    try increment(table: "hourly_counts", bucket: hour, category: category)
                }
            }

            try execute("INSERT INTO metadata (key, value) VALUES ('history_seed_v1', '1');")
            try execute("COMMIT;")
        } catch {
            _ = try? execute("ROLLBACK;")
            throw error
        }
    }

    func record(_ item: ClipboardItem, calendar: Calendar = .current) throws {
        let category = ClipboardStatisticsCategory(item: item)
        let day = Int(calendar.startOfDay(for: item.createdAt).timeIntervalSince1970)
        let hour = Int((calendar.dateInterval(of: .hour, for: item.createdAt)?.start ?? item.createdAt).timeIntervalSince1970)
        let hourlyCutoff = Int(Date().timeIntervalSince1970) - 72 * 3600

        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try increment(table: "daily_counts", bucket: day, category: category)
            if let sourceApp = item.sourceApp {
                try incrementApp(bucket: day, sourceApp: sourceApp)
            }
            if hour >= hourlyCutoff {
                try increment(table: "hourly_counts", bucket: hour, category: category)
            }
            // Hourly detail is only needed for the today view.
            try execute("DELETE FROM hourly_counts WHERE bucket < \(hourlyCutoff);")
            try execute("COMMIT;")
        } catch {
            _ = try? execute("ROLLBACK;")
            throw error
        }
    }

    func dailyEntries(from start: Date, to end: Date) throws -> [ClipboardStatisticsEntry] {
        try entries(in: "daily_counts", from: start, to: end)
    }

    func hourlyEntries(from start: Date, to end: Date) throws -> [ClipboardStatisticsEntry] {
        try entries(in: "hourly_counts", from: start, to: end)
    }

    func appEntries(from start: Date, to end: Date) throws -> [ClipboardStatisticsAppEntry] {
        let sql = """
            SELECT bundle_id, MAX(name), SUM(count) FROM daily_app_counts
            WHERE bucket >= ? AND bucket < ? GROUP BY bundle_id ORDER BY SUM(count) DESC, bundle_id;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(start.timeIntervalSince1970))
        sqlite3_bind_int64(statement, 2, Int64(end.timeIntervalSince1970))

        var result: [ClipboardStatisticsAppEntry] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let bundleID = sqlite3_column_text(statement, 0), let name = sqlite3_column_text(statement, 1) else { continue }
                result.append(ClipboardStatisticsAppEntry(
                    bundleID: String(cString: bundleID),
                    name: String(cString: name),
                    count: Int(sqlite3_column_int64(statement, 2))
                ))
            case SQLITE_DONE: return result
            default: throw databaseError()
            }
        }
    }

    private func hasCompletedHistorySeed() throws -> Bool {
        try hasCompletedSeed("history_seed_v1")
    }

    private func hasCompletedSeed(_ key: String) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM metadata WHERE key = ? LIMIT 1;", -1, &statement, nil) == SQLITE_OK else {
            throw databaseError()
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = key.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw databaseError()
        }
    }

    private func earliestRecordedDay() throws -> Int? {
        try earliestRecordedDay(in: "daily_counts")
    }

    private func earliestRecordedDay(in table: String) throws -> Int? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MIN(bucket) FROM \(table);", -1, &statement, nil) == SQLITE_OK else {
            throw databaseError()
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError() }
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func increment(table: String, bucket: Int, category: ClipboardStatisticsCategory) throws {
        let sql = "INSERT INTO \(table) (bucket, category, count) VALUES (?, ?, 1) ON CONFLICT(bucket, category) DO UPDATE SET count = count + 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError()
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(bucket))
        sqlite3_bind_int(statement, 2, Int32(category.rawValue))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func incrementApp(bucket: Int, sourceApp: ClipboardSourceApp) throws {
        let sql = """
            INSERT INTO daily_app_counts (bucket, bundle_id, name, count) VALUES (?, ?, ?, 1)
            ON CONFLICT(bucket, bundle_id) DO UPDATE SET name = excluded.name, count = count + 1;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(bucket))
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = sourceApp.bundleID.withCString { sqlite3_bind_text(statement, 2, $0, -1, transient) }
        _ = sourceApp.name.withCString { sqlite3_bind_text(statement, 3, $0, -1, transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func entries(in table: String, from start: Date, to end: Date) throws -> [ClipboardStatisticsEntry] {
        let sql = "SELECT bucket, category, count FROM \(table) WHERE bucket >= ? AND bucket < ? ORDER BY bucket;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError()
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(start.timeIntervalSince1970))
        sqlite3_bind_int64(statement, 2, Int64(end.timeIntervalSince1970))

        var result: [ClipboardStatisticsEntry] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let category = ClipboardStatisticsCategory(rawValue: Int(sqlite3_column_int(statement, 1))) else { continue }
                result.append(ClipboardStatisticsEntry(
                    bucket: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0))),
                    category: category,
                    count: Int(sqlite3_column_int(statement, 2))
                ))
            case SQLITE_DONE:
                return result
            default:
                throw databaseError()
            }
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw databaseError() }
    }

    private func databaseError() -> ClipboardDatabaseError {
        ClipboardDatabaseError.stepFailed(db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error")
    }
}
