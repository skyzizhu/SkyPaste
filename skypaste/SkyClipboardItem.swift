import AppKit
import Foundation
import UniformTypeIdentifiers

enum ClipboardFilter: String, CaseIterable, Identifiable {
    case all
    case text
    case image
    case file
    case folder
    case code
    case url
    case favorites

    var id: String { rawValue }

    static let fixedLeading: ClipboardFilter = .all
    static let fixedTrailing: ClipboardFilter = .favorites
    static let reorderableCases: [ClipboardFilter] = [.text, .image, .file, .folder, .code, .url]
    static let defaultDisplayOrder: [ClipboardFilter] = [fixedLeading] + reorderableCases + [fixedTrailing]

    var isUserReorderable: Bool {
        Self.reorderableCases.contains(self)
    }

    static func normalizedReorderableOrder(_ filters: [ClipboardFilter]) -> [ClipboardFilter] {
        var seen = Set<ClipboardFilter>()
        let filtered = filters.filter { filter in
            filter.isUserReorderable && seen.insert(filter).inserted
        }

        let missing = reorderableCases.filter { !seen.contains($0) }
        return filtered + missing
    }

    static func displayOrder(from reorderableOrder: [ClipboardFilter]) -> [ClipboardFilter] {
        [fixedLeading] + normalizedReorderableOrder(reorderableOrder) + [fixedTrailing]
    }

    var title: String {
        switch self {
        case .all:
            return L10n.tr("filter.all")
        case .text:
            return L10n.tr("filter.text")
        case .image:
            return L10n.tr("filter.image")
        case .file:
            return L10n.tr("filter.file")
        case .folder:
            return L10n.tr("filter.folder")
        case .code:
            return L10n.tr("filter.code")
        case .url:
            return L10n.tr("filter.url")
        case .favorites:
            return L10n.tr("filter.favorites")
        }
    }

    var symbolSystemName: String? {
        switch self {
        case .all:
            return "square.grid.2x2"
        case .text:
            return "text.alignleft"
        case .image:
            return "photo"
        case .file:
            return "doc.fill"
        case .folder:
            return "folder.fill"
        case .code:
            return "chevron.left.forwardslash.chevron.right"
        case .url:
            return "link"
        case .favorites:
            return "star.fill"
        }
    }

    func matches(_ item: ClipboardItem) -> Bool {
        switch self {
        case .favorites:
            return item.isFavorite
        case .all:
            return true
        case .text:
            return item.isPlainText
        case .image:
            return item.isImage || item.containsImageFiles
        case .file:
            return item.containsFiles
        case .folder:
            return item.containsFolders
        case .code:
            return item.isCode
        case .url:
            return item.isURL
        }
    }
}

enum ClipboardContent: Equatable {
    case text(String)
    case image(data: Data, name: String?, originalByteCount: Int, previewOnly: Bool)
    case fileURLs(urls: [URL], pasteboardPayload: ClipboardFilePasteboardPayload?)
}

struct ClipboardFilePasteboardPayload: Codable, Equatable {
    let items: [ClipboardPasteboardItemPayload]

    var hasEntries: Bool {
        items.contains { !$0.entries.isEmpty }
    }
}

struct ClipboardPasteboardItemPayload: Codable, Equatable {
    let entries: [ClipboardPasteboardEntryPayload]
}

struct ClipboardPasteboardEntryPayload: Codable, Equatable {
    enum Storage: Codable, Equatable {
        case data(Data)
        case string(String)
        case propertyList(Data)
    }

    let type: String
    let storage: Storage
}

enum ClipboardFileSystemItemKind: Equatable {
    case file
    case folder
}

enum ClipboardSource: Int, Equatable {
    case local = 0
    case universalClipboard = 1
    case cloudKit = 2

    var isUniversalClipboard: Bool {
        self == .universalClipboard
    }

    var isDeviceSynced: Bool {
        self == .universalClipboard || self == .cloudKit
    }

    var deviceIconSystemName: String? {
        switch self {
        case .local:
            return nil
        case .universalClipboard:
            return "iphone.gen3"
        case .cloudKit:
            return "icloud"
        }
    }

