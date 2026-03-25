import AppKit
import Foundation
import UniformTypeIdentifiers

enum ClipboardFilter: String, CaseIterable, Identifiable {
    case all
    case text
    case image
    case url
    case code
    case favorites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return L10n.tr("filter.all")
        case .text:
            return L10n.tr("filter.text")
        case .image:
            return L10n.tr("filter.image")
        case .url:
            return L10n.tr("filter.url")
        case .code:
            return L10n.tr("filter.code")
        case .favorites:
            return L10n.tr("filter.favorites")
        }
    }

    func matches(_ item: ClipboardItem) -> Bool {
        switch self {
        case .all:
            return true
        case .text:
            return item.isPlainText
        case .image:
            return item.isImage
        case .url:
            return item.isURL
        case .code:
            return item.isCode
        case .favorites:
            return item.isFavorite
        }
    }
}

enum ClipboardContent: Equatable {
    case text(String)
    case image(data: Data, name: String?, originalByteCount: Int, previewOnly: Bool)
    case fileURLs([URL])
}

struct ClipboardItem: Identifiable, Equatable {
    struct Classification: Equatable {
        let isPlainText: Bool
        let isImage: Bool
        let isURL: Bool
        let isCode: Bool
    }

    let id: UUID
    let createdAt: Date
    let content: ClipboardContent
    let fingerprint: String
    let classification: Classification
    let title: String
    let subtitle: String
    var isFavorite: Bool

    init(content: ClipboardContent, fingerprint: String) {
        self.init(id: UUID(), createdAt: Date(), content: content, fingerprint: fingerprint, isFavorite: false)
    }

    init(id: UUID, createdAt: Date, content: ClipboardContent, fingerprint: String, isFavorite: Bool = false) {
        let derivedClassification = Self.makeClassification(for: content)
        self.id = id
        self.createdAt = createdAt
        self.content = content
        self.fingerprint = fingerprint
        self.classification = derivedClassification
        self.title = Self.makeTitle(for: content)
        self.subtitle = Self.makeSubtitle(for: content)
        self.isFavorite = isFavorite
    }

    var isPlainText: Bool { classification.isPlainText }

    var isImage: Bool { classification.isImage }

    var isURL: Bool { classification.isURL }

    var isCode: Bool { classification.isCode }

    var previewImage: NSImage? {
        guard case .image(let data, _, _, _) = content else { return nil }
        return NSImage(data: data)
    }

    var previewImageData: Data? {
        guard case .image(let data, _, _, _) = content else { return nil }
        return data
    }

    private static func makeTitle(for content: ClipboardContent) -> String {
        switch content {
        case .text(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return L10n.tr("clipboard.empty_text") }
            if trimmed.count <= 90 { return trimmed }
            return String(trimmed.prefix(90)) + "..."

        case .image(_, let name, _, _):
            let cleaned = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? L10n.tr("clipboard.image_fallback_name") : cleaned

        case .fileURLs(let urls):
            if urls.count == 1 {
                return L10n.format("clipboard.file_single", urls[0].lastPathComponent)
            }
            return L10n.format("clipboard.file_count", urls.count)
        }
    }

    private static func makeSubtitle(for content: ClipboardContent) -> String {
        switch content {
        case .text(let value):
            return L10n.format("clipboard.subtitle.text", value.count)

        case .image(_, _, let originalByteCount, _):
            let kb = max(1, originalByteCount / 1024)
            return L10n.format("clipboard.subtitle.image", kb)

        case .fileURLs(let urls):
            return urls.map(\.lastPathComponent).joined(separator: ", ")
        }
    }

    private static func makeClassification(for content: ClipboardContent) -> Classification {
        switch content {
        case .image:
            return Classification(isPlainText: false, isImage: true, isURL: false, isCode: false)
        case .fileURLs:
            return Classification(isPlainText: false, isImage: false, isURL: false, isCode: false)
        case .text(let value):
            let isURL = looksLikeURL(value)
            let isCode = looksLikeCode(value, isKnownURL: isURL)
            return Classification(
                isPlainText: !isURL,
                isImage: false,
                isURL: isURL,
                isCode: isCode
            )
        }
    }

    private static func looksLikeURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        guard
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
            let match = detector.firstMatch(in: trimmed, options: [], range: NSRange(location: 0, length: trimmed.utf16.count))
        else {
            return false
        }

