import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Inserts text into the currently focused application by simulating paste.
/// Clipboard contents are restored after insertion when possible.
@MainActor
public final class TextInsertion {
    public enum Mode: Sendable {
        case paste
        case type
    }

    public init() {}

    public func insert(_ text: String, mode: Mode = .paste) throws {
        guard !text.isEmpty else { return }
        switch mode {
        case .paste:
            try paste(text)
        case .type:
            try typeText(text)
        }
    }

    private func paste(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        let previousChangeCount = pasteboard.changeCount
        let previousString = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        postKey(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand, keyDown: true)
        postKey(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand, keyDown: false)

        // Give the target app a moment to consume the paste before restoring the clipboard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if pasteboard.changeCount != previousChangeCount {
                pasteboard.clearContents()
                if let previousString {
                    pasteboard.setString(previousString, forType: .string)
                }
            }
        }
    }

    private func typeText(_ text: String) throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        for character in text {
            let utf16 = Array(character.utf16)
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                utf16.withUnsafeBufferPointer { pointer in
                    down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: pointer.baseAddress)
                }
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                utf16.withUnsafeBufferPointer { pointer in
                    up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: pointer.baseAddress)
                }
                up.post(tap: .cghidEventTap)
            }
        }
    }

    /// Posts Cmd+C so the frontmost app copies its current selection.
    public func copySelection() {
        postKey(keyCode: CGKeyCode(kVK_ANSI_C), flags: .maskCommand, keyDown: true)
        postKey(keyCode: CGKeyCode(kVK_ANSI_C), flags: .maskCommand, keyDown: false)
    }

    private func postKey(keyCode: CGKeyCode, flags: CGEventFlags, keyDown: Bool) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}
