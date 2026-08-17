import AppKit
import SwiftUI

@MainActor
final class AppCoordinator {
    let store: ClipboardStore
    let settings: AppSettings
    let cloudSync: CloudClipboardSyncManager

    private let toastModel = GlobalToastModel()
    private var panelWindow: NSWindow?
    private var debugWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var imagePreviewWindow: NSWindow?
    private var textPreviewWindow: NSWindow?
    private var fileSystemPreviewWindow: NSWindow?
    private var toastWindow: NSPanel?
    private var toastHostingController: NSHostingController<GlobalToastView>?
    private var settingsWindowController: NSWindowController?
    private var previousApp: NSRunningApplication?
    private var toastDismissWorkItem: DispatchWorkItem?

    init(settings: AppSettings) {
        self.settings = settings
        let store = ClipboardStore(settings: settings)
        let cloudSync = CloudClipboardSyncManager(store: store, settings: settings)
        self.store = store
        self.cloudSync = cloudSync
        store.onLocalItemAdded = { [weak cloudSync] item in
            Task { @MainActor in
                cloudSync?.uploadLocalItemIfNeeded(item)
            }
        }
    }
}

// MARK: - AppCoordinator Panel

@MainActor
extension AppCoordinator {
    func configureWindow() {
        let rootView = makePanelView()
        let hostingView = NSHostingView(rootView: rootView)

        if let panelWindow {
            panelWindow.title = L10n.tr("app.title")
            panelWindow.contentView = hostingView
            applyAppearance()
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.tr("app.title")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.center()
        panel.contentView = hostingView
        panel.orderOut(nil)

        panelWindow = panel
        applyAppearance()
    }

    private func makePanelView() -> PanelView {
        PanelView(store: store, settings: settings, onPick: { [weak self] item in
            self?.paste(item)
        }, onCopy: { [weak self] item in
            self?.copyOnly(item)
        }, onPreview: { [weak self] item in
            self?.showImagePreview(for: item)
        }, onTextPreview: { [weak self] item in
            self?.showTextPreview(for: item)
        }, onFileSystemPreview: { [weak self] item in
            self?.showFileSystemPreview(for: item)
        }, onOpenFileItem: { [weak self] item in
            self?.openFileSystemItem(for: item)
        }, onOpenContainingFolder: { [weak self] item in
            self?.revealInFinder(for: item)
        }, onCopyFileSystemPath: { [weak self] item in
            self?.copyFileSystemPathString(for: item)
        }, onOpenURL: { [weak self] item in
            self?.openURLInBrowser(for: item)
        }, onOpenEmail: { [weak self] item in
            self?.openEmailComposer(for: item)
        }, onClose: { [weak self] in
            self?.closePanel()
        })
    }

    func togglePanel() {
        guard let panelWindow else { return }

        if panelWindow.isVisible {
            closePanel()
            return
        }

        captureFrontApp()
        showPanel()
    }

    func presentPanelForTesting() {
        configureWindow()
        showPanel()
    }

    private func showPanel() {
        guard let panelWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        panelWindow.makeKeyAndOrderFront(nil)
    }

    func closePanel() {
        guard let panelWindow else { return }
        panelWindow.orderOut(nil)
    }

    func showDebugPanel() {
        let view = PasteboardDebugPanelView()
        let hostingView = NSHostingView(rootView: view)

        if debugWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = L10n.tr("app.debug_title")
            window.center()
            debugWindow = window
        }

        debugWindow?.title = L10n.tr("app.debug_title")
        debugWindow?.contentView = hostingView
        applyAppearance()
        NSApp.activate(ignoringOtherApps: true)
        debugWindow?.makeKeyAndOrderFront(nil)
    }

    var isDebugPanelVisible: Bool {
        debugWindow?.isVisible == true
    }

    var isSettingsWindowVisible: Bool {
        settingsWindow?.isVisible == true
    }
}

// MARK: - AppCoordinator Preview Windows

