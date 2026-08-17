import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct RowMouseDownObserver: NSViewRepresentable {
    let item: ClipboardItem
    let onPrimaryMouseDown: (() -> Void)?
    let onSecondaryMouseDown: (() -> Void)?
    let onAnchorViewChange: ((NSView?) -> Void)?
    let onDragStateChange: ((Bool) -> Void)?
    let onResolveDragItem: ((ClipboardItem) -> ClipboardItem)?

    func makeNSView(context: Context) -> RowMouseDownObserverView {
        let view = RowMouseDownObserverView()
        view.item = item
        view.onPrimaryMouseDown = onPrimaryMouseDown
        view.onSecondaryMouseDown = onSecondaryMouseDown
        view.onAnchorViewChange = onAnchorViewChange
        view.onDragStateChange = onDragStateChange
        view.onResolveDragItem = onResolveDragItem
        return view
    }

    func updateNSView(_ nsView: RowMouseDownObserverView, context: Context) {
        nsView.item = item
        nsView.onPrimaryMouseDown = onPrimaryMouseDown
        nsView.onSecondaryMouseDown = onSecondaryMouseDown
        nsView.onAnchorViewChange = onAnchorViewChange
        nsView.onDragStateChange = onDragStateChange
        nsView.onResolveDragItem = onResolveDragItem
    }
}

final class RowMouseDownObserverView: NSView, NSDraggingSource {
    var item: ClipboardItem?
    var onPrimaryMouseDown: (() -> Void)?
    var onSecondaryMouseDown: (() -> Void)?
    var onAnchorViewChange: ((NSView?) -> Void)?
    var onDragStateChange: ((Bool) -> Void)?
    var onResolveDragItem: ((ClipboardItem) -> ClipboardItem)?
    private var isRegisteredForEvents = false
    private var mouseDownEvent: NSEvent?
    private var mouseDownLocationInWindow: NSPoint?
    private var hasStartedDrag = false

