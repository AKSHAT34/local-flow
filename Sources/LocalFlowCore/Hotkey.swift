import Carbon.HIToolbox
import CoreGraphics
import Foundation
import os

/// Observes the configured trigger key globally with a CGEventTap. The tap is passive
/// (defaultTap) and forwards events so the system still sees them.
@MainActor
public final class GlobalHotkeyService {
    /// Trigger press; `withControl` is true when Control is held (command mode).
    public var onTriggerDown: ((Bool) -> Void)?
    public var onTriggerUp: (() -> Void)?
    public var onEscape: (() -> Void)?
    public var onPasteLast: (() -> Void)?

    /// Supplies the currently configured trigger key. Read on the main actor.
    public var triggerKeyProvider: (@MainActor () -> TriggerKey)?

    private let escapeConsumption = OSAllocatedUnfairLock(initialState: false)
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var running = false
    private var optionDown = false
    private var commandDown = false

    public init() {}

    public var isRunning: Bool { running }

    /// Whether Escape key events should be consumed while a dictation gesture is active.
    public var consumeEscape: Bool {
        get { escapeConsumption.withLock { $0 } }
        set { escapeConsumption.withLock { $0 = newValue } }
    }

    nonisolated func shouldConsumeEscape() -> Bool {
        escapeConsumption.withLock { $0 }
    }

    public func start() {
        guard !running else { return }
        let flagsMask = CGEventMask(1) << CGEventType.flagsChanged.rawValue
        let keyMask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let eventMask = flagsMask | keyMask
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: localFlowHotkeyCallback,
            userInfo: refcon
        ) else {
            LocalFlowLog.write("hotkey: CGEvent.tapCreate returned nil (Accessibility permission likely missing)")
            return
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        running = true
        LocalFlowLog.write("hotkey: event tap started (enabled=\(CGEvent.tapIsEnabled(tap: tap)))")
    }

    public func stop() {
        guard running else { return }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        source = nil
        tap = nil
        running = false
        optionDown = false
        commandDown = false
    }

    func reenableTap() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        LocalFlowLog.write("hotkey: re-enabled tap after system disable")
    }

    /// Handles a flagsChanged event on the main actor. Always returns the event upstream.
    func handleFlagsChanged(keyCode: CGKeyCode, flags: CGEventFlags) {
        switch triggerKeyProvider?() ?? .fn {
        case .fn:
            guard keyCode == CGKeyCode(kVK_Function) else { return }
            if flags.contains(.maskSecondaryFn) {
                onTriggerDown?(flags.contains(.maskControl))
            } else {
                onTriggerUp?()
            }
        case .rightOption:
            guard keyCode == CGKeyCode(kVK_RightOption) else { return }
            // Right Option shares .maskAlternate with Left Option, so per-keyCode
            // toggling is the reliable signal (each press/release = one event).
            optionDown.toggle()
            if optionDown {
                onTriggerDown?(flags.contains(.maskControl))
            } else {
                onTriggerUp?()
            }
        case .rightCommand:
            guard keyCode == CGKeyCode(kVK_RightCommand) else { return }
            commandDown.toggle()
            if commandDown {
                onTriggerDown?(flags.contains(.maskControl))
            } else {
                onTriggerUp?()
            }
        }
    }
}

private func localFlowHotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<GlobalHotkeyService>.fromOpaque(userInfo).takeUnretainedValue()

    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        Task { @MainActor in service.reenableTap() }
        return nil
    case .flagsChanged:
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        Task { @MainActor in service.handleFlagsChanged(keyCode: keyCode, flags: flags) }
        return Unmanaged.passUnretained(event)
    case .keyDown:
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        if keyCode == CGKeyCode(kVK_ANSI_V), flags.contains(.maskCommand), flags.contains(.maskControl) {
            Task { @MainActor in service.onPasteLast?() }
            return nil
        }
        if keyCode == CGKeyCode(kVK_Escape), service.shouldConsumeEscape() {
            Task { @MainActor in service.onEscape?() }
            return nil
        }
        return Unmanaged.passUnretained(event)
    default:
        return Unmanaged.passUnretained(event)
    }
}
