//
//  HoverTooltip.swift
//  MergeRequestMonitor
//

import AppKit
import SwiftUI

private let hoverTooltipWindowIdentifier = NSUserInterfaceItemIdentifier("MergeRequestMonitor.HoverTooltip")

/// True for the custom tooltip panel. It is borderless and can extend past the status
/// panel, but it ignores clicks, so it must not keep that panel open.
func isHoverTooltipWindow(_ window: NSWindow) -> Bool {
    window.identifier == hoverTooltipWindowIdentifier
}

extension View {
    /// Hover tooltip that appears while this menu-bar app is inactive.
    ///
    /// `NSView.toolTip` and SwiftUI `.help` are drawn by AppKit only when the app is
    /// active. An accessory app is active while Settings is open, and otherwise is not,
    /// so those tips never show on the status panel.
    func hoverTooltip(_ text: String) -> some View {
        modifier(HoverTooltipModifier(text: text))
    }

    /// Hover that works while this menu-bar app is inactive.
    ///
    /// SwiftUI `.onHover` uses tracking areas, which are not delivered to an
    /// inactive accessory app. This polls `NSEvent.mouseLocation` instead.
    func onPointerHover(_ isHovered: Binding<Bool>) -> some View {
        modifier(PointerHoverModifier(isHovered: isHovered))
    }
}

/// Reads the control's SwiftUI layout frame, which is where the tip should sit.
struct HoverTooltipModifier: ViewModifier {
    var text: String

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                HoverTooltipAnchor(text: text, globalFrame: proxy.frame(in: .global))
            }
        }
    }
}

/// Hides a visible tooltip immediately. Closing the status panel releases its views
/// on the same turn; this covers the gap before that teardown.
func hideHoverTooltips() {
    HoverTooltipController.shared.hideForPanelClose()
    PointerHoverController.shared.hideForPanelClose()
}

/// SwiftUI `.global` is top-left / Y-down in the window content; AppKit is bottom-left.
private func screenRect(fromSwiftUIGlobal globalFrame: CGRect, in window: NSWindow) -> NSRect? {
    guard globalFrame.width > 0.5, globalFrame.height > 0.5 else { return nil }
    let height = window.contentView?.bounds.height ?? window.frame.height
    let inWindow = NSRect(
        x: globalFrame.origin.x,
        y: height - globalFrame.origin.y - globalFrame.height,
        width: globalFrame.width,
        height: globalFrame.height
    )
    return window.convertToScreen(inWindow)
}

private struct HoverTooltipAnchor: NSViewRepresentable {
    var text: String
    var globalFrame: CGRect

    func makeNSView(context: Context) -> HoverTooltipAnchorView {
        let view = HoverTooltipAnchorView()
        view.text = text
        view.globalFrame = globalFrame
        return view
    }

    func updateNSView(_ nsView: HoverTooltipAnchorView, context: Context) {
        nsView.text = text
        nsView.globalFrame = globalFrame
        if nsView.window != nil {
            HoverTooltipController.shared.register(nsView, text: text)
        }
    }
}

/// Invisible registration view. Clicks pass through to the SwiftUI control in front.
/// Hit-testing uses only the SwiftUI layout frame: the AppKit view behind a hosting
/// view is often stuck at the bottom of the popover (or window-sized), which produced
/// ghost tip targets below the real status dots.
private final class HoverTooltipAnchorView: NSView {
    var text: String = "" {
        didSet {
            guard text != oldValue, window != nil else { return }
            HoverTooltipController.shared.register(self, text: text)
        }
    }

    var globalFrame: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Screen rect of this control if the pointer is inside its SwiftUI layout frame.
    func hitScreenRect(containing mouse: NSPoint) -> NSRect? {
        guard let window, let rect = layoutScreenRect(in: window) else { return nil }
        return rect.contains(mouse) ? rect : nil
    }

    func layoutScreenRect(in window: NSWindow) -> NSRect? {
        screenRect(fromSwiftUIGlobal: globalFrame, in: window)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            HoverTooltipController.shared.register(self, text: text)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            HoverTooltipController.shared.unregister(ObjectIdentifier(self))
        }
    }

    deinit {
        HoverTooltipController.shared.unregister(ObjectIdentifier(self))
    }
}

