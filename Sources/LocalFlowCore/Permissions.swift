import AVFoundation
import ApplicationServices
import CoreGraphics
import Foundation
import Speech

public enum PermissionKind: String, CaseIterable, Sendable {
    case microphone
    case speechRecognition
    case accessibility
}

public struct PermissionStatus: Sendable {
    public var microphone: Bool
    public var speechRecognition: Bool
    public var accessibility: Bool

    public var allGranted: Bool { microphone && speechRecognition && accessibility }
}

public enum Permissions {
    public static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    public static func status() async -> PermissionStatus {
        let mic = await microphoneStatus()
        let speech = await speechStatus()
        let accessibility = AXIsProcessTrusted()
        return PermissionStatus(microphone: mic, speechRecognition: speech, accessibility: accessibility)
    }

    public static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    public static func requestSpeechRecognition() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            return status == .authorized
        default:
            return false
        }
    }

    public static func requestAccessibility(prompt: Bool = true) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Screen & System Audio Recording (ScreenCaptureKit) permission.
    public static var screenCaptureTrusted: Bool { CGPreflightScreenCaptureAccess() }

    /// Prompts once when undetermined; returns the current grant state.
    @discardableResult
    public static func requestScreenCaptureAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    private static func microphoneStatus() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        default: return false
        }
    }

    private static func speechStatus() async -> Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }
}
