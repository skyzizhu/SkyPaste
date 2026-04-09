import CloudKit
import Foundation
import Security

enum SkyCloudClipboardSchema {
    static let containerIdentifier = "iCloud.com.huaibor.skypaste"
    static let recordType = "SkyClipboardItem"

    enum Field {
        static let contentType = "contentType"
        static let text = "text"
        static let fingerprint = "fingerprint"
        static let createdAt = "createdAt"
        static let sourceDevice = "sourceDevice"
    }

    enum ContentType {
        static let text = "text"
    }
}

@MainActor
final class CloudClipboardSyncManager {
    private let store: ClipboardStore
    private let settings: AppSettings
    private var database: CKDatabase?
    private var timer: Timer?
    private var isFetching = false

    init(store: ClipboardStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    func applyCurrentSetting() {
        settings.iCloudSyncEnabled ? start() : stop()
    }

    func start() {
        stop()

        guard ensureCloudKitAvailability() else {
            return
        }

        fetchNow()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.fetchNow()
            }
        }

        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isFetching = false
    }

    func fetchNow() {
        guard settings.iCloudSyncEnabled, !isFetching, let database else { return }
        isFetching = true

        let query = CKQuery(recordType: SkyCloudClipboardSchema.recordType, predicate: NSPredicate(value: true))
        let operation = CKQueryOperation(query: query)
        operation.desiredKeys = [
            SkyCloudClipboardSchema.Field.contentType,
            SkyCloudClipboardSchema.Field.text,
            SkyCloudClipboardSchema.Field.fingerprint,
            SkyCloudClipboardSchema.Field.createdAt,
            SkyCloudClipboardSchema.Field.sourceDevice
        ]
        operation.resultsLimit = 100

        operation.recordMatchedBlock = { [weak self] _, result in
            guard case .success(let record) = result else { return }
            Task { @MainActor in
                self?.ingest(record)
            }
        }

        operation.queryResultBlock = { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isFetching = false
                if case .success(let cursor?) = result {
                    self.fetch(cursor: cursor)
                }
            }
        }

        database.add(operation)
    }

    private func fetch(cursor: CKQueryOperation.Cursor) {
        guard settings.iCloudSyncEnabled, !isFetching, let database else { return }
        isFetching = true

        let operation = CKQueryOperation(cursor: cursor)
        operation.desiredKeys = [
            SkyCloudClipboardSchema.Field.contentType,
            SkyCloudClipboardSchema.Field.text,
            SkyCloudClipboardSchema.Field.fingerprint,
            SkyCloudClipboardSchema.Field.createdAt,
            SkyCloudClipboardSchema.Field.sourceDevice
        ]
        operation.resultsLimit = 100

        operation.recordMatchedBlock = { [weak self] _, result in
            guard case .success(let record) = result else { return }
            Task { @MainActor in
                self?.ingest(record)
            }
        }

        operation.queryResultBlock = { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isFetching = false
                if case .success(let nextCursor?) = result {
                    self.fetch(cursor: nextCursor)
                }
            }
        }

        database.add(operation)
    }

    private func ensureCloudKitAvailability() -> Bool {
        if database != nil {
            return true
        }

        guard Self.hasCloudKitEntitlement else {
            print("[CloudClipboardSync] CloudKit entitlement unavailable; iCloud sync disabled for this build.")
            return false
        }

        database = CKContainer(identifier: SkyCloudClipboardSchema.containerIdentifier).privateCloudDatabase
        return true
    }

    private static let hasCloudKitEntitlement: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        guard let rawValue = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) else {
            return false
        }

        if CFGetTypeID(rawValue) == CFArrayGetTypeID(),
           let values = rawValue as? [String] {
            return values.contains("CloudKit") || values.contains("CloudKit-Anonymous")
        }

        return false
    }()

    private func ingest(_ record: CKRecord) {
        guard
            record[SkyCloudClipboardSchema.Field.contentType] as? String == SkyCloudClipboardSchema.ContentType.text,
            let text = record[SkyCloudClipboardSchema.Field.text] as? String
        else {
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let fingerprint = record[SkyCloudClipboardSchema.Field.fingerprint] as? String ?? "txt:\(trimmed)"
        let createdAt = record[SkyCloudClipboardSchema.Field.createdAt] as? Date ?? record.creationDate ?? Date()
        let item = ClipboardItem(
            id: UUID(),
            createdAt: createdAt,
            content: .text(trimmed),
            fingerprint: fingerprint,
            source: .cloudKit
        )
        store.addCloudSyncedItem(item)
    }
}
