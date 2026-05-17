import AppKit
import SwiftUI

@MainActor
final class AppCoordinator {
    let store: ClipboardStore
    let settings: AppSettings
    let cloudSync: CloudClipboardSyncManager

    private var panelWindow: NSWindow?
    private var debugWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var imagePreviewWindow: NSWindow?
    private var textPreviewWindow: NSWindow?
    private var fileSystemPreviewWindow: NSWindow?
    private var settingsWindowController: NSWindowController?
    private var previousApp: NSRunningApplication?

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
        let rootView = PanelView(store: store, settings: settings, onPick: { [weak self] item in
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
        }, onClose: { [weak self] in
            self?.closePanel()
        })
        return rootView
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

        let controller = NSHostingController(rootView: SettingsView(settings: settings, cloudSync: cloudSync))
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
        let rootView = TextPreviewView(item: item, text: text) { [weak self] in
            self?.copyOnly(item)
        }

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
            onRevealInFinder: item.isSingleFile ? { [weak self] in
                self?.revealInFinder(for: item)
            } : nil
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

    func copyFileSystemPathString(for item: ClipboardItem) {
        guard let urls = item.fileURLs, !urls.isEmpty else { return }
        let pathText = urls.map(\.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pathText, forType: .string)
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

    func applyAppearance() {
        let appearance = settings.appearanceMode.nsAppearance
        [panelWindow, debugWindow, settingsWindow, imagePreviewWindow, textPreviewWindow, fileSystemPreviewWindow].forEach { window in
            window?.appearance = appearance
        }
    }

    private func captureFrontApp() {
        guard let current = NSWorkspace.shared.frontmostApplication else { return }
        if current.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = current
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

    func copyOnly(_ item: ClipboardItem) {
        store.copyToPasteboard(item)
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let settings = AppSettings.shared
    private lazy var coordinator = AppCoordinator(settings: settings)

    private var monitor: ClipboardMonitor?
    private let hotKeyManager = HotKeyManager()
    private var statusItem: NSStatusItem?
    private var statusPopover: NSPopover?
    private var localPopoverMonitor: Any?
    private var globalPopoverMonitor: Any?
    private var appDeactivationObserver: NSObjectProtocol?
    private var hotKeyObserver: NSObjectProtocol?
    private var languageObserver: NSObjectProtocol?
    private var iCloudSyncObserver: NSObjectProtocol?
    private var appearanceObserver: NSObjectProtocol?

    private var isRunningUITests: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitesting")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyAppearance()
        coordinator.configureWindow()

        if isRunningUITests {
            NSApp.setActivationPolicy(.regular)
            coordinator.presentPanelForTesting()
            return
        }

        NSApp.setActivationPolicy(.accessory)
        coordinator.store.captureCurrentPasteboardIfNeeded()

        monitor = ClipboardMonitor { [weak coordinator] acceptsLocalContent in
            Task { @MainActor in
                coordinator?.store.captureCurrentPasteboardIfNeeded(acceptsLocalContent: acceptsLocalContent)
            }
        }
        monitor?.start()
        coordinator.cloudSync.applyCurrentSetting()

        applyHotKeyRegistration()
        observeSettingsChanges()
        setupStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        coordinator.cloudSync.stop()
        hotKeyManager.unregister()

        if let hotKeyObserver {
            NotificationCenter.default.removeObserver(hotKeyObserver)
            self.hotKeyObserver = nil
        }

        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
            self.languageObserver = nil
        }

        if let iCloudSyncObserver {
            NotificationCenter.default.removeObserver(iCloudSyncObserver)
            self.iCloudSyncObserver = nil
        }

        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
            self.appearanceObserver = nil
        }

        if let appDeactivationObserver {
            NotificationCenter.default.removeObserver(appDeactivationObserver)
            self.appDeactivationObserver = nil
        }

        removePopoverAutoCloseMonitors()
    }

