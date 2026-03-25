import AppKit
import SwiftUI

@MainActor
final class AppCoordinator {
    let store: ClipboardStore
    let settings: AppSettings

    private var panelWindow: NSWindow?
    private var debugWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var settingsWindowController: NSWindowController?
    private var previousApp: NSRunningApplication?

    init(settings: AppSettings) {
        self.settings = settings
        self.store = ClipboardStore(settings: settings)
    }

    func configureWindow() {
        let rootView = makePanelView()
        let hostingView = NSHostingView(rootView: rootView)

        if let panelWindow {
            panelWindow.title = L10n.tr("app.title")
            panelWindow.contentView = hostingView
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
    }

    private func makePanelView() -> PanelView {
        let rootView = PanelView(store: store, settings: settings, onPick: { [weak self] item in
            self?.paste(item)
        }, onCopy: { [weak self] item in
            self?.copyOnly(item)
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
        NSApp.activate(ignoringOtherApps: true)
        debugWindow?.makeKeyAndOrderFront(nil)
    }

    var isDebugPanelVisible: Bool {
        debugWindow?.isVisible == true
    }

    var isSettingsWindowVisible: Bool {
        settingsWindow?.isVisible == true
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

        let controller = NSHostingController(rootView: SettingsView(settings: settings))
        settingsWindow?.title = L10n.tr("menu.preferences")
        settingsWindow?.contentViewController = controller

        guard let settingsWindowController else { return }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController.showWindow(nil)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared
    private lazy var coordinator = AppCoordinator(settings: settings)

    private var monitor: ClipboardMonitor?
    private let hotKeyManager = HotKeyManager()
    private var statusItem: NSStatusItem?
    private var statusPopover: NSPopover?
    private var hotKeyObserver: NSObjectProtocol?
    private var languageObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        coordinator.configureWindow()
        coordinator.store.captureCurrentPasteboardIfNeeded()

        monitor = ClipboardMonitor { [weak coordinator] in
            Task { @MainActor in
                coordinator?.store.captureCurrentPasteboardIfNeeded()
            }
        }
        monitor?.start()

        applyHotKeyRegistration()
        observeSettingsChanges()
        setupStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        hotKeyManager.unregister()

        if let hotKeyObserver {
            NotificationCenter.default.removeObserver(hotKeyObserver)
            self.hotKeyObserver = nil
        }

        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
            self.languageObserver = nil
        }
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
        let image = NSApp.applicationIconImage.copy() as? NSImage
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = false
        return image
    }

    private func configureStatusPopover() {
        let view = MenuBarClipboardView(
            store: coordinator.store,
            onCopy: { [weak self] item in
                self?.coordinator.copyOnly(item)
            },
            onOpenPanel: { [weak self] in
                self?.statusPopover?.performClose(nil)
                self?.coordinator.togglePanel()
            },
            onOpenDebug: { [weak self] in
                self?.statusPopover?.performClose(nil)
                self?.coordinator.showDebugPanel()
            },
            onOpenPreferences: { [weak self] in
                self?.statusPopover?.performClose(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self?.openPreferences()
                }
            },
            onQuit: { [weak self] in
                self?.quitApp()
            }
        )

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 460)
        popover.contentViewController = NSHostingController(rootView: view)
        statusPopover = popover
    }

    @objc private func toggleStatusPopover() {
        guard let button = statusItem?.button, let popover = statusPopover else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @objc private func openPreferences() {
        coordinator.showSettingsWindow()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