        return match.range.location == 0 && match.range.length == trimmed.utf16.count
    }

    private static func looksLikeCode(_ value: String, isKnownURL: Bool) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !isKnownURL else { return false }
        guard trimmed.count >= 8 else { return false }

        let lines = trimmed.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let newlineCount = max(0, lines.count - 1)
        let lowercased = trimmed.lowercased()

        if trimmed.hasPrefix("```") && trimmed.hasSuffix("```") {
            return true
        }

        let strongKeywordPatterns = [
            #"(^|\W)(func|class|struct|enum|protocol|extension|namespace|interface|typedef|import|export|return|const|let|var|def|async|await|public|private|protected|final|static)\s"#,
            #"(^|\W)(if|else|for|while|switch|case|guard|catch|try)\s*(\(|\{|\w)"#,
            #"</?[a-z][^>]*>"#,
            #"(^|\W)(select|insert|update|delete|create|alter|drop|where|from|join|group by|order by)\s"#
        ]

        let weakSignalPatterns = [
            #"->"#,
            #"=>"#,
            #"::"#,
            #"\b\w+\s*\([^()\n]*\)\s*\{"#,
            #"\b\w+\s*\([^()\n]*\)\s*;"#,
            #"\[[^\]]+\]"#,
            #"\{[^}]+\}"#
        ]

        let strongMatches = strongKeywordPatterns.reduce(0) { count, pattern in
            count + (lowercased.range(of: pattern, options: .regularExpression) != nil ? 1 : 0)
        }

        let weakMatches = weakSignalPatterns.reduce(0) { count, pattern in
            count + (trimmed.range(of: pattern, options: .regularExpression) != nil ? 1 : 0)
        }

        let symbolCharacterSet = CharacterSet(charactersIn: "{}[]();<>`=$#\\")
        let symbolCount = trimmed.unicodeScalars.filter { symbolCharacterSet.contains($0) }.count
        let indentedLineCount = lines.filter { line in
            line.hasPrefix("    ") || line.hasPrefix("\t")
        }.count

        var score = 0
        score += strongMatches * 3
        score += weakMatches
        if newlineCount >= 2 { score += 1 }
        if indentedLineCount >= 1 { score += 1 }
        if symbolCount >= 6 { score += 1 }
        if trimmed.contains(";\n") || trimmed.contains("{\n") || trimmed.contains("\n}") { score += 1 }

        let naturalLanguagePenaltyWords = [
            "你好", "谢谢", "请", "the ", "and ", "that ", "this ", "with ", "你", "我们"
        ]
        let naturalLanguagePenalty = naturalLanguagePenaltyWords.reduce(0) { count, word in
            count + (lowercased.contains(word) ? 1 : 0)
        }
        score -= min(naturalLanguagePenalty, 2)

        if newlineCount == 0 {
            if strongMatches >= 1 && weakMatches >= 1 {
                return true
            }
            if strongMatches >= 2 || (weakMatches >= 2 && symbolCount >= 4) {
                return true
            }
            return false
        }

        if strongMatches >= 1 && (weakMatches >= 1 || indentedLineCount >= 1) {
            return true
        }

        return score >= 4
    }
}

enum ClipboardCaptureResult {
    case none
    case item(ClipboardItem)
}

struct ClipboardDecoder {
    static func decode(from pasteboard: NSPasteboard) -> ClipboardCaptureResult {
        guard let first = pasteboard.pasteboardItems?.first else { return .none }

        let fileURLs = extractFileURLs(from: pasteboard, first: first)
        if !fileURLs.isEmpty {
            if fileURLs.count == 1, let image = imagePayloadFromFileURL(fileURLs[0]) {
                let digest = image.data.prefix(64).base64EncodedString()
                return .item(
                    ClipboardItem(
                        content: .image(data: image.data, name: image.name, originalByteCount: image.data.count, previewOnly: false),
                        fingerprint: "img:\(digest):\(image.data.count)"
                    )
                )
            }

            let joined = fileURLs.map(\.path).joined(separator: "|")
            let item = ClipboardItem(content: .fileURLs(fileURLs), fingerprint: "file:\(joined)")
            return .item(item)
        }

        if let image = extractImagePayload(first: first, pasteboard: pasteboard) {
            let digest = image.data.prefix(64).base64EncodedString()
            return .item(
                ClipboardItem(
                    content: .image(data: image.data, name: image.name, originalByteCount: image.data.count, previewOnly: false),
                    fingerprint: "img:\(digest):\(image.data.count)"
                )
            )
        }

        if let raw = first.string(forType: .string) {
            let text = raw.trimmingCharacters(in: .newlines)
            guard !text.isEmpty else { return .none }
            return .item(ClipboardItem(content: .text(text), fingerprint: "txt:\(text)"))
        }

        return .none
    }

