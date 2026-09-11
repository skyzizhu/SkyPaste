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

        guard let export = imageExportPayload(from: data) else {
            showSaveError(imagePNGEncodingError(), window: window)
            completion?()
            return
        }

        let panel = NSSavePanel()
        panel.title = L10n.tr("save_as.title")
        panel.prompt = L10n.tr("save_as.action")
        panel.nameFieldStringValue = imageFileName(preferredName: preferredName, fileExtension: export.fileExtension)
        panel.allowedContentTypes = [export.contentType]
        panel.canCreateDirectories = true

        present(panel, window: window) { response in
            defer { completion?() }
            guard response == .OK, let destination = panel.url else { return }
            do {
                try writeReplacingExistingItem(data: export.data, to: destination)
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

    private static func imageFileName(preferredName: String?, fileExtension: String) -> String {
        let base = sanitizedFileName(preferredName)
        let nameWithoutExtension = (base as NSString).deletingPathExtension
        if nameWithoutExtension.isEmpty {
            return "SkyPaste Image.\(fileExtension)"
        }
        return "\(nameWithoutExtension).\(fileExtension)"
    }

    private struct ImageExportPayload {
        let data: Data
        let fileExtension: String
        let contentType: UTType
    }

    private static func imageExportPayload(from data: Data) -> ImageExportPayload? {
        if hasPrefix(data, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return ImageExportPayload(data: data, fileExtension: "png", contentType: .png)
        }

        guard let image = NSImage(data: data) else {
            return nil
        }

        if let png = pngData(from: image) {
            return ImageExportPayload(data: png, fileExtension: "png", contentType: .png)
        }

        if let tiff = image.tiffRepresentation, !tiff.isEmpty {
            return ImageExportPayload(data: tiff, fileExtension: "tiff", contentType: .tiff)
        }

        if let jpeg = jpegData(from: image) {
            return ImageExportPayload(data: jpeg, fileExtension: "jpg", contentType: .jpeg)
        }

        return nil
    }

    private static func pngData(from image: NSImage) -> Data? {
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            if let data = bitmap.representation(using: .png, properties: [:]), !data.isEmpty {
                return data
            }
        }

        let size = bestRasterSize(for: image)
        guard size.width > 0, size.height > 0 else {
            return nil
        }

        guard
            let bitmap = NSBitmapImageRep(
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
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        guard let data = bitmap.representation(using: .png, properties: [:]), !data.isEmpty else {
            return nil
        }
        return data
    }

    private static func jpegData(from image: NSImage) -> Data? {
        guard
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            return nil
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
    }

    private static func bestRasterSize(for image: NSImage) -> NSSize {
        if image.size.width > 0, image.size.height > 0 {
            return image.size
        }

        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return NSSize(width: cgImage.width, height: cgImage.height)
        }

        return .zero
    }

    private static func imagePNGEncodingError() -> NSError {
        NSError(
            domain: "com.huaibor.skypaste.save-as",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "SkyPaste could not convert this image to PNG."
            ]
        )
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