    private func applyHotKeyRegistration() {
        let binding = settings.hotKeyBinding
        hotKeyManager.register(keyCode: binding.keyCode, modifiers: binding.modifiers) { [weak coordinator] in
            coordinator?.togglePanel()
        }
    }

    private func observeSettingsChanges() {
        hotKeyObserver = NotificationCenter.default.addObserver(
            forName: .hotKeySettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyHotKeyRegistration()
            }
        }

        languageObserver = NotificationCenter.default.addObserver(
            forName: .languageSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshLocalizedUI()
            }
        }

        iCloudSyncObserver = NotificationCenter.default.addObserver(
            forName: .iCloudSyncSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.coordinator.cloudSync.applyCurrentSetting()
            }
        }

        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .appearanceSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyAppearance()
            }
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = ""
        item.button?.image = statusBarImage()
        item.button?.imagePosition = .imageOnly
        item.button?.target = self
        item.button?.action = #selector(toggleStatusPopover)

        statusItem = item
        configureStatusPopover()
    }

    private func refreshLocalizedUI() {
        let oldPopover = statusPopover
        let wasPopoverShown = statusPopover?.isShown == true
        let statusButton = statusItem?.button

        if wasPopoverShown {
            oldPopover?.performClose(nil)
        }

        statusItem?.button?.title = ""
        statusItem?.button?.image = statusBarImage()
        statusItem?.button?.imagePosition = .imageOnly
        coordinator.configureWindow()
        if coordinator.isDebugPanelVisible {
            coordinator.showDebugPanel()
        }
        if coordinator.isSettingsWindowVisible {
            coordinator.showSettingsWindow()
        }
        configureStatusPopover()

        if wasPopoverShown, let statusButton, let statusPopover {
            statusPopover.show(relativeTo: statusButton.bounds, of: statusButton, preferredEdge: .minY)
        }
    }

    private func statusBarImage() -> NSImage? {
        guard let appIcon = NSApp.applicationIconImage.copy() as? NSImage else { return nil }

        let iconSide = max(19, NSStatusBar.system.thickness - 2)
        let targetSize = NSSize(width: iconSide, height: iconSide)
        let canvasRect = NSRect(origin: .zero, size: targetSize)
        let statusImage = NSImage(size: targetSize)

        statusImage.lockFocus()
        NSColor.clear.setFill()
        canvasRect.fill()

        appIcon.draw(
            in: canvasRect,
            from: NSRect(origin: .zero, size: appIcon.size),
            operation: .sourceOver,
            fraction: 1
        )
        statusImage.unlockFocus()
        statusImage.size = targetSize

        statusImage.isTemplate = false
        return statusImage
    }

    private func configureStatusPopover() {
        let view = MenuBarClipboardView(
            store: coordinator.store,
            settings: settings,
            onPick: { [weak self] item in
                self?.closeStatusPopover()
                self?.coordinator.paste(item)
            },
            onCopy: { [weak self] item in
                self?.coordinator.copyOnly(item)
            },
            onPreview: { [weak self] item in
                self?.closeStatusPopover()
                self?.coordinator.showImagePreview(for: item)
            },
            onTextPreview: { [weak self] item in
                self?.closeStatusPopover()
                self?.coordinator.showTextPreview(for: item)
            },
            onFileSystemPreview: { [weak self] item in
                self?.closeStatusPopover()
                self?.coordinator.showFileSystemPreview(for: item)
            },
            onOpenFileItem: { [weak self] item in
                self?.closeStatusPopover()
                self?.coordinator.openFileSystemItem(for: item)
            },
            onOpenContainingFolder: { [weak self] item in
                self?.closeStatusPopover()
                self?.coordinator.revealInFinder(for: item)
            },
            onCopyFileSystemPath: { [weak self] item in
                self?.coordinator.copyFileSystemPathString(for: item)
            },
            onOpenURL: { [weak self] item in
                self?.closeStatusPopover()
                self?.coordinator.openURLInBrowser(for: item)
            },
            onOpenPanel: { [weak self] in
                self?.closeStatusPopover()
                self?.coordinator.togglePanel()
            },
            onOpenPreferences: { [weak self] in
                self?.closeStatusPopover()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self?.openPreferences()
                }
            },
            onQuit: { [weak self] in
                self?.quitApp()
            }
        )

        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.delegate = self
        popover.contentSize = NSSize(width: 360, height: 460)
        let controller = FirstMouseHostingController(rootView: view)
        controller.view.appearance = settings.appearanceMode.nsAppearance
        popover.contentViewController = controller
        statusPopover = popover
    }

    private func applyAppearance() {
        let appearance = settings.appearanceMode.nsAppearance
        NSApp.appearance = appearance
        coordinator.applyAppearance()
        statusPopover?.contentViewController?.view.appearance = appearance
        statusPopover?.contentViewController?.view.window?.appearance = appearance
    }

    @objc private func toggleStatusPopover() {
        guard let button = statusItem?.button, let popover = statusPopover else { return }

        if popover.isShown {
            closeStatusPopover()
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            installPopoverAutoCloseMonitors()
        }
    }

    private func closeStatusPopover() {
        statusPopover?.performClose(nil)
        removePopoverAutoCloseMonitors()
    }

    private func installPopoverAutoCloseMonitors() {
        guard localPopoverMonitor == nil, globalPopoverMonitor == nil else { return }

        localPopoverMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            guard let popover = self.statusPopover, popover.isShown else { return event }

            let popoverWindow = popover.contentViewController?.view.window
            let statusWindow = self.statusItem?.button?.window
            if event.window === popoverWindow || event.window === statusWindow {
                return event
            }

            self.closeStatusPopover()
            return event
        }

        globalPopoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.closeStatusPopover()
            }
        }

        if appDeactivationObserver == nil {
            appDeactivationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.closeStatusPopover()
                }
            }
        }
    }

    private func removePopoverAutoCloseMonitors() {
        if let localPopoverMonitor {
            NSEvent.removeMonitor(localPopoverMonitor)
            self.localPopoverMonitor = nil
        }

        if let globalPopoverMonitor {
            NSEvent.removeMonitor(globalPopoverMonitor)
            self.globalPopoverMonitor = nil
        }
    }

    func popoverDidClose(_ notification: Notification) {
        removePopoverAutoCloseMonitors()
    }

    @objc private func openPreferences() {
        coordinator.showSettingsWindow()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

private struct ImagePreviewView: View {
    @Environment(\.colorScheme) private var colorScheme
    let item: ClipboardItem
    let onCopy: () -> Void
    @State private var zoomScale: CGFloat = 1
    @GestureState private var gestureScale: CGFloat = 1

    private var image: NSImage? {
        item.previewImage
    }

    var body: some View {
        let liveScale = clampedScale(zoomScale * gestureScale)

        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("preview.title"))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(item.subtitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    Button(action: onCopy) {
                        Label(L10n.tr("menu.copy"), systemImage: "doc.on.doc")
                    }

                    Button {
                        zoomScale = clampedScale(zoomScale - 0.2)
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }

                    Button {
                        zoomScale = 1
                    } label: {
                        Text("\(Int(liveScale * 100))%")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }

                    Button {
                        zoomScale = clampedScale(zoomScale + 0.2)
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(.ultraThinMaterial)

            Divider()

            GeometryReader { proxy in
                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: colorScheme == .dark
                                    ? [
                                        Color.white.opacity(0.04),
                                        Color(nsColor: .controlBackgroundColor)
                                    ]
                                    : [
                                        Color.black.opacity(0.05),
                                        Color.white.opacity(0.52)
                                    ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                        }

                    if let image {
                        let fittedSize = fittedImageSize(
                            imageSize: image.size,
                            availableSize: CGSize(
                                width: max(proxy.size.width - 120, 280),
                                height: max(proxy.size.height - 120, 280)
                            )
                        )

                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .frame(
                                width: max(120, fittedSize.width * liveScale),
                                height: max(120, fittedSize.height * liveScale)
                            )
                            .shadow(color: .black.opacity(0.08), radius: 14, y: 8)
                    } else {
                        ContentUnavailableView(
                            L10n.tr("preview.unavailable"),
                            systemImage: "photo",
                            description: Text(L10n.tr("preview.unavailable_message"))
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(24)
                .gesture(magnifyGesture)
                .clipped()
                .background(
                    LinearGradient(
                        colors: [
                            Color(nsColor: .windowBackgroundColor),
                            Color.accentColor.opacity(0.06)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func fittedImageSize(imageSize: CGSize, availableSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGSize(width: 240, height: 240)
        }

        let widthScale = availableSize.width / imageSize.width
        let heightScale = availableSize.height / imageSize.height
        let scale = min(widthScale, heightScale, 1)

        return CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .updating($gestureScale) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                zoomScale = clampedScale(zoomScale * value.magnification)
            }
    }

    private func clampedScale(_ value: CGFloat) -> CGFloat {
        min(max(value, 0.4), 5)
    }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private final class FirstMouseHostingController<Content: View>: NSHostingController<Content> {
    override func loadView() {
        view = FirstMouseHostingView(rootView: rootView)
    }
}

private struct TextPreviewView: View {
    let item: ClipboardItem
    let text: String
    let onCopy: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("preview.text_title"))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text(item.subtitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: onCopy) {
                    Label(L10n.tr("menu.copy"), systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(.ultraThinMaterial)

            Divider()

            ScrollView {
                Text(text)
                    .font(.system(size: item.isCode ? 13 : 14, weight: .regular, design: item.isCode ? .monospaced : .default))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
            .background(
                LinearGradient(
                    colors: [
                        Color(nsColor: .windowBackgroundColor),
                        Color.accentColor.opacity(0.05)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        .frame(minWidth: 680, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor
final class FileSystemPreviewModel: ObservableObject {
    enum State {
        case loading
        case loaded(FileSystemPreviewSnapshot)
    }

    @Published private(set) var state: State = .loading
    private let item: ClipboardItem

    init(item: ClipboardItem) {
        self.item = item
        load()
    }

    private func load() {
        let item = item
        Task.detached(priority: .userInitiated) {
            let snapshot = FileSystemPreviewSnapshot.build(for: item)
            await MainActor.run {
                self.state = .loaded(snapshot)
            }
        }
    }
}

struct FileSystemPreviewSnapshot: Equatable {
    let representedURLs: [URL]
    let availableURLs: [URL]
    let missingURLs: [URL]
    let displayName: String
    let kind: ClipboardFileSystemItemKind?
    let typeDescription: String
    let sizeBytes: Int64?
    let sizeText: String
    let pathText: String
    let itemCount: Int?
    let directoryEntries: [FileSystemPreviewDirectoryEntry]

    var isMissing: Bool {
        availableURLs.isEmpty
    }

    var shouldShowContents: Bool {
        !directoryEntries.isEmpty || kind == .folder || representedURLs.count > 1
    }

    static func build(for item: ClipboardItem) -> FileSystemPreviewSnapshot {
        let urls = item.fileURLs ?? []
        let fileManager = FileManager.default
        let availableURLs = urls.filter { fileManager.fileExists(atPath: $0.path) }
        let missingURLs = urls.filter { !fileManager.fileExists(atPath: $0.path) }

        if let singleURL = urls.first, urls.count == 1 {
            let kind = item.singleFileSystemItemKind ?? fileSystemKind(for: singleURL)
            let displayName = singleURL.lastPathComponent
            let typeDescription = typeDescription(for: singleURL, fallbackKind: kind)
            let pathText = singleURL.path

            switch kind {
            case .folder:
                let entries = availableURLs.isEmpty ? [] : immediateEntries(in: singleURL)
                let sizeBytes = availableURLs.isEmpty ? nil : recursiveSize(of: singleURL)
                return FileSystemPreviewSnapshot(
                    representedURLs: urls,
                    availableURLs: availableURLs,
                    missingURLs: missingURLs,
                    displayName: displayName,
                    kind: .folder,
                    typeDescription: typeDescription,
                    sizeBytes: sizeBytes,
                    sizeText: sizeBytes.map(formatByteCount) ?? L10n.tr("preview.file_system_unavailable"),
                    pathText: pathText,
                    itemCount: availableURLs.isEmpty ? nil : entries.count,
                    directoryEntries: entries
                )
            case .file:
                let sizeBytes = availableURLs.isEmpty ? nil : fileSize(of: singleURL)
                return FileSystemPreviewSnapshot(
                    representedURLs: urls,
                    availableURLs: availableURLs,
                    missingURLs: missingURLs,
                    displayName: displayName,
                    kind: .file,
                    typeDescription: typeDescription,
                    sizeBytes: sizeBytes,
                    sizeText: sizeBytes.map(formatByteCount) ?? L10n.tr("preview.file_system_unavailable"),
                    pathText: pathText,
                    itemCount: nil,
                    directoryEntries: []
                )
            }
        }

        let representedKinds = urls.map(fileSystemKind(for:))
        let distinctKinds = Set(representedKinds.map { $0 == .folder ? "folder" : "file" })
        let kind: ClipboardFileSystemItemKind? = distinctKinds.count == 1 ? representedKinds.first : nil
        let sizeBytes = availableURLs.isEmpty ? nil : availableURLs.reduce(Int64(0)) { partial, url in
            partial + totalSize(of: url)
        }

        return FileSystemPreviewSnapshot(
            representedURLs: urls,
            availableURLs: availableURLs,
            missingURLs: missingURLs,
            displayName: item.title,
            kind: kind,
            typeDescription: kind.map { $0 == .folder ? L10n.tr("preview.file_system_type_folder") : L10n.tr("preview.file_system_type_file") } ?? L10n.tr("preview.file_system_type_mixed"),
            sizeBytes: sizeBytes,
            sizeText: sizeBytes.map(formatByteCount) ?? L10n.tr("preview.file_system_unavailable"),
            pathText: L10n.tr("preview.file_system_multiple_locations"),
            itemCount: urls.count,
            directoryEntries: urls.map(selectionEntry(for:))
        )
    }

    private static func selectionEntry(for url: URL) -> FileSystemPreviewDirectoryEntry {
        let kind = fileSystemKind(for: url)
        return FileSystemPreviewDirectoryEntry(
            url: url,
            name: url.lastPathComponent,
            kind: kind,
            detailText: kind == .folder ? L10n.tr("preview.file_system_type_folder") : typeDescription(for: url, fallbackKind: .file),
            sizeText: kind == .folder ? nil : fileSize(of: url).map(formatByteCount)
        )
    }

    private static func immediateEntries(in directoryURL: URL) -> [FileSystemPreviewDirectoryEntry] {
        let fileManager = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .localizedTypeDescriptionKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey
        ]
        let childURLs = withSecurityScopedAccess(to: directoryURL) {
            try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: []
            )
        }
        guard let childURLs else {
            return []
        }

        return childURLs
            .sorted { lhs, rhs in
                let lhsKind = fileSystemKind(for: lhs)
                let rhsKind = fileSystemKind(for: rhs)
                if lhsKind != rhsKind {
                    return lhsKind == .folder
                }
                return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }
            .map { url in
                let kind = fileSystemKind(for: url)
                return FileSystemPreviewDirectoryEntry(
                    url: url,
                    name: url.lastPathComponent,
                    kind: kind,
                    detailText: typeDescription(for: url, fallbackKind: kind),
                    sizeText: kind == .folder ? nil : fileSize(of: url).map(formatByteCount)
                )
            }
    }

    private static func totalSize(of url: URL) -> Int64 {
        switch fileSystemKind(for: url) {
        case .file:
            return fileSize(of: url) ?? 0
        case .folder:
            return recursiveSize(of: url) ?? 0
        }
    }

    private static func fileSize(of url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .totalFileSizeKey,
            .fileSizeKey
        ]
        let values = withSecurityScopedAccess(to: url) {
            try? url.resourceValues(forKeys: keys)
        }
        guard let values else { return nil }
        if let value = values.totalFileSize { return Int64(value) }
        if let value = values.fileSize { return Int64(value) }
        if let value = values.totalFileAllocatedSize { return Int64(value) }
        if let value = values.fileAllocatedSize { return Int64(value) }
        return nil
    }

    private static func recursiveSize(of directoryURL: URL) -> Int64? {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .totalFileSizeKey,
            .fileSizeKey
        ]
        return withSecurityScopedAccess(to: directoryURL) {
            guard let enumerator = fileManager.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: keys,
                options: [],
                errorHandler: { _, _ in true }
            ) else {
                return nil
            }

            var total: Int64 = 0
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    continue
                }
                if let value = values?.totalFileSize {
                    total += Int64(value)
                } else if let value = values?.fileSize {
                    total += Int64(value)
                } else if let value = values?.totalFileAllocatedSize {
                    total += Int64(value)
                } else if let value = values?.fileAllocatedSize {
                    total += Int64(value)
                }
            }

            return total
        }
    }

    private static func typeDescription(for url: URL, fallbackKind: ClipboardFileSystemItemKind?) -> String {
        if fallbackKind == .folder {
            return L10n.tr("preview.file_system_type_folder")
        }

        if let values = withSecurityScopedAccess(to: url, {
            try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey])
        }),
           let localizedTypeDescription = values.localizedTypeDescription,
           !localizedTypeDescription.isEmpty {
            return localizedTypeDescription
        }

        switch fallbackKind {
        case .folder:
            return L10n.tr("preview.file_system_type_folder")
        case .file:
            return L10n.tr("preview.file_system_type_file")
        case nil:
            return L10n.tr("preview.file_system_type_mixed")
        }
    }

    private static func fileSystemKind(for url: URL) -> ClipboardFileSystemItemKind {
        if let values = withSecurityScopedAccess(to: url, {
            try? url.resourceValues(forKeys: [.isDirectoryKey])
        }), values.isDirectory == true {
            return .folder
        }
        return url.hasDirectoryPath ? .folder : .file
    }

    private static func formatByteCount(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    private static func withSecurityScopedAccess<T>(to url: URL, _ work: () -> T) -> T {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return work()
    }
}

struct FileSystemPreviewDirectoryEntry: Identifiable, Equatable {
    let url: URL
    let name: String
    let kind: ClipboardFileSystemItemKind
    let detailText: String
    let sizeText: String?

    var id: String { url.path }
}

private struct FileSystemPreviewView: View {
    let item: ClipboardItem
    let onCopy: () -> Void
    let onCopyPath: () -> Void
    let onOpen: () -> Void
    let onRevealInFinder: (() -> Void)?
    @StateObject private var model: FileSystemPreviewModel

    init(
        item: ClipboardItem,
        onCopy: @escaping () -> Void,
        onCopyPath: @escaping () -> Void,
        onOpen: @escaping () -> Void,
        onRevealInFinder: (() -> Void)? = nil
    ) {
        self.item = item
        self.onCopy = onCopy
        self.onCopyPath = onCopyPath
        self.onOpen = onOpen
        self.onRevealInFinder = onRevealInFinder
        _model = StateObject(wrappedValue: FileSystemPreviewModel(item: item))
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            Group {
                switch model.state {
                case .loading:
                    loadingView
                case .loaded(let snapshot):
                    contentView(for: snapshot)
                }
            }
            .background(
                LinearGradient(
                    colors: [
                        Color(nsColor: .windowBackgroundColor),
                        Color.accentColor.opacity(0.05)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("preview.file_system_title"))
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.subtitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            HStack(spacing: 8) {
                Button(action: onCopy) {
                    Label(L10n.tr("menu.copy"), systemImage: "doc.on.doc")
                }
                .fixedSize()

                Button(action: onCopyPath) {
                    Label(L10n.tr("menu.copy_path"), systemImage: "text.alignleft")
                }
                .fixedSize()

                Button(action: onOpen) {
                    Label(item.openActionTitle, systemImage: item.singleFileSystemItemKind == .folder ? "folder" : "arrow.up.right.square")
                }
                .fixedSize()

                if let onRevealInFinder {
                    Button(action: onRevealInFinder) {
                        Label(L10n.tr("menu.reveal_in_finder"), systemImage: "folder.badge.gearshape")
                    }
                    .fixedSize()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .layoutPriority(1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial)
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(L10n.tr("preview.file_system_loading"))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func contentView(for snapshot: FileSystemPreviewSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !snapshot.missingURLs.isEmpty {
                    missingItemsBanner(snapshot.missingURLs)
                }

                infoSection(snapshot)

                if snapshot.shouldShowContents {
                    contentsSection(snapshot)
                }
            }
            .padding(24)
        }
    }

    private func missingItemsBanner(_ missingURLs: [URL]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.tr("preview.file_system_not_found"), systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.orange)

            Text(L10n.tr("preview.file_system_not_found_message"))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            ForEach(missingURLs, id: \.path) { url in
                Text(url.path)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.orange.opacity(0.18), lineWidth: 1)
        }
    }

    private func infoSection(_ snapshot: FileSystemPreviewSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("preview.file_system_section_info"))
                .font(.system(size: 15, weight: .semibold, design: .rounded))

            VStack(spacing: 12) {
                infoRow(label: L10n.tr("preview.file_system_label_name"), value: snapshot.displayName)
                infoRow(label: L10n.tr("preview.file_system_label_type"), value: snapshot.typeDescription)
                infoRow(label: L10n.tr("preview.file_system_label_size"), value: snapshot.sizeText)
                infoRow(label: L10n.tr("preview.file_system_label_path"), value: snapshot.pathText, monospaced: true)
                if let itemCount = snapshot.itemCount {
                    infoRow(label: L10n.tr("preview.file_system_label_items"), value: L10n.format("preview.file_system_item_count", itemCount))
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private func infoRow(label: String, value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 13, weight: .medium, design: monospaced ? .monospaced : .default))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func contentsSection(_ snapshot: FileSystemPreviewSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("preview.file_system_section_contents"))
                .font(.system(size: 15, weight: .semibold, design: .rounded))

            if snapshot.directoryEntries.isEmpty {
                Text(L10n.tr("preview.file_system_empty_directory"))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(snapshot.directoryEntries.enumerated()), id: \.element.id) { index, entry in
                        FileSystemPreviewEntryRow(entry: entry)

                        if index < snapshot.directoryEntries.count - 1 {
                            Divider()
                                .padding(.leading, 34)
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }
}

private struct FileSystemPreviewEntryRow: View {
    let entry: FileSystemPreviewDirectoryEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(iconBackgroundColor)

                Image(systemName: entry.kind == .folder ? "folder.fill" : "doc.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(iconForegroundColor)
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Text(entry.detailText)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let sizeText = entry.sizeText {
                Text(sizeText)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 10)
    }

    private var iconBackgroundColor: Color {
        entry.kind == .folder ? Color.orange.opacity(0.16) : Color.indigo.opacity(0.14)
    }

    private var iconForegroundColor: Color {
        entry.kind == .folder ? Color.orange.opacity(0.9) : Color.indigo.opacity(0.9)
    }
}