    override var isFlipped: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            unregisterForEvents()
            onAnchorViewChange?(nil)
        } else {
            onAnchorViewChange?(self)
            registerForEventsIfNeeded()
        }
    }

    deinit {
        onAnchorViewChange?(nil)
        unregisterForEvents()
    }

    fileprivate func handleMouseDownEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            mouseDownEvent = event
            mouseDownLocationInWindow = event.locationInWindow
            hasStartedDrag = false
            onPrimaryMouseDown?()
        case .rightMouseDown:
            cancelPendingDrag()
            onSecondaryMouseDown?()
        case .leftMouseDragged:
            handleLeftMouseDragged(event)
        case .leftMouseUp:
            cancelPendingDrag()
        default:
            break
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        onDragStateChange?(true)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragStateChange?(false)
    }

    private func registerForEventsIfNeeded() {
        guard !isRegisteredForEvents else { return }
        isRegisteredForEvents = true
        RowMouseDownEventCoordinator.shared.register(self)
    }

    private func unregisterForEvents() {
        guard isRegisteredForEvents else { return }
        isRegisteredForEvents = false
        RowMouseDownEventCoordinator.shared.unregister(self)
    }

    private func handleLeftMouseDragged(_ event: NSEvent) {
        guard
            !hasStartedDrag,
            let mouseDownEvent,
            let mouseDownLocationInWindow,
            shouldStartDrag(from: mouseDownLocationInWindow, to: event.locationInWindow),
            let item,
            let payload = ClipboardRowDragPayload(item: onResolveDragItem?(item) ?? item)
        else {
            return
        }

        hasStartedDrag = true

        if let missing = payload.firstMissingItem {
            showMissingItemAlert(for: missing)
            cancelPendingDrag()
            return
        }

        // Anchor the preview stack at the live cursor position: the session may
        // start well after mouse-down (drag threshold + payload preparation), and
        // dragging frames keep their offset from the cursor at session start.
        // A stale mouse-down anchor makes the floating icons trail the cursor.
        guard let anchor = currentMouseLocationInView()
            ?? Optional(convert(mouseDownLocationInWindow, from: nil))
        else {
            cancelPendingDrag()
            return
        }

        guard let draggingItems = payload.makeDraggingItems(anchor: anchor) else {
            cancelPendingDrag()
            return
        }

        let session = beginDraggingSession(with: draggingItems, event: mouseDownEvent, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        cancelPendingDrag()
    }

    private func currentMouseLocationInView() -> NSPoint? {
        guard let window else { return nil }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return convert(windowPoint, from: nil)
    }

    private func shouldStartDrag(from start: NSPoint, to current: NSPoint) -> Bool {
        let dx = current.x - start.x
        let dy = current.y - start.y
        return hypot(dx, dy) >= 4
    }

    private func cancelPendingDrag() {
        mouseDownEvent = nil
        mouseDownLocationInWindow = nil
        hasStartedDrag = false
    }

    private func showMissingItemAlert(for missing: (url: URL, kind: ClipboardFileSystemItemKind)) {
        let alert = NSAlert()
        alert.messageText = missing.kind == .folder
            ? L10n.tr("drag.missing_folder_title")
            : L10n.tr("drag.missing_file_title")
        alert.informativeText = L10n.format("drag.missing_item_message", missing.url.path)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr("menu.ok"))

        if let window {
            alert.beginSheetModal(for: window)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}

private final class RowMouseDownEventCoordinator {
    static let shared = RowMouseDownEventCoordinator()

    private let registeredViews = NSHashTable<RowMouseDownObserverView>.weakObjects()
    private var eventMonitor: Any?
    private weak var activeMouseDownView: RowMouseDownObserverView?

    private init() {}

    func register(_ view: RowMouseDownObserverView) {
        registeredViews.add(view)
        installMonitorIfNeeded()
    }

    func unregister(_ view: RowMouseDownObserverView) {
        registeredViews.remove(view)
        removeMonitorIfPossible()
    }

    private func installMonitorIfNeeded() {
        guard eventMonitor == nil else { return }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.dispatch(event)
            return event
        }
    }

    private func removeMonitorIfPossible() {
        guard registeredViews.allObjects.isEmpty, let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }

    private func dispatch(_ event: NSEvent) {
        if event.type == .leftMouseDragged {
            activeMouseDownView?.handleMouseDownEvent(event)
            return
        }

        if event.type == .leftMouseUp {
            activeMouseDownView?.handleMouseDownEvent(event)
            activeMouseDownView = nil
            return
        }

        guard let eventWindow = event.window else { return }

        for view in registeredViews.allObjects.reversed() {
            guard
                view.window === eventWindow,
                !view.isHiddenOrHasHiddenAncestor,
                view.alphaValue > 0.01
            else {
                continue
            }

            let point = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(point) else { continue }
            view.handleMouseDownEvent(event)
            if event.type == .leftMouseDown {
                activeMouseDownView = view
            }
            return
        }
    }
}

private struct ClipboardRowDragPayload {
    private static let temporaryImageExpiration: TimeInterval = 48 * 60 * 60

    enum PayloadKind {
        case imageFile(URL)
        case fileSystemItems([(url: URL, kind: ClipboardFileSystemItemKind)])
    }

    let kind: PayloadKind

    init?(item: ClipboardItem) {
        switch item.content {
        case .image(let data, let name, _, _):
            guard let url = Self.makeTemporaryImageFile(data: data, preferredName: name, itemID: item.id) else {
                return nil
            }
            kind = .imageFile(url)
        case .fileURLs(let urls, _):
            let items = urls.filter(\.isFileURL).map { url in
                (url: url, kind: Self.itemKind(for: url))
            }
            guard !items.isEmpty else { return nil }
            kind = .fileSystemItems(items)
        case .text:
            // Intentionally no drag-out for text, URLs, emails, and code snippets:
            // only images and file system items can be dragged from the list.
            return nil
        }
    }

    var firstMissingItem: (url: URL, kind: ClipboardFileSystemItemKind)? {
        switch kind {
        case .imageFile(let url):
            return FileManager.default.fileExists(atPath: url.path) ? nil : (url, .file)
        case .fileSystemItems(let items):
            return items.first { item in
                !FileManager.default.fileExists(atPath: item.url.path)
            }
        }
    }

