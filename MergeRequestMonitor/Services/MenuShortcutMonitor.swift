//
//  MenuShortcutMonitor.swift
//  MergeRequestMonitor
//

import Carbon.HIToolbox
import Combine
import Foundation

/// Owns the popover hotkey. `RegisterEventHotKey` reserves a shortcut with the
/// window server, so this does not listen to keystrokes and does not need
/// Accessibility or Input Monitoring permission.
final class MenuShortcutMonitor: ObservableObject {
    @Published private(set) var registrationError: String?

    var onPress: (() -> Void)?

    private let signature: OSType = 0x474C424D // GLBM
    private let hotKeyID: UInt32 = 1
    private var settings: AppSettings?
    private var cancellable: AnyCancellable?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var isRecording = false

    func start(settings: AppSettings) {
        self.settings = settings
        installHandlerIfNeeded()
        cancellable = settings.$menuShortcut.sink { [weak self] shortcut in
            self?.apply(shortcut)
        }
    }

    func stop() {
        cancellable = nil
        unregisterHotKey()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    /// Drops the hotkey while Settings is listening, so the same combination can be pressed again.
    func setRecording(_ recording: Bool) {
        guard recording != isRecording else { return }
        isRecording = recording
        apply(settings?.menuShortcut)
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let monitor = Unmanaged<MenuShortcutMonitor>.fromOpaque(userData).takeUnretainedValue()
                return monitor.handleHotKey(event)
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        if status != noErr {
            handlerRef = nil
            gDebugPrint("InstallEventHandler failed status=\(status)")
        }
    }

    private func handleHotKey(_ event: EventRef) -> OSStatus {
        var pressedID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &pressedID
        )
        guard status == noErr, pressedID.signature == signature, pressedID.id == hotKeyID else {
            return OSStatus(eventNotHandledErr)
        }
        DispatchQueue.main.async { [weak self] in
            self?.onPress?()
        }
        return noErr
    }

    private func apply(_ shortcut: MenuShortcut?) {
        unregisterHotKey()
        guard let shortcut, !isRecording else {
            updateRegistrationError(nil)
            return
        }

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: signature, id: hotKeyID)
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.carbonModifiers,
            id,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            hotKeyRef = ref
            updateRegistrationError(nil)
            gDebugPrint("menu shortcut registered \(shortcut.displayString)")
        } else {
            updateRegistrationError("That shortcut is already used by macOS or another app.")
            gDebugPrint("RegisterEventHotKey failed status=\(status)")
        }
    }

    /// Settings updates this from a view callback. Publish on the next turn so SwiftUI
    /// is not asked to refresh while it is already updating.
    private func updateRegistrationError(_ message: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.registrationError != message else { return }
            self.registrationError = message
        }
    }

    private func unregisterHotKey() {
        guard let hotKeyRef else { return }
        UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
    }
}
