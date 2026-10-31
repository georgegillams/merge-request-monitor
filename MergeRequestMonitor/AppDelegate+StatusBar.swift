//
//  AppDelegate+StatusBar.swift
//  MergeRequestMonitor
//

import AppKit
import Combine
import SwiftUI

extension AppDelegate {
    private static let settingsWindowDefaultSize = NSSize(width: 640, height: 720)
    private static let settingsWindowMinimumSize = NSSize(width: 520, height: 480)
    private static let statusPanelWidth: CGFloat = 420
    private static let statusPanelMaxHeight: CGFloat = 520
    private static let statusPanelScreenMargin: CGFloat = 8
    private static let statusPanelGapBelowMenuBar: CGFloat = 6

    func createStatusBarButton() {
        gDebugPrint("NSStatusBar.system.statusItem…")
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusBarItem.isVisible = true
        gDebugPrint("statusItem created length=\(statusBarItem.length) button=\(statusBarItem.button != nil)")

        updateMenuBarIcon()

        if let button = statusBarItem.button {
            button.toolTip = "Merge Request Monitor"
            button.setAccessibilityLabel("Merge Request Monitor")
            // Target is used by NSStatusBarButton.mouseDown override; no sendAction —
            // AppKit’s default press/release cycle would clear the open highlight.
            button.target = self
            gDebugPrint("status button title=\(button.title.debugDescription) frame=\(NSStringFromRect(button.frame)) window=\(String(describing: button.window))")
        } else {
            gDebugPrint("ERROR: statusBarItem.button is nil")
        }
    }

    func updateMenuBarIcon() {
        guard let button = statusBarItem?.button else {
            gDebugPrint("updateMenuBarIcon: no button")
            return
        }

        // Rasterized template image. A live SF Symbol in this status item has rendered blank.
        statusBarItem.length = NSStatusItem.squareLength
        button.image = Self.menuBarIcon
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.title = ""
        gDebugPrint("updateMenuBarIcon set in-progress icon")
    }

    /// In-progress job mark (ring + progress wedge), in one color so the menu bar can tint it.
    /// Proportions match `GitLabStatusIcon`'s `.inProgress` layout and the `CIStatusRunning` glyph.
    private static let menuBarIcon: NSImage = {
        let side: CGFloat = 18
        // Draw as opaque black so the composite can be a menu-bar template.
        let glyph = (NSImage(named: "CIStatusRunning")?.copy() as? NSImage) ?? NSImage()
        glyph.isTemplate = false

        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let inset: CGFloat = 0.75
            let canvas = min(rect.width, rect.height) - inset * 2
            let origin = NSPoint(x: rect.midX - canvas / 2, y: rect.midY - canvas / 2)
            let canvasRect = NSRect(origin: origin, size: NSSize(width: canvas, height: canvas))

            NSColor.black.setFill()

            // Same 2/14 ring as the in-progress job icon.
            let ring = NSBezierPath(ovalIn: canvasRect)
            let ringInset = canvas * 2 / 14
            ring.appendOval(in: NSRect(
                x: origin.x + ringInset,
                y: origin.y + ringInset,
                width: canvas - ringInset * 2,
                height: canvas - ringInset * 2
            ))
            ring.windingRule = .evenOdd
            ring.fill()

            glyph.draw(in: canvasRect, from: .zero, operation: .sourceOver, fraction: 1)

            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Merge Request Monitor"
        return image
    }()

    /// Called from `NSStatusBarButton.mouseDown` (no `super`) so the system highlight can stick.
    func handleStatusItemMouseDown() {
        toggleStatusPanel()
        statusBarItem.button?.highlight(statusPanel != nil)
    }

    func toggleStatusPanel() {
        if statusPanel != nil {
            closeStatusPanel()
        } else {
            showStatusPanel()
        }
    }

    func showStatusPanel() {
        guard statusBarItem.button != nil else { return }
        if statusPanel != nil { return }

        let root = PopoverView(
            coordinator: refreshCoordinator,
            settings: settings,
            onOpenSettings: { [weak self] in
                self?.closeStatusPanel()
                self?.showSettingsWindow()
            }
        )
        let hosting = NSHostingController(rootView: root)
        hosting.view.frame = NSRect(origin: .zero, size: NSSize(width: Self.statusPanelWidth, height: 200))

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: Self.statusPanelWidth, height: 200)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Just under the menu bar so a second click always hits the status item, not this panel.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Keep it visible while this app is inactive (normal for a menu-bar panel).
        // Dismissal on real focus changes is handled explicitly below.
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentViewController = hosting

        statusPanel = panel
        statusPanelHosting = hosting
        observeStatusPanelContentSize()