/// Polls the cursor while anchors are on screen. Tracking areas and `mouseMoved`
/// are not delivered to an inactive accessory app; `NSEvent.mouseLocation` still updates.
private final class HoverTooltipController {
    static let shared = HoverTooltipController()

    private struct Anchor {
        var text: String
        weak var view: HoverTooltipAnchorView?
    }

    private struct Hit {
        let id: ObjectIdentifier
        let text: String
        let anchor: HoverTooltipAnchorView
        let screenRect: NSRect
    }

    private var anchors: [ObjectIdentifier: Anchor] = [:]
    private var timer: Timer?
    private var hoverID: ObjectIdentifier?
    private var hoverBegan: Date?
    /// Set on mouse-down so the tip stays dismissed until the pointer leaves that control.
    private var suppressedID: ObjectIdentifier?
    private var panel: HoverTooltipPanel?
    private var shownAnchorID: ObjectIdentifier?
    private var shownText: String?
    private var shownFrame: NSRect = .zero

    private var showDelay: TimeInterval {
        let milliseconds = UserDefaults.standard.integer(forKey: "NSInitialToolTipDelay")
        guard milliseconds > 0 else { return 0.5 }
        return TimeInterval(milliseconds) / 1000
    }

    func register(_ view: HoverTooltipAnchorView, text: String) {
        anchors[ObjectIdentifier(view)] = Anchor(text: text, view: view)
        startTimerIfNeeded()
    }

    func unregister(_ id: ObjectIdentifier) {
        anchors.removeValue(forKey: id)
        if hoverID == id || shownAnchorID == id {
            hoverID = nil
            hoverBegan = nil
            hideTooltip()
        }
        if suppressedID == id {
            suppressedID = nil
        }
        if anchors.isEmpty {
            stopTimer()
        }
    }

    func hideForPanelClose() {
        hoverID = nil
        hoverBegan = nil
        suppressedID = nil
        hideTooltip()
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = 1.0 / 120.0
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        anchors = anchors.filter { $0.value.view != nil }
        guard !anchors.isEmpty else {
            hideForPanelClose()
            stopTimer()
            return
        }

        let hit = anchor(at: NSEvent.mouseLocation)

        if NSEvent.pressedMouseButtons != 0 {
            if let hit {
                suppressedID = hit.id
            }
            hoverID = nil
            hoverBegan = nil
            hideTooltip()
            return
        }

        guard let hit else {
            suppressedID = nil
            hoverID = nil
            hoverBegan = nil
            hideTooltip()
            return
        }

        if suppressedID == hit.id {
            return
        }
        suppressedID = nil

        if hoverID != hit.id {
            hoverID = hit.id
            hoverBegan = Date()
            hideTooltip()
        }

        guard let hoverBegan, Date().timeIntervalSince(hoverBegan) >= showDelay else { return }
        showTooltip(text: hit.text, anchorID: hit.id, from: hit.anchor, around: hit.screenRect)
    }

    /// The anchor under the cursor, in the topmost of our windows at that point.
    /// A stage or review popover therefore wins over a status dot it covers.
    private func anchor(at mouse: NSPoint) -> Hit? {
        guard let front = topWindow(at: mouse) else { return nil }
        var best: Hit?
        for (id, anchor) in anchors {
            guard let view = anchor.view, !anchor.text.isEmpty else { continue }
            guard view.window === front else { continue }
            guard let onScreen = view.hitScreenRect(containing: mouse) else { continue }
            let hit = Hit(id: id, text: anchor.text, anchor: view, screenRect: onScreen)
            if let best, hit.screenRect.width * hit.screenRect.height >= best.screenRect.width * best.screenRect.height {
                continue
            }
            best = hit
        }
        return best
    }

    private func topWindow(at mouse: NSPoint) -> NSWindow? {
        var best: NSWindow?
        for window in NSApp.windows {
            guard window.isVisible, !isHoverTooltipWindow(window), window.frame.contains(mouse) else { continue }
            guard let current = best else {
                best = window
                continue
            }
            if window.level.rawValue > current.level.rawValue
                || (window.level.rawValue == current.level.rawValue && window.windowNumber > current.windowNumber) {
                best = window
            }
        }
        return best
    }