@MainActor
extension AppCoordinator {
    func showImagePreview(for item: ClipboardItem) {
        guard item.isImage else { return }
        let previewItem = store.itemForPreview(item)
        let rootView = ImagePreviewView(item: previewItem) { [weak self] in
            self?.copyOnly(previewItem)
        }

        if imagePreviewWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 860),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.minSize = NSSize(width: 860, height: 640)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.hidesOnDeactivate = false
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.toolbarStyle = .unifiedCompact
            window.isMovableByWindowBackground = true
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.center()
            imagePreviewWindow = window
        }

        let controller = NSHostingController(rootView: rootView)
        imagePreviewWindow?.title = L10n.tr("preview.title")
        imagePreviewWindow?.contentViewController = controller
        applyAppearance()
        centerWindow(imagePreviewWindow)

        NSApp.activate(ignoringOtherApps: true)
        imagePreviewWindow?.makeKeyAndOrderFront(nil)
        imagePreviewWindow?.orderFrontRegardless()
    }

    func showSettingsWindow() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.minSize = NSSize(width: 700, height: 680)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.toolbarStyle = .preference
            window.isMovableByWindowBackground = true
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.center()
            settingsWindowController = NSWindowController(window: window)
            settingsWindow = window
        }

        let controller = NSHostingController(rootView: SettingsView(settings: settings, store: store, cloudSync: cloudSync))
        settingsWindow?.title = L10n.tr("menu.preferences")
        settingsWindow?.contentViewController = controller
        applyAppearance()

        guard let settingsWindowController else { return }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController.showWindow(nil)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
    }

    func showTextPreview(for item: ClipboardItem) {
        guard let text = item.previewText else { return }
        let rootView = TextPreviewView(
            item: item,
            text: text,
            onCopy: { [weak self] in
                self?.copyOnly(item)
            },
            onOpenURL: item.browserURL != nil ? { [weak self] in
                self?.openURLInBrowser(for: item)
            } : nil,
            onOpenEmail: item.mailtoURL != nil ? { [weak self] in
                self?.openEmailComposer(for: item)
            } : nil
        )

        if textPreviewWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1120, height: 820),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.minSize = NSSize(width: 820, height: 600)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.hidesOnDeactivate = false
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.toolbarStyle = .unifiedCompact
            window.isMovableByWindowBackground = true
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.center()
            textPreviewWindow = window
        }

        let controller = NSHostingController(rootView: rootView)
        textPreviewWindow?.title = L10n.tr("preview.text_title")
        textPreviewWindow?.contentViewController = controller
        applyAppearance()
        centerWindow(textPreviewWindow)

        NSApp.activate(ignoringOtherApps: true)
        textPreviewWindow?.makeKeyAndOrderFront(nil)
        textPreviewWindow?.orderFrontRegardless()
    }

    func showFileSystemPreview(for item: ClipboardItem) {
        guard item.isFileCollection else { return }
        let rootView = FileSystemPreviewView(
            item: item,
            onCopy: { [weak self] in
                self?.copyOnly(item)
            },
            onCopyPath: { [weak self] in
                self?.copyFileSystemPathString(for: item)
            },
            onOpen: { [weak self] in
                self?.openFileSystemItem(for: item)
            },
            onRevealInFinder: { [weak self] in
                self?.revealInFinder(for: item)
            }
        )

        if fileSystemPreviewWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.minSize = NSSize(width: 760, height: 560)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.hidesOnDeactivate = false
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.toolbarStyle = .unifiedCompact
            window.isMovableByWindowBackground = true
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.center()
            fileSystemPreviewWindow = window
        }

        let controller = NSHostingController(rootView: rootView)
        fileSystemPreviewWindow?.title = L10n.tr("preview.file_system_title")
        fileSystemPreviewWindow?.contentViewController = controller
        applyAppearance()
        centerWindow(fileSystemPreviewWindow)

        NSApp.activate(ignoringOtherApps: true)
        fileSystemPreviewWindow?.makeKeyAndOrderFront(nil)
        fileSystemPreviewWindow?.orderFrontRegardless()
    }
}

// MARK: - AppCoordinator Item Actions

@MainActor
extension AppCoordinator {
    func openFileSystemItem(for item: ClipboardItem) {
        guard let urls = item.fileURLs, !urls.isEmpty else { return }

        let fileManager = FileManager.default
        var missingItems: [(url: URL, kind: ClipboardFileSystemItemKind)] = []

        for url in urls {
            let path = url.path
            guard fileManager.fileExists(atPath: path) else {
                missingItems.append((url, itemKind(for: url)))
                continue
            }

            NSWorkspace.shared.open(url)
        }

        guard let firstMissing = missingItems.first else { return }
        showMissingFileSystemItemAlert(for: firstMissing.url, kind: firstMissing.kind)
    }

    func openContainingFolder(for item: ClipboardItem) {
        guard let folderURL = item.containingFolderURL else { return }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: folderURL.path) else {
            showMissingFileSystemItemAlert(for: folderURL, kind: .folder)
            return
        }