    var badgeText: String? {
        switch self {
        case .local:
            return nil
        case .universalClipboard:
            return L10n.tr("clipboard.source.universal")
        case .cloudKit:
            return L10n.tr("clipboard.source.icloud")
        }
    }

    var searchKeywords: [String] {
        switch self {
        case .local:
            return ["local", "mac", "this mac", "本机", "本地"]
        case .universalClipboard:
            return ["phone", "iphone", "universal", "universal clipboard", "手机", "iphone 剪贴板", "通用剪贴板"]
        case .cloudKit:
            return ["icloud", "cloud", "sync", "云", "云同步", "icloud sync"]
        }
    }
}

struct ClipboardSourceApp: Equatable {
    let bundleID: String
    let name: String
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
    let searchIndex: String
    let source: ClipboardSource
    let sourceApp: ClipboardSourceApp?
    var isFavorite: Bool
    var isSnippet: Bool

    init(content: ClipboardContent, fingerprint: String) {
        self.init(id: UUID(), createdAt: Date(), content: content, fingerprint: fingerprint, source: .local, sourceApp: nil, isFavorite: false, isSnippet: false)
    }

    init(content: ClipboardContent, fingerprint: String, source: ClipboardSource) {
        self.init(id: UUID(), createdAt: Date(), content: content, fingerprint: fingerprint, source: source, sourceApp: nil, isFavorite: false, isSnippet: false)
    }

    init(
        id: UUID,
        createdAt: Date,
        content: ClipboardContent,
        fingerprint: String,
        source: ClipboardSource = .local,
        sourceApp: ClipboardSourceApp? = nil,
        isFavorite: Bool = false,
        isSnippet: Bool = false
    ) {
        let derivedClassification = Self.makeClassification(for: content)
        self.id = id
        self.createdAt = createdAt
        self.content = content
        self.fingerprint = fingerprint
        self.classification = derivedClassification
        self.source = source
        self.sourceApp = source == .local ? sourceApp : nil
        self.searchIndex = Self.makeSearchIndex(
            for: content,
            classification: derivedClassification,
            source: source,
            sourceApp: source == .local ? sourceApp : nil
        )
        self.isFavorite = isFavorite
        self.isSnippet = isSnippet
    }

    func withSourceApp(_ sourceApp: ClipboardSourceApp?) -> ClipboardItem {
        ClipboardItem(
            id: id,
            createdAt: createdAt,
            content: content,
            fingerprint: fingerprint,
            source: source,
            sourceApp: sourceApp,
            isFavorite: isFavorite,
            isSnippet: isSnippet
        )
    }

    var title: String {
        Self.makeTitle(for: content)
    }

    var subtitle: String {
        Self.makeSubtitle(for: content)
    }

    var isPlainText: Bool { classification.isPlainText }

    var isImage: Bool { classification.isImage }

    var isURL: Bool { classification.isURL }

    var isCode: Bool { classification.isCode }

    var fileURLs: [URL]? {
        guard case .fileURLs(let urls, _) = content else { return nil }
        return urls
    }

    var filePasteboardPayload: ClipboardFilePasteboardPayload? {
        guard case .fileURLs(_, let pasteboardPayload) = content else { return nil }
        return pasteboardPayload
    }

    var isFileCollection: Bool {
        fileURLs?.isEmpty == false
    }

    var fileSystemKinds: [ClipboardFileSystemItemKind] {
        fileURLs?.map(Self.fileSystemItemKind(for:)) ?? []
    }

    var containsFiles: Bool {
        guard let fileURLs else { return false }
        return fileURLs.contains { url in
            Self.fileSystemItemKind(for: url) == .file && !Self.isImageFileURL(url)
        }
    }

    var containsFolders: Bool {
        fileSystemKinds.contains(.folder)
    }

    var containsImageFiles: Bool {
        guard let fileURLs else { return false }
        return fileURLs.contains { url in
            Self.fileSystemItemKind(for: url) == .file && Self.isImageFileURL(url)
        }
    }