    private func showTooltip(
        text: String,
        anchorID: ObjectIdentifier,
        from view: NSView,
        around anchorRect: NSRect
    ) {
        guard let window = view.window else { return }
        let panel = ensurePanel()
        let box = panel.box
        let size = box.size(for: text)
        let frame = tooltipFrame(size: size, near: anchorRect, in: window)

        if shownAnchorID == anchorID, shownText == text, panel.isVisible, framesMatch(shownFrame, frame) {
            return
        }

        panel.appearance = view.effectiveAppearance
        box.appearance = view.effectiveAppearance
        box.message = text
        // Stay above the status panel and any SwiftUI popover opened from it.
        panel.level = NSWindow.Level(
            rawValue: max(window.level.rawValue, NSWindow.Level.popUpMenu.rawValue) + 2
        )
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        shownAnchorID = anchorID
        shownText = text
        shownFrame = frame
    }

    private func hideTooltip() {
        shownAnchorID = nil
        shownText = nil
        shownFrame = .zero
        guard panel?.isVisible == true else { return }
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> HoverTooltipPanel {
        if let panel { return panel }
        let panel = HoverTooltipPanel()
        self.panel = panel
        return panel
    }

    private func framesMatch(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < 0.5
            && abs(lhs.origin.y - rhs.origin.y) < 0.5
            && abs(lhs.size.width - rhs.size.width) < 0.5
            && abs(lhs.size.height - rhs.size.height) < 0.5
    }

    /// Places the tip beside the control, inside the popover. Below the control when it
    /// fits; above it when that would hang out under the window.
    private func tooltipFrame(size: NSSize, near anchor: NSRect, in source: NSWindow) -> NSRect {
        let gap: CGFloat = 4
        let margin: CGFloat = 4
        let windowFrame = source.frame.insetBy(dx: margin, dy: margin)
        let x = anchor.midX - size.width / 2
        let below = NSRect(x: x, y: anchor.minY - gap - size.height, width: size.width, height: size.height)
        let above = NSRect(x: x, y: anchor.maxY + gap, width: size.width, height: size.height)
        var frame = windowFrame.contains(below) || !windowFrame.intersects(above) ? below : above
        if frame.maxY > windowFrame.maxY {
            frame.origin.y = windowFrame.maxY - size.height
        }
        if frame.minY < windowFrame.minY {
            frame.origin.y = windowFrame.minY
        }
        if frame.minX < windowFrame.minX {
            frame.origin.x = windowFrame.minX
        }
        if frame.maxX > windowFrame.maxX {
            frame.origin.x = windowFrame.maxX - size.width
        }
        let screen = source.screen?.visibleFrame ?? windowFrame
        if frame.minX < screen.minX + margin { frame.origin.x = screen.minX + margin }
        if frame.maxX > screen.maxX - margin { frame.origin.x = screen.maxX - margin - size.width }
        if frame.minY < screen.minY + margin { frame.origin.y = screen.minY + margin }
        if frame.maxY > screen.maxY - margin { frame.origin.y = screen.maxY - margin - size.height }
        frame.origin.x = round(frame.origin.x)
        frame.origin.y = round(frame.origin.y)
        return frame
    }
}

private final class HoverTooltipPanel: NSPanel {
    let box = TooltipBox()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        identifier = hoverTooltipWindowIdentifier
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        // NSPanel hides itself whenever the app is inactive. That is the default state
        // of this menu-bar app, so the tip would never appear.
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        animationBehavior = .none
        tabbingMode = .disallowed
        box.autoresizingMask = [.width, .height]
        contentView = box
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class TooltipBox: NSView {
    private static let maxTextWidth: CGFloat = 280
    private static let padX: CGFloat = 8
    private static let padY: CGFloat = 4

    var message: String = "" {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    func size(for text: String) -> NSSize {
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: Self.maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: textAttributes()
        )
        return NSSize(
            width: min(Self.maxTextWidth, ceil(measured.width)) + Self.padX * 2 + 1,
            height: ceil(measured.height) + Self.padY * 2 + 1
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        let textRect = bounds.insetBy(dx: Self.padX, dy: Self.padY)
        (message as NSString).draw(in: textRect, withAttributes: textAttributes())
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func textAttributes() -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.alignment = .left
        return [
            .font: NSFont.toolTipsFont(ofSize: 0),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ]
    }
}

// MARK: - Pointer hover

private struct PointerHoverModifier: ViewModifier {
    @Binding var isHovered: Bool

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                PointerHoverAnchor(isHovered: $isHovered, globalFrame: proxy.frame(in: .global))
            }
        }
    }
}

