//
//  AppDelegate.swift
//  MergeRequestMonitor
//

import AppKit
import Combine
import SwiftUI

@main
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let settings = AppSettings()
    let menuShortcutMonitor = MenuShortcutMonitor()
    var refreshCoordinator: RefreshCoordinator!

    var windowsOpen = 0
    var statusBarItem: NSStatusItem!
    var statusPanel: NSPanel?
    /// Kept so we can remeasure after SwiftUI content changes while the panel is open.
    var statusPanelHosting: NSHostingController<PopoverView>?
    var statusPanelSizeCancellable: AnyCancellable?
    var settingsWindow: NSWindow?
    var eventMonitor: Any?
    var localEventMonitor: Any?
    /// Observers that dismiss the status panel, removed with the monitors.
    var panelDismissObservers: [(NotificationCenter, NSObjectProtocol)] = []
    /// Focus-loss notifications in this window are ignored so showing the panel
    /// doesn't immediately dismiss it.
    var ignoreFocusLossUntil: Date?
    /// True while a secondary-click menu is being presented, so the status-item
    /// click handler doesn't also toggle the panel.
    var isPresentingContextMenu = false
    /// Set once the secondary-click menu actually opens, so mouse-up doesn't present it again.
    var contextMenuDidOpen = false

    override init() {
        gDebugPrint("AppDelegate.init begin")
        super.init()
        gDebugPrint("AppDelegate.init done args=\(ProcessInfo.processInfo.arguments)")
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // AppKit’s default tip delay is ~1s; shorten so status icons feel responsive.
        // Hover tips on the status panel read this same millisecond value.
        UserDefaults.standard.set(20, forKey: "NSInitialToolTipDelay")
        gDebugPrint("applicationWillFinishLaunching policy=\(NSApp.activationPolicy().rawValue)")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        gDebugPrint("applicationDidFinishLaunching enter isGDebugScheme=\(isGDebugScheme)")

        refreshCoordinator = RefreshCoordinator(settings: settings)
        installEditMenu()

        NSApp.setActivationPolicy(.accessory)
        gDebugPrint("activationPolicy after accessory=\(NSApp.activationPolicy().rawValue)")

        gDebugPrint("createStatusBarButton…")
        createStatusBarButton()
        gDebugPrint("createStatusBarButton returned visible=\(statusBarItem?.isVisible ?? false)")

        menuShortcutMonitor.onPress = { [weak self] in
            self?.toggleStatusPanel()
        }
        menuShortcutMonitor.start(settings: settings)

        gDebugPrint("refreshCoordinator.start…")
        refreshCoordinator.start()
        gDebugPrint("refreshCoordinator.start returned")

        let hasToken = settings.hasConfiguredInstance
        gDebugPrint("instances=\(settings.instances.count) hasToken=\(hasToken)")

        if isGDebugScheme || !hasToken {
            gDebugPrint("showSettingsWindow…")
            showSettingsWindow()
            gDebugPrint("showSettingsWindow returned windowsOpen=\(windowsOpen)")
        } else {
            gDebugPrint("skipping settings window")
        }

        gDebugPrint("applicationDidFinishLaunching exit")
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        gDebugPrint("applicationDidBecomeActive")
    }

    func applicationWillTerminate(_ notification: Notification) {
        gDebugPrint("applicationWillTerminate")
        menuShortcutMonitor.stop()
        refreshCoordinator?.stop()
        closeStatusPanel()
    }

    /// Menu-bar apps get no Edit menu from the storyboard. Without Paste, Cmd+V never
    /// reaches text fields — SecureField / NSSecureTextField included.
    func installEditMenu() {
        guard let mainMenu = NSApp.mainMenu, mainMenu.item(withTitle: "Edit") == nil else { return }

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")

        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)

        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        mainMenu.insertItem(editItem, at: min(1, mainMenu.items.count))
    }
}