        NSWorkspace.shared.open(folderURL)
    }

    func revealInFinder(for item: ClipboardItem) {
        guard let urls = item.fileURLs, !urls.isEmpty else { return }

        let fileManager = FileManager.default
        var missingItems: [(url: URL, kind: ClipboardFileSystemItemKind)] = []
        let existingURLs = urls.filter { url in
            let exists = fileManager.fileExists(atPath: url.path)
            if !exists {
                missingItems.append((url, itemKind(for: url)))
            }
            return exists
        }

        if !existingURLs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(existingURLs)
        }

        guard let firstMissing = missingItems.first else { return }
        showMissingFileSystemItemAlert(for: firstMissing.url, kind: firstMissing.kind)
    }

    func openURLInBrowser(for item: ClipboardItem) {
        guard let url = item.browserURL else { return }
        NSWorkspace.shared.open(url)
    }

    func openEmailComposer(for item: ClipboardItem) {
        guard let url = item.mailtoURL else { return }

        let mailAppURL = URL(fileURLWithPath: "/System/Applications/Mail.app", isDirectory: true)
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: mailAppURL, configuration: configuration) { _, error in
            if error != nil {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func copyFileSystemPathString(for item: ClipboardItem) {
        guard let urls = item.fileURLs, !urls.isEmpty else { return }
        let pathText = urls.map(\.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pathText, forType: .string)
        showGlobalCopyToast()
    }
}

// MARK: - AppCoordinator Clipboard Actions

@MainActor
extension AppCoordinator {
    func copyOnly(_ item: ClipboardItem) {
        store.copyToPasteboard(item)
        showGlobalCopyToast()
    }

    func paste(_ item: ClipboardItem) {
        store.copyToPasteboard(item)
        closePanel()
        previousApp?.activate(options: [])

        guard settings.autoPasteEnabled else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.sendCommandV()
        }
    }

    private func sendCommandV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        keyDown?.flags = .maskCommand

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

}

// MARK: - AppCoordinator Feedback & Helpers

@MainActor
extension AppCoordinator {
    func applyAppearance() {
        let appearance = settings.appearanceMode.nsAppearance
        [panelWindow, debugWindow, settingsWindow, imagePreviewWindow, textPreviewWindow, fileSystemPreviewWindow].forEach { window in
            window?.appearance = appearance
        }
    }

    private func centerWindow(_ window: NSWindow?) {
        guard let window else { return }

        if let screen = NSApp.keyWindow?.screen ?? NSScreen.main {
            let visibleFrame = screen.visibleFrame
            let origin = NSPoint(
                x: visibleFrame.midX - window.frame.width / 2,
                y: visibleFrame.midY - window.frame.height / 2
            )
            window.setFrameOrigin(origin)
        } else {
            window.center()
        }
    }

    private func captureFrontApp() {
        guard let current = NSWorkspace.shared.frontmostApplication else { return }
        if current.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = current
        }
    }

    private func showGlobalCopyToast() {
        if toastWindow == nil {
            toastModel.message = L10n.tr("menu.copy_success")
            let toastView = GlobalToastView(model: toastModel)
            let controller = NSHostingController(rootView: toastView)
            controller.view.wantsLayer = true
            controller.view.layer?.backgroundColor = NSColor.clear.cgColor
            controller.view.layoutSubtreeIfNeeded()
            let fittingSize = controller.view.fittingSize
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: fittingSize.width, height: fittingSize.height),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.ignoresMouseEvents = true
            panel.contentViewController = controller
            controller.view.frame = NSRect(origin: .zero, size: fittingSize)
            toastWindow = panel
            toastHostingController = controller
        } else {
            toastModel.message = L10n.tr("menu.copy_success")
        }

        guard let toastWindow, let toastHostingController else { return }

        toastDismissWorkItem?.cancel()
        toastHostingController.view.layoutSubtreeIfNeeded()
        let fittingSize = toastHostingController.view.fittingSize
        if toastWindow.frame.size != fittingSize {
            toastWindow.setContentSize(fittingSize)
            toastHostingController.view.frame = NSRect(origin: .zero, size: fittingSize)
        }
        positionToastWindow(toastWindow)
        toastWindow.alphaValue = 0
        toastWindow.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            toastWindow.animator().alphaValue = 1
        }

        let dismissWorkItem = DispatchWorkItem { [weak self] in
            guard let self, let toastWindow = self.toastWindow else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                toastWindow.animator().alphaValue = 0
            } completionHandler: {
                toastWindow.orderOut(nil)
            }
        }

        toastDismissWorkItem = dismissWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95, execute: dismissWorkItem)
    }

    private func positionToastWindow(_ window: NSWindow) {
        let screen = panelWindow?.screen ?? NSApp.keyWindow?.screen ?? NSScreen.main
        guard let screen else {
            window.center()
            return
        }

        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.midX - window.frame.width / 2,
            y: visibleFrame.midY - window.frame.height / 2
        )
        window.setFrameOrigin(origin)
    }

    private func itemKind(for url: URL) -> ClipboardFileSystemItemKind {
        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true {
            return .folder
        }
        return url.hasDirectoryPath ? .folder : .file
    }

    private func showMissingFileSystemItemAlert(for url: URL, kind: ClipboardFileSystemItemKind) {
        let alert = NSAlert()
        alert.messageText = kind == .folder
            ? L10n.tr("open.missing_folder_title")
            : L10n.tr("open.missing_file_title")
        alert.informativeText = L10n.format("open.missing_item_message", url.path)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr("menu.ok"))

        if let keyWindow = NSApp.keyWindow {
            alert.beginSheetModal(for: keyWindow)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