    static func write(_ item: ClipboardItem, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()

        switch item.content {
        case .text(let value):
            pasteboard.setString(value, forType: .string)

        case .image(let data, _, _, _):
            if let image = NSImage(data: data) {
                pasteboard.writeObjects([image])
            }

        case .fileURLs(let urls):
            pasteboard.writeObjects(urls as [NSPasteboardWriting])
        }
    }

    private static func extractFileURLs(from pasteboard: NSPasteboard, first: NSPasteboardItem) -> [URL] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            return urls
        }

        if let raw = first.propertyList(forType: .fileURL) as? String,
           let url = URL(string: raw) {
            return [url]
        }

        return []
    }

    private static func imagePayloadFromFileURL(_ url: URL) -> (data: Data, name: String)? {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else {
            return nil
        }

        guard let image = NSImage(contentsOf: url) else { return nil }
        guard let data = pngData(from: image) ?? image.tiffRepresentation else { return nil }

        return (data, url.lastPathComponent)
    }

    private static func extractImagePayload(first: NSPasteboardItem, pasteboard: NSPasteboard) -> (data: Data, name: String?)? {
        if let tiffData = first.data(forType: .tiff) {
            return (tiffData, inferImageName(from: pasteboard, first: first))
        }

        if let pngData = first.data(forType: .png) {
            return (pngData, inferImageName(from: pasteboard, first: first))
        }

        for type in first.types {
            guard
                let utType = UTType(type.rawValue),
                utType.conforms(to: .image),
                let data = first.data(forType: type)
            else {
                continue
            }

            if let normalized = normalizeImageData(data) {
                return (normalized, inferImageName(from: pasteboard, first: first))
            }
            return (data, inferImageName(from: pasteboard, first: first))
        }

        if let image = NSImage(pasteboard: pasteboard),
           let data = pngData(from: image) ?? image.tiffRepresentation {
            return (data, inferImageName(from: pasteboard, first: first))
        }

        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let firstImage = images.first,
           let data = pngData(from: firstImage) ?? firstImage.tiffRepresentation {
            return (data, inferImageName(from: pasteboard, first: first))
        }

        return nil
    }

    private static func inferImageName(from pasteboard: NSPasteboard, first: NSPasteboardItem) -> String? {
        let urls = extractFileURLs(from: pasteboard, first: first)
        if urls.count == 1 {
            return urls[0].lastPathComponent
        }

        return nil
    }

    private static func normalizeImageData(_ data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        return pngData(from: image) ?? image.tiffRepresentation
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff)
        else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
    }
}

enum ClipboardImageOptimizer {
    static let previewMaxDimension: CGFloat = 240

    static func memoryOptimizedItem(_ item: ClipboardItem) -> ClipboardItem {
        guard case .image(let data, let name, let originalByteCount, _) = item.content else {
            return item
        }

        guard let previewData = previewData(from: data) else {
            return ClipboardItem(
                id: item.id,
                createdAt: item.createdAt,
                content: .image(
                    data: data,
                    name: name,
                    originalByteCount: originalByteCount,
                    previewOnly: true
                ),
                fingerprint: item.fingerprint,
                isFavorite: item.isFavorite
            )
        }

        return ClipboardItem(
            id: item.id,
            createdAt: item.createdAt,
            content: .image(
                data: previewData,
                name: name,
                originalByteCount: originalByteCount,
                previewOnly: true
            ),
            fingerprint: item.fingerprint,
            isFavorite: item.isFavorite
        )
    }

    private static func previewData(from data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        if image.size.width <= 0 || image.size.height <= 0 { return data }

        let originalSize = image.size
        let maxDimension = max(originalSize.width, originalSize.height)

        let scale = min(1, previewMaxDimension / maxDimension)
        let targetSize = NSSize(
            width: max(1, round(originalSize.width * scale)),
            height: max(1, round(originalSize.height * scale))
        )

        let rendered = NSImage(size: targetSize)
        rendered.lockFocus()
        defer { rendered.unlockFocus() }

        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: targetSize), from: .zero, operation: .copy, fraction: 1.0)

        guard
            let tiff = rendered.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else {
            return nil
        }

        return png
    }
}
