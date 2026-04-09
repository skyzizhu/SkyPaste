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

        let record = CKRecord(recordType: CloudClipboardSchema.recordType)
        record[CloudClipboardSchema.Field.contentType] = CloudClipboardSchema.ContentType.text as CKRecordValue
        record[CloudClipboardSchema.Field.text] = text as CKRecordValue
        record[CloudClipboardSchema.Field.fingerprint] = "txt:\(text)" as CKRecordValue
        record[CloudClipboardSchema.Field.createdAt] = Date() as CKRecordValue
        record[CloudClipboardSchema.Field.sourceDevice] = sourceDevice as CKRecordValue

        _ = try await database.save(record)
    }
}