        // Size after SwiftUI lays out, then pin under the menu-bar item.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.statusPanel === panel else { return }
            guard self.statusBarItem.button != nil else {
                self.closeStatusPanel()
                return
            }
            self.updateStatusPanelSize()
            self.ignoreFocusLossUntil = Date().addingTimeInterval(0.25)
            self.startEventMonitor()
            // orderFront does nothing while this accessory app is inactive, which is the
            // usual case when the popover shortcut fires from another app.
            if NSApp.isActive {
                panel.orderFront(nil)
            } else {
                panel.orderFrontRegardless()
            }
            self.statusBarItem.button?.highlight(true)
            gDebugPrint("statusPanel shown frame=\(NSStringFromRect(panel.frame))")
        }
    }

    /// Remeasure when MR list / loading / errors change so height tracks content while open.
    private func observeStatusPanelContentSize() {
        statusPanelSizeCancellable?.cancel()
        statusPanelSizeCancellable = Publishers.CombineLatest4(
            refreshCoordinator.$mergeRequests,
            refreshCoordinator.$reviewedMergeRequests,
            refreshCoordinator.$isRefreshing,
            refreshCoordinator.$errors
        )
        .combineLatest(settings.$lastPopoverTab)
        .dropFirst()
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            // Wait for SwiftUI to commit the new tree before measuring.
            DispatchQueue.main.async {
                self?.updateStatusPanelSize()
            }
        }
    }

    /// Fits the panel to current SwiftUI content, clamped to min 200 / max `statusPanelMaxHeight`.
    private func updateStatusPanelSize() {
        guard let panel = statusPanel,
              let hosting = statusPanelHosting,
              let button = statusBarItem.button else { return }

        // Unconstrained height so a short panel (e.g. loading) can grow once rows appear.
        let fittingSize = hosting.sizeThatFits(
            in: NSSize(width: Self.statusPanelWidth, height: .greatestFiniteMagnitude)
        )
        var fitting = fittingSize
        if fitting.width < 1 { fitting.width = Self.statusPanelWidth }
        if fitting.height < 1 { fitting.height = 200 }
        fitting.width = Self.statusPanelWidth
        fitting.height = min(max(fitting.height, 200), Self.statusPanelMaxHeight)

        guard abs(panel.frame.width - fitting.width) > 0.5
            || abs(panel.frame.height - fitting.height) > 0.5 else { return }

        panel.setContentSize(fitting)
        positionStatusPanel(panel, under: button)
        gDebugPrint("statusPanel resized frame=\(NSStringFromRect(panel.frame))")
    }

    /// Places the panel directly under the status item, clamping horizontally to the screen.
    private func positionStatusPanel(_ panel: NSPanel, under button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }

        let buttonInWindow = button.convert(button.bounds, to: nil)
        let buttonOnScreen = buttonWindow.convertToScreen(buttonInWindow)
        let screen = buttonWindow.screen ?? NSScreen.main ?? NSScreen.screens[0]
        // Prefer the full frame for horizontal clamp so we can use space under the menu bar
        // while still staying on this display; use visibleFrame for bottom clamp.
        let displayFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let margin = Self.statusPanelScreenMargin
        let size = panel.frame.size

        var origin = NSPoint.zero
        origin.x = buttonOnScreen.midX - size.width / 2
        let minX = displayFrame.minX + margin
        let maxX = displayFrame.maxX - size.width - margin
        origin.x = max(minX, min(origin.x, maxX))

        // AppKit: origin is bottom-left. Sit just below the status item.
        origin.y = buttonOnScreen.minY - Self.statusPanelGapBelowMenuBar - size.height
        let minY = visibleFrame.minY + margin
        if origin.y < minY {
            origin.y = minY
        }

        panel.setFrameOrigin(origin)
    }

    func closeStatusPanel() {
        guard statusPanel != nil || eventMonitor != nil || localEventMonitor != nil || !panelDismissObservers.isEmpty else {
            return
        }
        let panel = statusPanel
        statusPanel = nil
        statusPanelHosting = nil
        statusPanelSizeCancellable?.cancel()
        statusPanelSizeCancellable = nil
        ignoreFocusLossUntil = nil
        stopEventMonitor()
        statusBarItem.button?.highlight(false)
        panel?.orderOut(nil)
        hideHoverTooltips()
    }

    /// True when this event is a click on the menu-bar button, including global-monitor copies.
    private func eventIsOnStatusButton(_ event: NSEvent) -> Bool {
        guard let button = statusBarItem.button, let window = button.window else { return false }
        let buttonInWindow = button.convert(button.bounds, to: nil)
        if event.window === window {
            return buttonInWindow.insetBy(dx: -2, dy: -2).contains(event.locationInWindow)
        }
        let rect = window.convertToScreen(buttonInWindow).insetBy(dx: -2, dy: -2)
        if event.window == nil {
            return rect.contains(event.locationInWindow)
        }
        let screenPoint = event.window?.convertToScreen(
            NSRect(origin: event.locationInWindow, size: .zero)
        ).origin ?? NSEvent.mouseLocation
        return rect.contains(screenPoint)
    }

    private func startEventMonitor() {
        stopEventMonitor()

        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            self?.dismissStatusPanelIfEventIsOutside(event)
        }
        // Global monitors never see clicks delivered to this app, so the settings
        // window needs a local monitor. Key events cover typing there without a click.
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [mouseEvents, .keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.dismissStatusPanelIfEventIsOutside(event) ? nil : event
        }

        observePanelDismiss(.default, name: NSApplication.didResignActiveNotification, object: NSApp)
        observePanelDismiss(.default, name: NSApplication.didHideNotification, object: NSApp) { [weak self] _ in
            self?.closeStatusPanel()
        }
        observePanelDismiss(
            NSWorkspace.shared.notificationCenter,
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            handler: { [weak self] notification in
                let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard activated?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self?.closeStatusPanelForFocusLoss()
            }
        )
    }

    private func observePanelDismiss(
        _ center: NotificationCenter,
        name: Notification.Name,
        object: Any?,
        handler: ((Notification) -> Void)? = nil
    ) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] notification in
            if let handler {
                handler(notification)
            } else {
                self?.closeStatusPanelForFocusLoss()
            }
        }
        panelDismissObservers.append((center, token))
    }

    /// Closes on focus loss, but ignores the burst of activation changes caused by showing the panel
    /// or by the status-item click that is about to toggle it.
    private func closeStatusPanelForFocusLoss() {
        if let event = NSApp.currentEvent, eventIsOnStatusButton(event) { return }
        if let until = ignoreFocusLossUntil, Date() < until { return }
        // Clicking the status panel (or a nested popover) to dismiss a nested
        // SwiftUI popover resigns key briefly; that is not a real leave of the UI.
        if let event = NSApp.currentEvent,
           [.leftMouseDown, .rightMouseDown].contains(event.type),
           isMouseInsideStatusRelatedUI() {
            return
        }
        closeStatusPanel()
    }

    /// - Returns: `true` when the event was consumed (Escape).
    @discardableResult
    private func dismissStatusPanelIfEventIsOutside(_ event: NSEvent) -> Bool {
        guard statusPanel != nil else { return false }

        // Status-item clicks are owned by NSStatusBarButton.mouseDown (toggle + highlight).
        if eventIsOnStatusButton(event) { return false }

        if event.type == .keyDown {
            // Escape always dismisses. Other keys dismiss only when they land in
            // another of our windows, such as Settings.
            if event.keyCode == 53 {
                closeStatusPanel()
                return true
            }
            if let window = event.window,
               !isStatusRelatedWindow(window),
               statusBarItem.button?.window !== window {
                closeStatusPanel()
            }
            return false
        }

        // Prefer screen position: clicks that dismiss a nested popover are sometimes
        // attributed to a transient window (or nil), even when aimed at the panel.
        if isMouseInsideStatusRelatedUI() {
            // Nested popover dismissal often posts resignActive after this click.
            ignoreFocusLossUntil = Date().addingTimeInterval(0.35)
            return false
        }
        if let window = event.window, isStatusRelatedWindow(window) {
            ignoreFocusLossUntil = Date().addingTimeInterval(0.35)
            return false
        }

        closeStatusPanel()
        return false
    }

    /// Status panel plus transient UI it presents (SwiftUI stage and review popovers).
    private func isStatusRelatedWindow(_ window: NSWindow) -> Bool {
        if isHoverTooltipWindow(window) { return false }
        if window === statusPanel { return true }
        if window === settingsWindow { return false }
        if window === statusBarItem?.button?.window { return false }
        guard window.isVisible else { return false }

        // SwiftUI `.popover` windows are elevated / borderless panels.
        if window.level.rawValue >= NSWindow.Level.popUpMenu.rawValue {
            return true
        }
        if window.styleMask.contains(.borderless), !window.styleMask.contains(.titled) {
            return true
        }
        return false
    }

    private func isMouseInsideStatusRelatedUI() -> Bool {
        let mouse = NSEvent.mouseLocation
        for window in NSApp.windows where isStatusRelatedWindow(window) {
            if window.frame.contains(mouse) { return true }
        }
        return false
    }

    private func stopEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        for (center, token) in panelDismissObservers {
            center.removeObserver(token)
        }
        panelDismissObservers.removeAll()
    }

    func openContextMenu() {
        guard !isPresentingContextMenu else { return }
        isPresentingContextMenu = true
        defer { isPresentingContextMenu = false }

        closeStatusPanel()
        guard statusBarItem.button != nil else { return }

        let productName = Bundle.main.menuProductName
        let buildLabel = Bundle.main.menuBuildLabel
        let menu = NSMenu()
        menu.delegate = self

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettingsWindow),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let feedbackItem = NSMenuItem(
            title: "Provide feedback",
            action: #selector(openFeedback),
            keyEquivalent: ""
        )
        feedbackItem.target = self
        menu.addItem(feedbackItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "\(productName) \(buildLabel)", action: nil, keyEquivalent: ""))

        let quitItem = NSMenuItem(
            title: "Quit \(productName)",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        // `NSMenu.popUp(positioning:at:in:)` cancels immediately on a secondary click,
        // so the menu never appears. `performClick` re-enters our mouseDown override.
        // This is the status-item presenter, and it still tracks correctly from a right-click.
        contextMenuDidOpen = false
        presentStatusItemMenu(menu)
    }

    private func presentStatusItemMenu(_ menu: NSMenu) {
        // `popUpMenu` is deprecated in favor of assigning `menu`, which can't be left
        // assigned here: every click would open this menu, and `performClick` re-enters
        // our `mouseDown` override. Call the status-item presenter directly.
        let selector = NSSelectorFromString("popUpStatusItemMenu:")
        guard let implementation = statusBarItem.method(for: selector) else { return }
        typealias PresentMenu = @convention(c) (AnyObject, Selector, NSMenu) -> Void
        let present = unsafeBitCast(implementation, to: PresentMenu.self)
        present(statusBarItem, selector, menu)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        closeStatusPanelForFocusLoss()
    }

    @objc func showSettingsWindow() {
        closeStatusPanel()
        gDebugPrint("showSettingsWindow enter windowsOpen=\(windowsOpen)")
        let settingsUI = SettingsView(
            settings: settings,
            coordinator: refreshCoordinator,
            menuShortcutMonitor: menuShortcutMonitor,
            onInstancesChanged: { [weak self] in
                self?.refreshCoordinator.refresh(reason: .manual)
            }
        )

        if settingsWindow == nil {
            windowsOpen += 1
            updateActivationPolicy()
            settingsWindow = NSWindow(
                contentRect: NSRect(origin: .zero, size: Self.settingsWindowDefaultSize),
                styleMask: [.closable, .titled, .resizable],
                backing: .buffered,
                defer: false
            )
        }

        guard let window = settingsWindow else { return }

        window.isReleasedWhenClosed = false
        window.title = "\(Bundle.main.menuProductName) Settings"
        window.backgroundColor = .windowBackgroundColor
        window.titlebarAppearsTransparent = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentMinSize = Self.settingsWindowMinimumSize
        window.delegate = self

        let hostingController = NSHostingController(rootView: settingsUI)
        if #available(macOS 13.0, *) {
            hostingController.sizingOptions = [.minSize]
        }
        window.contentViewController = hostingController
        window.setContentSize(Self.settingsWindowDefaultSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        gDebugPrint("showSettingsWindow ordered front isVisible=\(window.isVisible) frame=\(NSStringFromRect(window.frame))")
    }

    @objc func openFeedback() {
        NSWorkspace.shared.open(Bundle.main.feedbackURL)
    }

    @objc func quit() {
        NSApp.terminate(self)
    }

    func windowWillClose(_ notification: Notification) {
        windowsOpen = max(0, windowsOpen - 1)
        updateActivationPolicy()
        if notification.object as? NSWindow == settingsWindow {
            settingsWindow = nil
        }
    }

    func updateActivationPolicy() {
        if windowsOpen > 0 {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

extension NSStatusBarButton {
    /// Keep the system status-item highlight while our panel is open. Do not call `super` —
    /// the default tracking loop clears highlight on mouse-up.
    open override func mouseDown(with event: NSEvent) {
        guard let appDelegate = target as? AppDelegate else {
            super.mouseDown(with: event)
            return
        }
        if appDelegate.isPresentingContextMenu {
            return
        }
        if event.modifierFlags.contains(.control) {
            appDelegate.openContextMenu()
            return
        }
        appDelegate.handleStatusItemMouseDown()
    }

    open override func rightMouseDown(with event: NSEvent) {
        guard let appDelegate = target as? AppDelegate else {
            super.rightMouseDown(with: event)
            return
        }
        // A menu opened while the button is still down can be cancelled before it
        // appears. Mouse-up presents again if this attempt never opens.
        appDelegate.contextMenuDidOpen = false
        appDelegate.openContextMenu()
    }

    open override func rightMouseUp(with event: NSEvent) {
        guard let appDelegate = target as? AppDelegate else {
            super.rightMouseUp(with: event)
            return
        }
        defer { appDelegate.contextMenuDidOpen = false }
        guard !appDelegate.contextMenuDidOpen else { return }
        appDelegate.openContextMenu()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        contextMenuDidOpen = true
    }
}
