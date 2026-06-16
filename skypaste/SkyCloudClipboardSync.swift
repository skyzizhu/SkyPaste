import CryptoKit
import CloudKit
import Combine
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

    static func recordName(for fingerprint: String) -> String {
        let digest = SHA256.hash(data: Data(fingerprint.utf8))
        return "clip-" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum CloudClipboardSyncPolicy {
    static func shouldUpload(_ item: ClipboardItem) -> Bool {
        guard item.source == .local else { return false }
        guard case .text(let value) = item.content else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func backfillUploadCandidates(from items: [ClipboardItem]) -> [ClipboardItem] {
        items
            .filter(shouldUpload)
            .sorted { $0.createdAt < $1.createdAt }
    }

    static func missingUploadCandidates(
        from items: [ClipboardItem],
        existingRecordNames: Set<String>
    ) -> [ClipboardItem] {
        backfillUploadCandidates(from: items).filter { item in
            !existingRecordNames.contains(SkyCloudClipboardSchema.recordName(for: item.fingerprint))
        }
    }

    static func shouldApplyIncoming(_ incoming: ClipboardItem, over existing: ClipboardItem?) -> Bool {
        guard let existing else { return true }
        return incoming.createdAt > existing.createdAt
    }

    static func updatedFetchSessionCursor(current: Date?, ingesting createdAt: Date) -> Date {
        max(current ?? createdAt, createdAt)
    }

    static func finalizedFetchCursor(previous: Date?, fetchedMax: Date?) -> Date? {
        guard let fetchedMax else { return previous }
        guard let previous else { return fetchedMax }
        return max(previous, fetchedMax)
    }
}

enum CloudClipboardSyncStatus: Equatable {
    case disabled
    case unavailable
    case syncing
    case synced(Date)
    case error(String)
}

@MainActor
final class CloudClipboardSyncManager: ObservableObject {
    @Published private(set) var status: CloudClipboardSyncStatus = .disabled

    private let store: ClipboardStore
    private let settings: AppSettings
    private var database: CKDatabase?
    private var timer: Timer?
    private var isFetching = false
    private var pendingUploadFingerprints = Set<String>()
    private var lastFetchedCreatedAt: Date?
    private var fetchSessionMaxCreatedAt: Date?
    private var activeFetchOperation: CKQueryOperation?
    private var activeUploadOperations: [String: CKModifyRecordsOperation] = [:]
    private var activeBackfillTask: Task<Void, Never>?
    private var syncSessionID = UUID()
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let lastFetchedCreatedAt = "cloudSync.lastFetchedCreatedAt"
    }

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
            status = .unavailable
            return
        }

        status = .syncing
        lastFetchedCreatedAt = persistedFetchCursor

        if settings.iCloudSyncUploadEnabled {
            activeBackfillTask = Task { [weak self] in
                await self?.backfillExistingLocalItems()
            }
        }

        if settings.iCloudSyncReceiveEnabled {
            fetchNow()
            timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.fetchNow()
                }
            }
        } else {
            markSynced()
        }

        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stop() {
        syncSessionID = UUID()
        timer?.invalidate()
        timer = nil
        activeBackfillTask?.cancel()
        activeBackfillTask = nil
        activeFetchOperation?.cancel()
        activeFetchOperation = nil
        activeUploadOperations.values.forEach { $0.cancel() }
        activeUploadOperations.removeAll()
        isFetching = false
        pendingUploadFingerprints.removeAll()
        lastFetchedCreatedAt = nil
        fetchSessionMaxCreatedAt = nil
        status = .disabled
    }

    func uploadLocalItemIfNeeded(_ item: ClipboardItem) {
        guard settings.iCloudSyncEnabled else { return }
        guard settings.iCloudSyncUploadEnabled else { return }
        guard CloudClipboardSyncPolicy.shouldUpload(item) else { return }
        guard ensureCloudKitAvailability(), let database else { return }
        guard pendingUploadFingerprints.insert(item.fingerprint).inserted else { return }
        guard let record = makeRecord(for: item) else {
            pendingUploadFingerprints.remove(item.fingerprint)
            return
        }

        status = .syncing
        let sessionID = syncSessionID
        let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
        operation.savePolicy = .changedKeys
        operation.isAtomic = true
        activeUploadOperations[item.fingerprint] = operation

        Task { [weak self, database, operation] in
            do {
                try await Self.upsert(operation, in: database)
                await MainActor.run {
                    guard let self else { return }
                    self.activeUploadOperations.removeValue(forKey: item.fingerprint)
                    self.pendingUploadFingerprints.remove(item.fingerprint)
                    guard self.isCurrentSession(sessionID) else { return }
                    self.markSynced()
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.activeUploadOperations.removeValue(forKey: item.fingerprint)
                    self.pendingUploadFingerprints.remove(item.fingerprint)
                    guard self.isCurrentSession(sessionID) else { return }
                    guard !Self.isCancellationError(error) else { return }
                    self.status = .error(error.localizedDescription)
                }
                if !Self.isCancellationError(error) {
                    print("[CloudClipboardSync] Failed to upload clipboard item: \(error)")
                }
            }
        }
    }

    func syncNow() {
        guard settings.iCloudSyncEnabled else {
            status = .disabled
            return
        }

        guard settings.iCloudSyncReceiveEnabled else {
            markSynced()
            return
        }

        guard !isFetching else { return }

        guard ensureCloudKitAvailability() else {
            status = .unavailable
            return
        }

        fetchNow()
    }

    func fetchNow() {
        guard settings.iCloudSyncEnabled, settings.iCloudSyncReceiveEnabled, !isFetching, let database else { return }
        isFetching = true
        status = .syncing
        fetchSessionMaxCreatedAt = nil

        let query = Self.makeFetchQuery(since: lastFetchedCreatedAt)
        let operation = CKQueryOperation(query: query)
        let sessionID = syncSessionID
        operation.desiredKeys = [
            SkyCloudClipboardSchema.Field.contentType,
            SkyCloudClipboardSchema.Field.text,
            SkyCloudClipboardSchema.Field.fingerprint,
            SkyCloudClipboardSchema.Field.createdAt,
            SkyCloudClipboardSchema.Field.sourceDevice
        ]
        operation.resultsLimit = 100
        activeFetchOperation = operation

        operation.recordMatchedBlock = { [weak self] _, result in
            guard case .success(let record) = result else { return }
            Task { @MainActor in
                guard let self, self.isCurrentSession(sessionID) else { return }
                self.ingest(record)
            }
        }

        operation.queryResultBlock = { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                if self.activeFetchOperation === operation {
                    self.activeFetchOperation = nil
                }
                self.isFetching = false
                guard self.isCurrentSession(sessionID) else { return }
                switch result {
                case .success(let cursor?):
                    self.fetch(cursor: cursor, sessionID: sessionID)
                case .success(nil):
                    self.completeFetchSession()
                    self.markSynced()
                case .failure(let error):
                    guard !Self.isCancellationError(error) else { return }
                    self.fetchSessionMaxCreatedAt = nil
                    self.status = .error(error.localizedDescription)
                }
            }
        }

        database.add(operation)
    }

    nonisolated static func makeFetchQuery(since cutoffDate: Date?) -> CKQuery {
        let effectiveCutoff: Date
        if let cutoffDate {
            effectiveCutoff = cutoffDate.addingTimeInterval(-1)
        } else {
            effectiveCutoff = Date(timeIntervalSince1970: 0)
        }

        let predicate = NSPredicate(
            format: "%K > %@",
            SkyCloudClipboardSchema.Field.createdAt,
            effectiveCutoff as NSDate
        )
        let query = CKQuery(recordType: SkyCloudClipboardSchema.recordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: SkyCloudClipboardSchema.Field.createdAt, ascending: false)]
        return query
    }

    private func fetch(cursor: CKQueryOperation.Cursor, sessionID: UUID) {
        guard settings.iCloudSyncEnabled, settings.iCloudSyncReceiveEnabled, !isFetching, let database else { return }
        isFetching = true
        status = .syncing

        let operation = CKQueryOperation(cursor: cursor)
        activeFetchOperation = operation
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
                guard let self, self.isCurrentSession(sessionID) else { return }
                self.ingest(record)
            }
        }

        operation.queryResultBlock = { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                if self.activeFetchOperation === operation {
                    self.activeFetchOperation = nil
                }
                self.isFetching = false
                guard self.isCurrentSession(sessionID) else { return }
                switch result {
                case .success(let nextCursor?):
                    self.fetch(cursor: nextCursor, sessionID: sessionID)
                case .success(nil):
                    self.completeFetchSession()
                    self.markSynced()
                case .failure(let error):
                    guard !Self.isCancellationError(error) else { return }
                    self.fetchSessionMaxCreatedAt = nil
                    self.status = .error(error.localizedDescription)
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
            status = .unavailable
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
        fetchSessionMaxCreatedAt = CloudClipboardSyncPolicy.updatedFetchSessionCursor(
            current: fetchSessionMaxCreatedAt,
            ingesting: createdAt
        )
        let item = ClipboardItem(
            id: UUID(),
            createdAt: createdAt,
            content: .text(trimmed),
            fingerprint: fingerprint,
            source: .cloudKit
        )
        store.addCloudSyncedItem(item)
    }

    private func completeFetchSession() {
        lastFetchedCreatedAt = CloudClipboardSyncPolicy.finalizedFetchCursor(
            previous: lastFetchedCreatedAt,
            fetchedMax: fetchSessionMaxCreatedAt
        )
        persistedFetchCursor = lastFetchedCreatedAt
        fetchSessionMaxCreatedAt = nil
    }

    private func makeRecord(for item: ClipboardItem) -> CKRecord? {
        guard case .text(let text) = item.content else { return nil }

        let recordID = CKRecord.ID(recordName: SkyCloudClipboardSchema.recordName(for: item.fingerprint))
        let record = CKRecord(recordType: SkyCloudClipboardSchema.recordType, recordID: recordID)
        record[SkyCloudClipboardSchema.Field.contentType] = SkyCloudClipboardSchema.ContentType.text as CKRecordValue
        record[SkyCloudClipboardSchema.Field.text] = text as CKRecordValue
        record[SkyCloudClipboardSchema.Field.fingerprint] = item.fingerprint as CKRecordValue
        record[SkyCloudClipboardSchema.Field.createdAt] = item.createdAt as CKRecordValue
        record[SkyCloudClipboardSchema.Field.sourceDevice] = (Host.current().localizedName ?? "Mac") as CKRecordValue
        return record
    }

    private func backfillExistingLocalItems() async {
        guard settings.iCloudSyncEnabled, settings.iCloudSyncUploadEnabled else { return }
        guard ensureCloudKitAvailability(), let database else { return }

        let candidates = store.itemsEligibleForCloudSync()
        guard !candidates.isEmpty else { return }

        let recordIDs = candidates.map { item in
            CKRecord.ID(recordName: SkyCloudClipboardSchema.recordName(for: item.fingerprint))
        }

        let candidatesToUpload: [ClipboardItem]
        do {
            let existingRecordNames = try await Self.fetchExistingRecordNames(for: recordIDs, in: database)
            candidatesToUpload = CloudClipboardSyncPolicy.missingUploadCandidates(
                from: candidates,
                existingRecordNames: existingRecordNames
            )
        } catch {
            guard !Self.isCancellationError(error) else { return }
            print("[CloudClipboardSync] Failed to preflight backfill records, falling back to upload checks: \(error)")
            candidatesToUpload = CloudClipboardSyncPolicy.backfillUploadCandidates(from: candidates)
        }

        guard settings.iCloudSyncEnabled, settings.iCloudSyncUploadEnabled else { return }

        for item in candidatesToUpload {
            guard !Task.isCancelled else { return }
            uploadLocalItemIfNeeded(item)
        }
    }

    private var persistedFetchCursor: Date? {
        get {
            defaults.object(forKey: Keys.lastFetchedCreatedAt) as? Date
        }
        set {
            defaults.set(newValue, forKey: Keys.lastFetchedCreatedAt)
        }
    }

    private func isCurrentSession(_ sessionID: UUID) -> Bool {
        settings.iCloudSyncEnabled && syncSessionID == sessionID
    }

    private static func upsert(_ operation: CKModifyRecordsOperation, in database: CKDatabase) async throws {
        try await withCheckedThrowingContinuation { continuation in
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    private static func fetchExistingRecordNames(
        for recordIDs: [CKRecord.ID],
        in database: CKDatabase
    ) async throws -> Set<String> {
        guard !recordIDs.isEmpty else { return [] }

        return try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var existingRecordNames = Set<String>()
            var firstError: Error?
            let operation = CKFetchRecordsOperation(recordIDs: recordIDs)
            operation.desiredKeys = []

            operation.perRecordResultBlock = { recordID, result in
                lock.lock()
                defer { lock.unlock() }

                switch result {
                case .success:
                    existingRecordNames.insert(recordID.recordName)
                case .failure(let error):
                    let ckError = error as? CKError
                    if ckError?.code == .unknownItem {
                        return
                    }
                    if firstError == nil {
                        firstError = error
                    }
                }
            }

            operation.fetchRecordsResultBlock = { result in
                lock.lock()
                let capturedNames = existingRecordNames
                let capturedError = firstError
                lock.unlock()

                switch result {
                case .success:
                    if let capturedError {
                        continuation.resume(throwing: capturedError)
                    } else {
                        continuation.resume(returning: capturedNames)
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            database.add(operation)
        }
    }

    private static func isCancellationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == CKError.errorDomain && nsError.code == CKError.Code.operationCancelled.rawValue
    }

    private func markSynced() {
        status = .synced(Date())
    }
}
