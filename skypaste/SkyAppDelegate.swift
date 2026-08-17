import AppKit
import SwiftUI

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
}

// MARK: - AppDelegate Lifecycle

@MainActor
extension AppDelegate {
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
}

// MARK: - AppDelegate Settings & Status Item

@MainActor
private extension AppDelegate {
    func applyHotKeyRegistration() {
        let binding = settings.hotKeyBinding
        hotKeyManager.register(keyCode: binding.keyCode, modifiers: binding.modifiers) { [weak coordinator] in
            coordinator?.togglePanel()
        }
    }

    func observeSettingsChanges() {
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

    func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = ""
        item.button?.image = statusBarImage()
        item.button?.imagePosition = .imageOnly
        item.button?.target = self
        item.button?.action = #selector(toggleStatusPopover)

        statusItem = item
        configureStatusPopover()
    }

    func refreshLocalizedUI() {
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

    func statusBarImage() -> NSImage? {
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

    func configureStatusPopover() {
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
            onOpenEmail: { [weak self] item in
                self?.closeStatusPopover()
                self?.coordinator.openEmailComposer(for: item)
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

    func applyAppearance() {
        let appearance = settings.appearanceMode.nsAppearance
        NSApp.appearance = appearance
        coordinator.applyAppearance()
        statusPopover?.contentViewController?.view.appearance = appearance
        statusPopover?.contentViewController?.view.window?.appearance = appearance
    }
}

// MARK: - AppDelegate Popover

@MainActor
extension AppDelegate {
    @objc func toggleStatusPopover() {
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

    func popoverDidClose(_ notification: Notification) {
        removePopoverAutoCloseMonitors()
    }
}

@MainActor
private extension AppDelegate {
    func closeStatusPopover() {
        statusPopover?.performClose(nil)
        removePopoverAutoCloseMonitors()
    }

    func installPopoverAutoCloseMonitors() {
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

    func removePopoverAutoCloseMonitors() {
        if let localPopoverMonitor {
            NSEvent.removeMonitor(localPopoverMonitor)
            self.localPopoverMonitor = nil
        }

        if let globalPopoverMonitor {
            NSEvent.removeMonitor(globalPopoverMonitor)
            self.globalPopoverMonitor = nil
        }
    }

    @objc func openPreferences() {
        coordinator.showSettingsWindow()
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }
}