private struct PointerHoverAnchor: NSViewRepresentable {
    @Binding var isHovered: Bool
    var globalFrame: CGRect

    func makeNSView(context: Context) -> PointerHoverAnchorView {
        let view = PointerHoverAnchorView()
        view.isHovered = $isHovered
        view.globalFrame = globalFrame
        return view
    }

    func updateNSView(_ nsView: PointerHoverAnchorView, context: Context) {
        nsView.isHovered = $isHovered
        nsView.globalFrame = globalFrame
        if nsView.window != nil {
            PointerHoverController.shared.register(nsView, isHovered: $isHovered)
        }
    }
}

private final class PointerHoverAnchorView: NSView {
    var isHovered: Binding<Bool> = .constant(false)
    var globalFrame: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func hitScreenRect(containing mouse: NSPoint) -> NSRect? {
        guard let window, let rect = screenRect(fromSwiftUIGlobal: globalFrame, in: window) else {
            return nil
        }
        return rect.contains(mouse) ? rect : nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            PointerHoverController.shared.register(self, isHovered: isHovered)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            PointerHoverController.shared.unregister(ObjectIdentifier(self))
        }
    }

    deinit {
        PointerHoverController.shared.unregister(ObjectIdentifier(self))
    }
}

/// Polls the cursor while cards are on screen. Same constraint as hover tooltips:
/// tracking areas are not delivered to an inactive accessory app.
private final class PointerHoverController {
    static let shared = PointerHoverController()

    private struct Anchor {
        var isHovered: Binding<Bool>
        weak var view: PointerHoverAnchorView?
    }

    private var anchors: [ObjectIdentifier: Anchor] = [:]
    private var timer: Timer?
    private var hoveredID: ObjectIdentifier?

    func register(_ view: PointerHoverAnchorView, isHovered: Binding<Bool>) {
        anchors[ObjectIdentifier(view)] = Anchor(isHovered: isHovered, view: view)
        startTimerIfNeeded()
    }

    func unregister(_ id: ObjectIdentifier) {
        if let anchor = anchors.removeValue(forKey: id), anchor.isHovered.wrappedValue {
            anchor.isHovered.wrappedValue = false
        }
        if hoveredID == id {
            hoveredID = nil
        }
        if anchors.isEmpty {
            stopTimer()
        }
    }

    func hideForPanelClose() {
        for (_, anchor) in anchors where anchor.isHovered.wrappedValue {
            anchor.isHovered.wrappedValue = false
        }
        hoveredID = nil
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = 1.0 / 120.0
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        anchors = anchors.filter { $0.value.view != nil }
        guard !anchors.isEmpty else {
            hideForPanelClose()
            stopTimer()
            return
        }

        let mouse = NSEvent.mouseLocation
        var bestID: ObjectIdentifier?
        var bestArea: CGFloat = .greatestFiniteMagnitude
        for (id, anchor) in anchors {
            guard let view = anchor.view, view.window != nil else { continue }
            guard let onScreen = view.hitScreenRect(containing: mouse) else { continue }
            let area = onScreen.width * onScreen.height
            if area < bestArea {
                bestArea = area
                bestID = id
            }
        }

        if hoveredID != bestID {
            if let hoveredID, let previous = anchors[hoveredID], previous.isHovered.wrappedValue {
                previous.isHovered.wrappedValue = false
            }
            hoveredID = bestID
            if let bestID, let next = anchors[bestID], !next.isHovered.wrappedValue {
                next.isHovered.wrappedValue = true
            }
        }
    }
}