    var isSingleImageFile: Bool {
        guard let singleFileURL, singleFileSystemItemKind == .file else { return false }
        return Self.isImageFileURL(singleFileURL)
    }

    var singleFileURL: URL? {
        guard let fileURLs, fileURLs.count == 1 else { return nil }
        return fileURLs[0]
    }

    var singleFileSystemItemKind: ClipboardFileSystemItemKind? {
        guard let url = singleFileURL else { return nil }
        return Self.fileSystemItemKind(for: url)
    }

    var openActionTitle: String {
        switch singleFileSystemItemKind {
        case .folder:
            return L10n.tr("menu.open_folder")
        case .file:
            return L10n.tr("menu.open_file")
        case nil:
            return L10n.tr("menu.open_item")
        }
    }

    var isSingleFile: Bool {
        singleFileSystemItemKind == .file
    }

    var containingFolderURL: URL? {
        guard let singleFileURL, singleFileSystemItemKind == .file else { return nil }
        return singleFileURL.deletingLastPathComponent()
    }

    var browserURL: URL? {
        guard isURL, case .text(let value) = content else { return nil }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            return nil
        }

        guard scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    var previewImage: NSImage? {
        guard case .image(let data, _, _, _) = content else { return nil }
        return NSImage(data: data)
    }

    var previewImageData: Data? {
        guard case .image(let data, _, _, _) = content else { return nil }
        return data
    }

    var previewText: String? {
        guard case .text(let value) = content else { return nil }
        return value
    }

    var supportsTextPreview: Bool {
        previewText != nil
    }

    var searchableText: String {
        if isFavorite {
            return searchIndex + "\nfavorite\nfavorites\nfav\n收藏"
        }
        return searchIndex
    }

    private static func makeTitle(for content: ClipboardContent) -> String {
        switch content {
        case .text(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return L10n.tr("clipboard.empty_text") }
            if looksLikeURL(trimmed) {
                return prettyURLTitle(trimmed)
            }
            if trimmed.count <= 90 { return trimmed }
            return String(trimmed.prefix(90)) + "..."

        case .image(_, let name, _, _):
            let cleaned = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? L10n.tr("clipboard.image_fallback_name") : cleaned

        case .fileURLs(let urls, _):
            if urls.count == 1 {
                let url = urls[0]
                switch fileSystemItemKind(for: url) {
                case .folder:
                    return abbreviatedPath(for: url)
                case .file:
                    let itemName = Self.displayName(for: url)
                    return L10n.format("clipboard.file_single", itemName)
                }
            }

            let kinds = urls.map(fileSystemItemKind(for:))
            if kinds.allSatisfy({ $0 == .folder }) {
                return L10n.format("clipboard.folder_count", urls.count)
            }

            return L10n.format("clipboard.file_count", urls.count)
        }
    }

