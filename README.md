# LocalFlow

Local-first macOS dictation app (Wispr Flow–style) built with SwiftPM + AppKit.

## Build

```bash
./scripts/setup-signing.sh   # once: creates a stable self-signed codesigning identity
./scripts/build-app.sh
open build/LocalFlow.app
```

Requires only Command Line Tools (no full Xcode). The app is signed with a
self-signed "LocalFlow Local Signing" certificate so TCC permissions
(Accessibility, Microphone, Speech) survive rebuilds; if the identity is
missing the build falls back to ad-hoc with a warning (permissions will reset
each rebuild). The first launch after switching signatures requires removing
the stale entry in System Settings › Privacy & Security › Accessibility and
re-enabling LocalFlow.

## Use

- **Hold the trigger key** (default **Fn**) to dictate; **release** to transcribe and paste into the focused app.
- **Double-tap** the trigger for hands-free mode — tap again or click the Flow Bar ✓ to finish, Esc or ✕ to cancel.
- **Trigger + Control** starts Command Mode (Apple Intelligence rewrites the selection per your spoken instruction).
- **Ctrl+Cmd+V** pastes the last transcript.
- A floating **Flow Bar** pill sits above the Dock: hover for hints, click to start hands-free, waveform + timer while recording.
- Menu bar: **Open LocalFlow Hub** (history, dictionary, snippets, styles, setup), Paste last transcript, Start/Stop, Settings, Quit.
- Writing styles (Formal / Casual / Very casual) are chosen per app category — messaging, email, other — in the Hub.
- Permissions needed: Microphone, Speech Recognition, Accessibility (hotkey + paste injection). Set System Settings › Keyboard › "Press fn key to" = Do Nothing when using Fn.
- Quit Wispr Flow while using LocalFlow — both use Fn.

## Engines

- **Apple Speech (default):** on-device, zero download, strict `requiresOnDeviceRecognition`.
- **Parakeet TDT 0.6B v3:** local CoreML via FluidAudio; downloads ~445 MB on first use.

## Cleanup

- Rules-only by default (fillers, repeats, commands, numbers, snippets, dictionary, per-app style).
- Optional Apple Intelligence or an external local command for LLM cleanup.

## Verify

```bash
swift build
swift run LocalFlowChecks   # core checks (no XCTest/Xcode required)
```

`swift test` requires full Xcode (XCTest is not in Command Line Tools).

## License

This project is open-source and available under the [MIT License](LICENSE).

