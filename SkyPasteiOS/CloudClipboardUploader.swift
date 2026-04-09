import CryptoKit
import CloudKit
import Foundation
import UIKit

enum CloudClipboardSchema {
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

enum CloudClipboardUploadError: LocalizedError {
    case emptyPasteboard

    var errorDescription: String? {
        switch self {
        case .emptyPasteboard:
            return "当前剪贴板没有可同步的文本内容。"
        }
    }
}

struct CloudClipboardUploader {
    private let database = CKContainer(identifier: CloudClipboardSchema.containerIdentifier).privateCloudDatabase

    func uploadCurrentTextPasteboard() async throws {
        let pasteboardText = await MainActor.run {
            UIPasteboard.general.string
        }
        guard let text = pasteboardText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw CloudClipboardUploadError.emptyPasteboard
        }
        let sourceDevice = await MainActor.run {
            UIDevice.current.name
        }
        let fingerprint = "txt:\(text)"

        let recordID = CKRecord.ID(recordName: CloudClipboardSchema.recordName(for: fingerprint))
        let record = CKRecord(recordType: CloudClipboardSchema.recordType, recordID: recordID)
        record[CloudClipboardSchema.Field.contentType] = CloudClipboardSchema.ContentType.text as CKRecordValue
        record[CloudClipboardSchema.Field.text] = text as CKRecordValue
        record[CloudClipboardSchema.Field.fingerprint] = fingerprint as CKRecordValue
        record[CloudClipboardSchema.Field.createdAt] = Date() as CKRecordValue
        record[CloudClipboardSchema.Field.sourceDevice] = sourceDevice as CKRecordValue

        try await Self.upsert(record, in: database)
    }

    private static func upsert(_ record: CKRecord, in database: CKDatabase) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            operation.savePolicy = .changedKeys
            operation.isAtomic = true
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
}
