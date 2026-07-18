import AppKit
import Foundation
import UniformTypeIdentifiers

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
        let isEmail: Bool
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

    var isEmail: Bool { classification.isEmail }

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
            Self.fileSystemItemKind(for: url) == .file
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
        guard let url = Self.normalizedWebURL(from: trimmed), let scheme = url.scheme?.lowercased() else {
            return nil
        }

        guard scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    var emailAddress: String? {
        guard isEmail, case .text(let value) = content else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.normalizedEmailAddress(from: trimmed)
    }

    var mailtoURL: URL? {
        guard let emailAddress else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = emailAddress
        return components.url
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

    var supportsSharing: Bool {
        switch content {
        case .text(let value):
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .image(let data, _, _, _):
            return !data.isEmpty
        case .fileURLs(let urls, _):
            return !urls.isEmpty
        }
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
            if let emailAddress = normalizedEmailAddress(from: trimmed) {
                return emailAddress
            }
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
            if looksLikeEmail(trimmed) {
                return L10n.tr("filter.email")
            }
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
            return Classification(isPlainText: false, isImage: true, isURL: false, isEmail: false, isCode: false)
        case .fileURLs:
            return Classification(isPlainText: false, isImage: false, isURL: false, isEmail: false, isCode: false)
        case .text(let value):
            let isEmail = looksLikeEmail(value)
            let isURL = !isEmail && looksLikeURL(value)
            let isCode = !isEmail && looksLikeCode(value, isKnownURL: isURL)
            return Classification(
                isPlainText: !isURL && !isEmail,
                isImage: false,
                isURL: isURL,
                isEmail: isEmail,
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
        if classification.isEmail {
            parts.append(contentsOf: ["email", "mail", "e-mail", "邮箱", "邮件"])
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

        if normalizedWebURL(from: trimmed) != nil {
            return true
        }

        guard
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
            let match = detector.firstMatch(in: trimmed, options: [], range: NSRange(location: 0, length: trimmed.utf16.count))
        else {
            return false
        }

        guard match.range.location == 0 && match.range.length == trimmed.utf16.count else {
            return false
        }

        let scheme = match.url?.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    private static func looksLikeEmail(_ value: String) -> Bool {
        normalizedEmailAddress(from: value) != nil
    }

    private static func normalizedEmailAddress(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        guard trimmed.range(of: #"^[A-Z0-9._%+-]+@(?:[A-Z0-9-]+\.)+[A-Z]{2,63}$"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            return nil
        }
        return trimmed
    }

    private static func prettyURLTitle(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = normalizedWebURL(from: trimmed), let host = url.host, !host.isEmpty else {
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

    private static func normalizedWebURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }

        let candidate: String
        if let scheme = URLComponents(string: trimmed)?.scheme, !scheme.isEmpty {
            candidate = trimmed
        } else {
            candidate = "https://\(trimmed)"
        }

        guard let url = URL(string: candidate), let host = url.host, isLikelyWebHost(host) else { return nil }
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private static func isLikelyWebHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        guard !normalized.isEmpty else { return false }
        if normalized == "localhost" { return true }
        guard normalized.range(of: #"^[a-z0-9.-]+$"#, options: .regularExpression) != nil else {
            return false
        }

        if normalized.range(of: #"^(?:\d{1,3}\.){3}\d{1,3}$"#, options: .regularExpression) != nil {
            return normalized.split(separator: ".").allSatisfy { part in
                guard let octet = Int(part) else { return false }
                return (0...255).contains(octet)
            }
        }

        let labels = normalized.split(separator: ".")
        guard labels.count >= 2 else { return false }
        guard let topLevelDomain = labels.last, topLevelDomain.count >= 2 else { return false }
        guard topLevelDomain.allSatisfy({ $0.isLetter }) else { return false }

        return labels.allSatisfy { label in
            guard !label.isEmpty, label.count <= 63 else { return false }
            guard label.first?.isLetter == true || label.first?.isNumber == true else { return false }
            guard label.last?.isLetter == true || label.last?.isNumber == true else { return false }
            return label.allSatisfy { character in
                character.isLetter || character.isNumber || character == "-"
            }
        }
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

        let declarationPatterns = [
            #"(^|\W)(func|class|struct|enum|protocol|extension|namespace|interface|typedef|def)\s+\w+"#,
            #"(^|\W)(const|let|var)\s+\w+\s*(=|:)"#,
            #"(^|\W)(import|export)\s+[\w\.\{\*]"#,
            #"(^|\W)(public|private|protected|final|static)\s+(func|class|struct|var|let|const|def)\b"#
        ]
        let controlFlowPatterns = [
            #"(^|\W)(if|else if|for|while|switch|guard|catch)\s*(\(|\{)"#,
            #"(^|\W)(case|try|await|return)\b.*(;|\{|\})"#
        ]
        let syntaxPatterns = [
            #"</?[a-z][^>]*>"#,
            #"^\s*[\{\[]\s*["\w]"#
        ]
        let sqlKeywordPatterns = [
            #"\bselect\b"#,
            #"\binsert\b"#,
            #"\bupdate\b"#,
            #"\bdelete\b"#,
            #"\bcreate\b"#,
            #"\balter\b"#,
            #"\bdrop\b"#,
            #"\bfrom\b"#,
            #"\bwhere\b"#,
            #"\bjoin\b"#,
            #"\bset\b"#,
            #"\bvalues\b"#,
            #"\binto\b"#,
            #"\bgroup\s+by\b"#,
            #"\border\s+by\b"#
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

        let declarationMatches = declarationPatterns.reduce(0) { count, pattern in
            count + (lowercased.range(of: pattern, options: .regularExpression) != nil ? 1 : 0)
        }
        let controlFlowMatches = controlFlowPatterns.reduce(0) { count, pattern in
            count + (lowercased.range(of: pattern, options: .regularExpression) != nil ? 1 : 0)
        }
        let syntaxMatches = syntaxPatterns.reduce(0) { count, pattern in
            count + (lowercased.range(of: pattern, options: .regularExpression) != nil ? 1 : 0)
        }
        let sqlKeywordMatches = sqlKeywordPatterns.reduce(0) { count, pattern in
            count + (lowercased.range(of: pattern, options: .regularExpression) != nil ? 1 : 0)
        }
        let sqlStartsLikeStatement = lowercased.range(
            of: #"^\s*(select|insert|update|delete|create|alter|drop)\b"#,
            options: .regularExpression
        ) != nil
        let sqlLooksLikeCode = sqlStartsLikeStatement && (sqlKeywordMatches >= 2 || trimmed.hasSuffix(";"))
        let strongMatches = declarationMatches + controlFlowMatches + syntaxMatches + (sqlLooksLikeCode ? 1 : 0)

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
            return syntaxMatches >= 1 ||
                declarationMatches >= 1 ||
                sqlLooksLikeCode ||
                (controlFlowMatches >= 1 && weakMatches >= 1) ||
                (weakMatches >= 2 && symbolCount >= 4)
        }

        if syntaxMatches >= 1 || declarationMatches >= 1 || sqlLooksLikeCode {
            return true
        }

        if controlFlowMatches >= 1 && (weakMatches >= 1 || indentedLineCount >= 1) {
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
