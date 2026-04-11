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
        let rootView = ImagePreviewView(item: previewItem)

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
            window.hidesOnDeactivate = true
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
        let rootView = TextPreviewView(item: item, text: text)

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
            window.hidesOnDeactivate = true
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
        [panelWindow, debugWindow, settingsWindow, imagePreviewWindow, textPreviewWindow].forEach { window in
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        applyAppearance()

        coordinator.configureWindow()
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

        let targetSize = NSSize(width: 18, height: 18)
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
            onOpenPanel: { [weak self] in
                self?.closeStatusPopover()
                self?.coordinator.togglePanel()
            },
            onOpenDebug: { [weak self] in
                self?.closeStatusPopover()
                self?.coordinator.showDebugPanel()
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
        let controller = NSHostingController(rootView: view)
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
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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

private struct TextPreviewView: View {
    let item: ClipboardItem
    let text: String

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
