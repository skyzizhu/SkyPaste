import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum ClipboardSaveAsService {
    static func saveAs(_ item: ClipboardItem, relativeTo window: NSWindow? = nil, completion: (() -> Void)? = nil) {
        switch item.content {
        case .image(let data, let name, _, _):
            saveImage(data: data, preferredName: name, window: window, completion: completion)
        case .fileURLs(let urls, _):
            saveFileSystemItems(urls.filter(\.isFileURL), window: window, completion: completion)
        case .text:
            completion?()
            return
        }
    }

    private static func saveImage(data: Data, preferredName: String?, window: NSWindow?, completion: (() -> Void)?) {
        guard !data.isEmpty else {
            completion?()
            return
        }

        let panel = NSSavePanel()
        panel.title = L10n.tr("save_as.title")
        panel.prompt = L10n.tr("save_as.action")
        panel.nameFieldStringValue = imageFileName(preferredName: preferredName, data: data)
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.canCreateDirectories = true

        present(panel, window: window) { response in
            defer { completion?() }
            guard response == .OK, let destination = panel.url else { return }
            do {
                try writeReplacingExistingItem(data: data, to: destination)
            } catch {
                showSaveError(error, window: window)
            }
        }
    }

    private static func saveFileSystemItems(_ urls: [URL], window: NSWindow?, completion: (() -> Void)?) {
        guard !urls.isEmpty else {
            completion?()
            return
        }

        if let missing = firstMissingItem(in: urls) {
            showMissingItemAlert(for: missing.url, kind: missing.kind, window: window, completion: completion)
            return
        }

        if urls.count == 1, let source = urls.first {
            switch itemKind(for: source) {
            case .file:
                saveSingleFileSystemItem(source, window: window, completion: completion)
            case .folder:
                saveMultipleFileSystemItems([source], window: window, completion: completion)
            }
        } else {
            saveMultipleFileSystemItems(urls, window: window, completion: completion)
        }
    }

    private static func saveSingleFileSystemItem(_ source: URL, window: NSWindow?, completion: (() -> Void)?) {
        let panel = NSSavePanel()
        panel.title = L10n.tr("save_as.title")
        panel.prompt = L10n.tr("save_as.action")
        panel.nameFieldStringValue = source.lastPathComponent
        panel.canCreateDirectories = true

        present(panel, window: window) { response in
            defer { completion?() }
            guard response == .OK, let destination = panel.url else { return }
            do {
                try copyReplacingExistingItem(from: source, to: destination)
            } catch {
                showSaveError(error, window: window)
            }
        }
    }

    private static func saveMultipleFileSystemItems(_ sources: [URL], window: NSWindow?, completion: (() -> Void)?) {
        let panel = NSOpenPanel()
        panel.title = L10n.tr("save_as.title")
        panel.prompt = L10n.tr("save_as.choose_folder")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        present(panel, window: window) { response in
            defer { completion?() }
            guard response == .OK, let directory = panel.url else { return }
            do {
                for source in sources {
                    let destination = uniqueDestination(
                        for: source.lastPathComponent,
                        in: directory,
                        avoiding: source
                    )
                    try copyItemIfNeeded(from: source, to: destination)
                }
            } catch {
                showSaveError(error, window: window)
            }
        }
    }

    private static func present(_ panel: NSSavePanel, window: NSWindow?, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else if let keyWindow = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: keyWindow, completionHandler: completion)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            completion(panel.runModal())
        }
    }

    private static func writeReplacingExistingItem(data: Data, to destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try data.write(to: destination, options: .atomic)
    }

    private static func copyReplacingExistingItem(from source: URL, to destination: URL) throws {
        guard !sameFileSystemLocation(source, destination) else { return }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try copyItemIfNeeded(from: source, to: destination)
    }

    private static func copyItemIfNeeded(from source: URL, to destination: URL) throws {
        guard !sameFileSystemLocation(source, destination) else { return }

        let didAccessSource = source.startAccessingSecurityScopedResource()
        let didAccessDestination = destination.deletingLastPathComponent().startAccessingSecurityScopedResource()
        defer {
            if didAccessDestination {
                destination.deletingLastPathComponent().stopAccessingSecurityScopedResource()
            }
            if didAccessSource {
                source.stopAccessingSecurityScopedResource()
            }
        }

        try FileManager.default.copyItem(at: source, to: destination)
    }

    private static func uniqueDestination(for fileName: String, in directory: URL, avoiding source: URL) -> URL {
        let fileManager = FileManager.default
        let baseDestination = directory.appendingPathComponent(fileName)
        if !fileManager.fileExists(atPath: baseDestination.path) || sameFileSystemLocation(source, baseDestination) {
            return baseDestination
        }

        let nsName = fileName as NSString
        let baseName = nsName.deletingPathExtension.isEmpty ? fileName : nsName.deletingPathExtension
        let ext = nsName.pathExtension

        for index in 1...999 {
            let candidateName = ext.isEmpty
                ? "\(baseName) copy \(index)"
                : "\(baseName) copy \(index).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        let fallback = directory.appendingPathComponent(UUID().uuidString)
        return ext.isEmpty ? fallback : fallback.appendingPathExtension(ext)
    }

    private static func sameFileSystemLocation(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    private static func firstMissingItem(in urls: [URL]) -> (url: URL, kind: ClipboardFileSystemItemKind)? {
        urls.first { !FileManager.default.fileExists(atPath: $0.path) }.map { url in
            (url, itemKind(for: url))
        }
    }

    private static func itemKind(for url: URL) -> ClipboardFileSystemItemKind {
        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true {
            return .folder
        }
        return url.hasDirectoryPath ? .folder : .file
    }

    private static func imageFileName(preferredName: String?, data: Data) -> String {
        let base = sanitizedFileName(preferredName)
        if base.lowercased().hasSuffix(".png") ||
            base.lowercased().hasSuffix(".jpg") ||
            base.lowercased().hasSuffix(".jpeg") ||
            base.lowercased().hasSuffix(".tiff") {
            return base
        }
        return "\(base).\(imageFileExtension(for: data))"
    }

    private static func imageFileExtension(for data: Data) -> String {
        if hasPrefix(data, [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if hasPrefix(data, [0x49, 0x49, 0x2A, 0x00]) || hasPrefix(data, [0x4D, 0x4D, 0x00, 0x2A]) { return "tiff" }
        return "png"
    }

    private static func hasPrefix(_ data: Data, _ bytes: [UInt8]) -> Bool {
        guard data.count >= bytes.count else { return false }
        return data.prefix(bytes.count).elementsEqual(bytes)
    }

    private static func sanitizedFileName(_ value: String?) -> String {
        let fallback = "SkyPaste Image"
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed?.isEmpty == false ? trimmed ?? fallback : fallback
        let invalidCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = raw
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }

    private static func showMissingItemAlert(
        for url: URL,
        kind: ClipboardFileSystemItemKind,
        window: NSWindow?,
        completion: (() -> Void)? = nil
    ) {
        let alert = NSAlert()
        alert.messageText = kind == .folder
            ? L10n.tr("drag.missing_folder_title")
            : L10n.tr("drag.missing_file_title")
        alert.informativeText = L10n.format("drag.missing_item_message", url.path)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr("menu.ok"))
        present(alert, window: window, completion: completion)
    }

    private static func showSaveError(_ error: Error, window: NSWindow?) {
        let alert = NSAlert(error: error)
        alert.messageText = L10n.tr("save_as.error_title")
        present(alert, window: window)
    }

    private static func present(_ alert: NSAlert, window: NSWindow?, completion: (() -> Void)? = nil) {
        if let window {
            alert.beginSheetModal(for: window) { _ in
                completion?()
            }
        } else if let keyWindow = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: keyWindow) { _ in
                completion?()
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            completion?()
        }
    }
}

extension ClipboardItem {
    var supportsSaveAs: Bool {
        isImage || isFileCollection
    }
}