    private static func makeSubtitle(for content: ClipboardContent) -> String {
        switch content {
        case .text(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if looksLikeURL(trimmed) {
                return L10n.tr("filter.url")
            }
            return L10n.format("clipboard.subtitle.text", value.count)

        case .image(_, _, let originalByteCount, _):
            let kb = max(1, originalByteCount / 1024)
            return L10n.format("clipboard.subtitle.image", kb)

        case .fileURLs(let urls, _):
            if urls.count == 1 {
                let url = urls[0]
                switch fileSystemItemKind(for: url) {
                case .folder:
                    return L10n.tr("clipboard.subtitle.folder")
                case .file:
                    if isImageFileURL(url) {
                        if let ext = imageFileFormatText(for: url) {
                            return L10n.format("clipboard.subtitle.image_file_format", ext)
                        }
                        return L10n.tr("clipboard.subtitle.image_file")
                    }
                    return L10n.tr("clipboard.subtitle.file")
                }
            }

            let kinds = urls.map(fileSystemItemKind(for:))
            if kinds.allSatisfy({ $0 == .folder }) {
                return L10n.format("clipboard.subtitle.folder_count", urls.count)
            }

            if urls.allSatisfy({ fileSystemItemKind(for: $0) == .file && isImageFileURL($0) }) {
                return L10n.format("clipboard.subtitle.image_file_count", urls.count)
            }

            return L10n.format("clipboard.subtitle.file_count", urls.count)
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

    private static func makeSearchIndex(
        for content: ClipboardContent,
        classification: Classification,
        source: ClipboardSource,
        sourceApp: ClipboardSourceApp?
    ) -> String {
        var parts: [String] = []

        switch content {
        case .text(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                parts.append(trimmed)
            }

        case .image(_, let name, _, _):
            if let name {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    parts.append(trimmed)
                }
            }
            parts.append(contentsOf: ["image", "img", "图片"])

        case .fileURLs(let urls, _):
            parts.append(contentsOf: urls.map(displayName(for:)))
            parts.append(contentsOf: urls.map(\.path))
            parts.append(contentsOf: ["file", "files", "folder", "folders", "directory", "directories", "文件", "文件夹", "目录"])

            if urls.contains(where: isImageFileURL(_:)) {
                parts.append(contentsOf: ["image file", "photo file", "image", "img", "图片", "图片文件"])
            }
        }

        if classification.isPlainText {
            parts.append(contentsOf: ["text", "plain text", "文本"])
        }
        if classification.isURL {
            parts.append(contentsOf: ["url", "link", "链接"])
        }
        if classification.isCode {
            parts.append(contentsOf: ["code", "snippet", "代码"])
        }

        parts.append(contentsOf: source.searchKeywords)
        if let sourceApp {
            parts.append(sourceApp.name)
            parts.append(sourceApp.bundleID)
        }
        return parts.joined(separator: "\n").lowercased()
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

    private static func prettyURLTitle(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else {
            return trimmed
        }

        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty {
            return host
        }

        let condensedPath = path
            .split(separator: "/")
            .prefix(3)
            .joined(separator: "/")

        return "\(host)/\(condensedPath)"
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

    private static func fileSystemItemKind(for url: URL) -> ClipboardFileSystemItemKind {
        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true {
            return .folder
        }
        return url.hasDirectoryPath ? .folder : .file
    }

    private static func isImageFileURL(_ url: URL) -> Bool {
        guard !url.pathExtension.isEmpty else { return false }
        if let type = UTType(filenameExtension: url.pathExtension) {
            return type.conforms(to: .image)
        }
        return false
    }

    private static func displayName(for url: URL) -> String {
        let component = url.lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return component.isEmpty ? url.path : component
    }

    private static func imageFileFormatText(for url: URL) -> String? {
        let ext = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ext.isEmpty else { return nil }
        return ext.uppercased()
    }

    private static func abbreviatedPath(for url: URL) -> String {
        let fullPath = url.path
        guard !fullPath.isEmpty else { return url.absoluteString }

        let homePath = NSHomeDirectory()
        if fullPath == homePath {
            return "~"
        }
        if fullPath.hasPrefix(homePath + "/") {
            return "~" + fullPath.dropFirst(homePath.count)
        }
        return fullPath
    }

}

enum ClipboardCaptureResult {
    case none
    case item(ClipboardItem)
}

struct ClipboardDecoder {
    private static let remoteClipboardType = NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")
    private static let sourceMarkerFragments = [
        "remote-clipboard",
        "universal-clipboard"
    ]

    static func decode(from pasteboard: NSPasteboard) -> ClipboardCaptureResult {
        guard let first = pasteboard.pasteboardItems?.first else { return .none }
        let source = detectSource(from: pasteboard)

        let fileURLs = extractFileURLs(from: pasteboard, first: first)
        if !fileURLs.isEmpty {
            let joined = fileURLs.map(\.path).joined(separator: "|")
            let payload = captureFilePasteboardPayload(from: pasteboard)
            let item = ClipboardItem(content: .fileURLs(urls: fileURLs, pasteboardPayload: payload), fingerprint: "file:\(joined)", source: source)
            return .item(item)
        }

        if let image = extractImagePayload(first: first, pasteboard: pasteboard) {
            let digest = image.data.prefix(64).base64EncodedString()
            return .item(
                ClipboardItem(
                    content: .image(data: image.data, name: image.name, originalByteCount: image.data.count, previewOnly: false),
                    fingerprint: "img:\(digest):\(image.data.count)",
                    source: source
                )
            )
        }

        if let urlText = extractURLText(from: pasteboard, first: first) {
            let text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .none }
            return .item(ClipboardItem(content: .text(text), fingerprint: "txt:\(text)", source: source))
        }

        if let raw = first.string(forType: .string) {
            let text = raw.trimmingCharacters(in: .newlines)
            guard !text.isEmpty else { return .none }
            return .item(ClipboardItem(content: .text(text), fingerprint: "txt:\(text)", source: source))
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

        case .fileURLs(let urls, let pasteboardPayload):
            let pasteboardItems = makeFilePasteboardItems(urls: urls, payload: pasteboardPayload)
            if !pasteboardItems.isEmpty {
                pasteboard.writeObjects(pasteboardItems as [NSPasteboardWriting])
                writeLegacyFileList(urls, to: pasteboard)
                return
            }

            pasteboard.writeObjects(urls as [NSPasteboardWriting])
            writeLegacyFileList(urls, to: pasteboard)
        }
    }

    private static func captureFilePasteboardPayload(from pasteboard: NSPasteboard) -> ClipboardFilePasteboardPayload? {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return nil }

        let payloadItems = items.compactMap { item -> ClipboardPasteboardItemPayload? in
            let entries = item.types.compactMap { type -> ClipboardPasteboardEntryPayload? in
                if let data = item.data(forType: type) {
                    return ClipboardPasteboardEntryPayload(type: type.rawValue, storage: .data(data))
                }

                if let propertyList = item.propertyList(forType: type),
                   PropertyListSerialization.propertyList(propertyList, isValidFor: .binary),
                   let data = try? PropertyListSerialization.data(fromPropertyList: propertyList, format: .binary, options: 0)
                {
                    return ClipboardPasteboardEntryPayload(type: type.rawValue, storage: .propertyList(data))
                }

                if let string = item.string(forType: type) {
                    return ClipboardPasteboardEntryPayload(type: type.rawValue, storage: .string(string))
                }

                return nil
            }

            guard !entries.isEmpty else { return nil }
            return ClipboardPasteboardItemPayload(entries: entries)
        }

        let payload = ClipboardFilePasteboardPayload(items: payloadItems)
        return payload.hasEntries ? payload : nil
    }

    private static func makeFilePasteboardItems(urls: [URL], payload: ClipboardFilePasteboardPayload?) -> [NSPasteboardItem] {
        guard !urls.isEmpty else { return [] }

        let payloadItems = payload?.items ?? []

        return urls.enumerated().compactMap { index, url in
            let item = NSPasteboardItem()
            var hasValue = false
            var restoredTypes = Set<String>()

            for entry in payloadItems[safe: index]?.entries ?? [] {
                let type = NSPasteboard.PasteboardType(entry.type)
                switch entry.storage {
                case .data(let data):
                    item.setData(data, forType: type)
                    hasValue = true
                case .string(let string):
                    item.setString(string, forType: type)
                    hasValue = true
                case .propertyList(let data):
                    if let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil) {
                        item.setPropertyList(propertyList, forType: type)
                        hasValue = true
                    }
                }

                restoredTypes.insert(entry.type)
            }

            if !restoredTypes.contains(NSPasteboard.PasteboardType.fileURL.rawValue) {
                item.setString(url.absoluteString, forType: .fileURL)
                hasValue = true
            }

            if !restoredTypes.contains(NSPasteboard.PasteboardType.URL.rawValue) {
                item.setString(url.absoluteString, forType: .URL)
                hasValue = true
            }

            if !restoredTypes.contains("public.url-name") {
                item.setString(url.lastPathComponent, forType: NSPasteboard.PasteboardType("public.url-name"))
                hasValue = true
            }

            if !restoredTypes.contains(NSPasteboard.PasteboardType.string.rawValue) {
                item.setString(url.lastPathComponent, forType: .string)
                hasValue = true
            }

            return hasValue ? item : nil
        }
    }

    private static func writeLegacyFileList(_ urls: [URL], to pasteboard: NSPasteboard) {
        let filePaths = urls.filter(\.isFileURL).map(\.path)
        guard !filePaths.isEmpty else { return }

        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        pasteboard.setPropertyList(filePaths, forType: filenamesType)
    }

    private static func extractFileURLs(from pasteboard: NSPasteboard, first: NSPasteboardItem) -> [URL] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            return urls.filter(\.isFileURL)
        }