    var dragURLs: [URL] {
        switch kind {
        case .imageFile(let url):
            return [url]
        case .fileSystemItems(let items):
            return items.map(\.url)
        }
    }

    func makeDraggingItems(anchor: NSPoint) -> [NSDraggingItem]? {
        guard firstMissingItem == nil else { return nil }

        let urls = dragURLs
        guard !urls.isEmpty else { return nil }

        return ClipboardDragPreviewComposer.makeDraggingItems(for: urls, anchor: anchor)
    }

    private static func makeTemporaryImageFile(data: Data, preferredName: String?, itemID: UUID) -> URL? {
        guard !data.isEmpty else { return nil }

        let fileManager = FileManager.default
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SkyPasteDragItems", isDirectory: true)

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            removeExpiredTemporaryFiles(in: directory, fileManager: fileManager)
        } catch {
            return nil
        }

        // Write the original bytes untouched whenever the format is recognized:
        // re-encoding large images on the main thread delays the drag session
        // start, which makes the preview feel detached from the cursor.
        let baseName = sanitizedFileName(preferredName)
        let writableData: Data
        let fileExtension: String

        switch sniffedImageFormat(data) {
        case .png:
            writableData = data
            fileExtension = "png"
        case .jpeg:
            writableData = data
            fileExtension = "jpg"
        case .tiff:
            writableData = data
            fileExtension = "tiff"
        case nil:
            guard let converted = pngData(from: data) else { return nil }
            writableData = converted
            fileExtension = "png"
        }

        let url = directory.appendingPathComponent("\(baseName)-\(itemID.uuidString).\(fileExtension)")

