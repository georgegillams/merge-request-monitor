//
//  ShortcutRecorder.swift
//  MergeRequestMonitor
//

import AppKit
import SwiftUI
import components_swiftUI

struct ShortcutRecorder: View {
    @Binding var shortcut: MenuShortcut?
    @ObservedObject var monitor: MenuShortcutMonitor

    @State private var isRecording = false
    @State private var rejection: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                ShortcutCaptureButton(
                    title: isRecording ? "Type shortcut now" : (shortcut?.displayString ?? "Record new shortcut"),
                    isRecording: isRecording,
                    help: isRecording
                        ? "Press a shortcut. Escape cancels. Delete clears."
                        : "Click, then type your shortcut",
                    onToggle: toggleRecording,
                    onKey: handleKey,
                    onCancel: cancelRecording
                )
                .accessibilityLabel("Popover shortcut")
                .accessibilityValue(isRecording ? "Recording" : (shortcut?.displayString ?? "None"))

                if shortcut != nil, !isRecording {
                    Button {
                        rejection = nil
                        shortcut = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Clear shortcut")
                    .accessibilityLabel("Clear shortcut")
                }
            }

            if let rejection {
                Text(rejection)
                    .font(.caption)
                    .foregroundStyle(Semantic.Colors.statusDestructive)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 220, alignment: .trailing)
            }
        }
        .onChange(of: isRecording) { recording in
            monitor.setRecording(recording)
        }
        .onDisappear {
            if isRecording {
                isRecording = false
            }
            monitor.setRecording(false)
        }
    }

    private func toggleRecording() {
        rejection = nil
        isRecording.toggle()
    }

    private func cancelRecording() {
        guard isRecording else { return }
        rejection = nil
        isRecording = false
    }

    private func handleKey(_ event: NSEvent) {
        if event.isARepeat { return }
        let keyCode = event.keyCode
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let withoutCommandLikeModifier = modifiers.intersection([.command, .option, .control]).isEmpty

        // Escape and Delete control the recorder unless a command-like modifier is held.
        if keyCode == Self.escapeKeyCode, withoutCommandLikeModifier {
            rejection = nil
            isRecording = false
            return
        }
        if (keyCode == Self.deleteKeyCode || keyCode == Self.forwardDeleteKeyCode), withoutCommandLikeModifier {
            shortcut = nil
            rejection = nil
            isRecording = false
            return
        }
        guard let recorded = MenuShortcut(keyCode: keyCode, modifiers: modifiers) else {
            rejection = "Use ⌘, ⌥, ⌃, or a function key."
            return
        }
        shortcut = recorded
        rejection = nil
        isRecording = false
    }

    private static let escapeKeyCode: UInt16 = 53
    private static let deleteKeyCode: UInt16 = 51
    private static let forwardDeleteKeyCode: UInt16 = 117
}

/// Bordered button that records one shortcut. Clicks on the button are left for its action;
/// any other click cancels. A local key monitor runs before the Edit menu, so a shortcut
/// such as ⌘V can be recorded instead of pasting.
private struct ShortcutCaptureButton: NSViewRepresentable {
    var title: String
    var isRecording: Bool
    var help: String
    var onToggle: () -> Void
    var onKey: (NSEvent) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> ShortcutCaptureButtonView {
        let button = ShortcutCaptureButtonView()
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.font = .systemFont(ofSize: NSFont.systemFontSize)
        button.refusesFirstResponder = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: ShortcutCaptureButtonView, context: Context) {
        button.title = title
        button.toolTip = help
        button.onToggle = onToggle
        button.onKey = onKey
        button.onCancel = onCancel
        button.applyRecording(isRecording)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: ShortcutCaptureButtonView,
        context: Context
    ) -> CGSize? {
        let intrinsic = nsView.intrinsicContentSize
        return CGSize(width: max(intrinsic.width + 28, 128), height: max(intrinsic.height, 24))
    }
}

private final class ShortcutCaptureButtonView: NSButton {
    var onToggle: () -> Void = {}
    var onKey: (NSEvent) -> Void = { _ in }
    var onCancel: () -> Void = {}

    private var recording = false
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var ignoreResign = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(pressed)
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        tearDownMonitors()
    }

    func applyRecording(_ recording: Bool) {
        guard recording != self.recording else { return }
        self.recording = recording
        bezelColor = recording ? .controlAccentColor : nil
        if recording {
            installMonitors()
            window?.makeFirstResponder(self)
        } else {
            tearDownMonitors()
            resignIfNeeded()
        }
    }

    @objc private func pressed() {
        onToggle()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, recording, !ignoreResign {
            onCancel()
        }
        return resigned
    }

    private func resignIfNeeded() {
        guard window?.firstResponder === self else { return }
        ignoreResign = true
        window?.makeFirstResponder(nil)
        ignoreResign = false
    }

    private func installMonitors() {
        tearDownMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recording else { return event }
            self.onKey(event)
            return nil
        }
        // Clicks on this button fall through to `pressed`, which toggles recording off.
        // Any other click cancels so a following button action cannot start it again.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self, self.recording else { return event }
            if self.eventHitsSelf(event) { return event }
            self.onCancel()
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, self.recording else { return }
            if let window = notification.object as? NSWindow, window !== self.window { return }
            self.onCancel()
        }
    }

    private func tearDownMonitors() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
    }

    private func eventHitsSelf(_ event: NSEvent) -> Bool {
        guard let window else { return false }
        let pointInWindow: NSPoint
        if event.window === window {
            pointInWindow = event.locationInWindow
        } else if let eventWindow = event.window {
            let onScreen = eventWindow.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
            pointInWindow = window.convertPoint(fromScreen: onScreen)
        } else {
            pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        }
        return convert(bounds, to: nil).insetBy(dx: -4, dy: -4).contains(pointInWindow)
    }
}