        if let raw = first.propertyList(forType: .fileURL) as? String,
           let url = URL(string: raw),
           url.isFileURL {
            return [url]
        }

        return []
    }

    private static func extractURLText(from pasteboard: NSPasteboard, first: NSPasteboardItem) -> String? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first(where: { !$0.isFileURL }) {
            return url.absoluteString
        }

        if let raw = first.string(forType: .URL) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed), !url.isFileURL {
                return trimmed
            }
        }

        if let raw = first.propertyList(forType: .URL) as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed), !url.isFileURL {
                return trimmed
            }
        }

        return nil
    }

    private static func detectSource(from pasteboard: NSPasteboard) -> ClipboardSource {
        let allTypes = Set((pasteboard.types ?? []) + (pasteboard.pasteboardItems ?? []).flatMap(\.types))
        let hasRemoteMarker = allTypes.contains(remoteClipboardType) ||
            allTypes.contains(where: { type in
                let rawValue = type.rawValue.lowercased()
                return sourceMarkerFragments.contains(where: rawValue.contains)
            })

        return hasRemoteMarker ? .universalClipboard : .local
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
           let data = safeImageData(from: image) {
            return (data, inferImageName(from: pasteboard, first: first))
        }

        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let firstImage = images.first,
           let data = safeImageData(from: firstImage) {
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
        return safeImageData(from: image)
    }

    private static func safeImageData(from image: NSImage) -> Data? {
        if let png = pngData(from: image), !png.isEmpty {
            return png
        }

        if let tiff = image.tiffRepresentation, !tiff.isEmpty {
            return tiff
        }

        return nil
    }

    private static func pngData(from image: NSImage) -> Data? {
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let rep = NSBitmapImageRep(cgImage: cgImage)
            if let data = rep.representation(using: .png, properties: [:]), !data.isEmpty {
                return data
            }
        }

        let size = bestRasterSize(for: image)
        guard size.width > 0, size.height > 0 else {
            return nil
        }

        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width),
                pixelsHigh: Int(size.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]), !data.isEmpty else {
            return nil
        }

        return data
    }

    private static func bestRasterSize(for image: NSImage) -> NSSize {
        if image.size.width > 0, image.size.height > 0 {
            return image.size
        }

        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return NSSize(width: max(1, cgImage.width), height: max(1, cgImage.height))
        }

        return .zero
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
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
                source: item.source,
                sourceApp: item.sourceApp,
                isFavorite: item.isFavorite,
                isSnippet: item.isSnippet
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
            source: item.source,
            sourceApp: item.sourceApp,
            isFavorite: item.isFavorite,
            isSnippet: item.isSnippet
        )
    }

    private static func previewData(from data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        let originalSize = bestRenderSize(for: image)
        guard originalSize.width > 0, originalSize.height > 0 else { return nil }

        let maxDimension = max(originalSize.width, originalSize.height)
        guard maxDimension > 0 else { return nil }

        let scale = min(1, previewMaxDimension / maxDimension)
        let targetSize = NSSize(
            width: max(1, round(originalSize.width * scale)),
            height: max(1, round(originalSize.height * scale))
        )

        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(targetSize.width),
                pixelsHigh: Int(targetSize.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: targetSize), from: .zero, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        guard
            let png = rep.representation(using: .png, properties: [:])
        else {
            return nil
        }

        return png
    }

    private static func bestRenderSize(for image: NSImage) -> NSSize {
        if image.size.width > 0, image.size.height > 0 {
            return image.size
        }

        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return NSSize(width: max(1, cgImage.width), height: max(1, cgImage.height))
        }

        return .zero
    }
}