        do {
            if needsWrite(of: writableData, to: url, fileManager: fileManager) {
                try writableData.write(to: url, options: .atomic)
            }
            return url
        } catch {
            return nil
        }
    }

    private enum SniffedImageFormat {
        case png
        case jpeg
        case tiff
    }

    private static func sniffedImageFormat(_ data: Data) -> SniffedImageFormat? {
        if isPNGData(data) { return .png }
        if isJPEGData(data) { return .jpeg }
        if isTIFFData(data) { return .tiff }
        return nil
    }

    private static func hasPrefix(_ data: Data, _ bytes: [UInt8]) -> Bool {
        guard data.count >= bytes.count else { return false }
        return data.prefix(bytes.count).elementsEqual(bytes)
    }

    private static func isPNGData(_ data: Data) -> Bool {
        hasPrefix(data, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    private static func isJPEGData(_ data: Data) -> Bool {
        hasPrefix(data, [0xFF, 0xD8, 0xFF])
    }

    private static func isTIFFData(_ data: Data) -> Bool {
        hasPrefix(data, [0x49, 0x49, 0x2A, 0x00]) || hasPrefix(data, [0x4D, 0x4D, 0x00, 0x2A])
    }

    private static func needsWrite(of data: Data, to url: URL, fileManager: FileManager) -> Bool {
        guard
            let attributes = try? fileManager.attributesOfItem(atPath: url.path),
            let existingSize = attributes[.size] as? Int
        else {
            return true
        }
        return existingSize != data.count
    }

    private static func pngData(from data: Data) -> Data? {
        guard
            let image = NSImage(data: data),
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            return nil
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .png, properties: [:])
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

    private static func removeExpiredTemporaryFiles(in directory: URL, fileManager: FileManager) {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let expirationDate = Date().addingTimeInterval(-temporaryImageExpiration)
        for url in urls {
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if modified.map({ $0 < expirationDate }) ?? false {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private static func itemKind(for url: URL) -> ClipboardFileSystemItemKind {
        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true {
            return .folder
        }
        return url.hasDirectoryPath ? .folder : .file
    }
}

/// Builds Finder-style drag previews: one icon per file (stacked diagonally, up to a
/// visible cap), a count badge when dragging multiple items, and image thumbnails
/// instead of generic icons for image files.
private enum ClipboardDragPreviewComposer {
    private static let iconSize: CGFloat = 56
    private static let stackOffset: CGFloat = 13
    private static let maxVisibleIcons = 3
    private static let badgeDiameter: CGFloat = 19

    static func makeDraggingItems(for urls: [URL], anchor: NSPoint) -> [NSDraggingItem] {
        return urls.enumerated().map { index, url in
            let draggingItem = NSDraggingItem(pasteboardWriter: url as NSURL)

            if index < maxVisibleIcons {
                let offset = CGFloat(index) * stackOffset
                let frame = NSRect(
                    x: anchor.x - iconSize / 2 + offset,
                    y: anchor.y - iconSize / 2 - offset,
                    width: iconSize,
                    height: iconSize
                )
                let badgeCount = (index == 0 && urls.count > 1) ? urls.count : nil
                draggingItem.setDraggingFrame(frame, contents: makePreviewImage(for: url, badgeCount: badgeCount))
            } else {
                // Extra items stay on the pasteboard but contribute no visible preview.
                let frame = NSRect(
                    x: anchor.x - 0.5,
                    y: anchor.y - 0.5,
                    width: 1,
                    height: 1
                )
                draggingItem.setDraggingFrame(frame, contents: NSImage(size: frame.size))
            }

            return draggingItem
        }
    }

    private static func makePreviewImage(for url: URL, badgeCount: Int?) -> NSImage {
        let canvasSize = NSSize(width: iconSize, height: iconSize)
        let baseImage = thumbnailImage(for: url)

        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(canvasSize.width) * 2,
                pixelsHigh: Int(canvasSize.height) * 2,
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
            return baseImage
        }
        rep.size = canvasSize

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        let canvasRect = NSRect(origin: .zero, size: canvasSize)
        let fittedRect = fittedRect(for: baseImage.size, in: canvasRect)

        if isImageFileURL(url) {
            let clipPath = NSBezierPath(roundedRect: fittedRect, xRadius: 9, yRadius: 9)
            clipPath.addClip()
            baseImage.draw(in: fittedRect, from: .zero, operation: .copy, fraction: 1)

            let borderPath = NSBezierPath(roundedRect: fittedRect.insetBy(dx: -0.5, dy: -0.5), xRadius: 9.5, yRadius: 9.5)
            borderPath.lineWidth = 1
            NSColor.black.withAlphaComponent(0.12).setStroke()
            borderPath.stroke()
        } else {
            baseImage.draw(in: fittedRect, from: .zero, operation: .copy, fraction: 1)
        }

        if let badgeCount {
            drawCountBadge(count: badgeCount, in: canvasRect)
        }

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: canvasSize)
        image.addRepresentation(rep)
        return image
    }

    private static func thumbnailImage(for url: URL) -> NSImage {
        if isImageFileURL(url), let thumbnail = imageThumbnail(at: url) {
            return thumbnail
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private static func imageThumbnail(at url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func drawCountBadge(count: Int, in canvasRect: NSRect) {
        let badgeRect = NSRect(
            x: canvasRect.maxX - badgeDiameter - 1,
            y: 1,
            width: badgeDiameter,
            height: badgeDiameter
        )

        let badgePath = NSBezierPath(ovalIn: badgeRect)
        NSColor.controlAccentColor.setFill()
        badgePath.fill()
        NSColor.white.setStroke()
        badgePath.lineWidth = 1.5
        badgePath.stroke()

        let text = "\(count)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: attributes)
        let textRect = NSRect(
            x: badgeRect.midX - textSize.width / 2,
            y: badgeRect.midY - textSize.height / 2,
            width: textSize.width,
            height: textSize.height
        )
        text.draw(in: textRect, withAttributes: attributes)
    }

    private static func fittedRect(for imageSize: NSSize, in canvasRect: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return NSRect(origin: .zero, size: canvasRect.size)
        }

        let scale = min(canvasRect.width / imageSize.width, canvasRect.height / imageSize.height)
        let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return NSRect(
            x: canvasRect.midX - size.width / 2,
            y: canvasRect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func isImageFileURL(_ url: URL) -> Bool {
        guard !url.pathExtension.isEmpty else { return false }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }
}
