# LocalFlow — Fully Local, Wispr-Flow-Style Dictation for macOS

Build plan and handoff spec for a coding agent. Read the whole document before writing code.

- Target machine: MacBook Pro Mac17,9, Apple M5 Pro, 24 GB RAM, macOS 26.6.2 (build 25G83), arm64
- Toolchain present: Command Line Tools only (Swift 6.4, macOS 26 SDK incl. `Speech`, `FoundationModels`, `CoreML`, `AVFAudio`). **Full Xcode is NOT installed** (see §12).
- Research date: 2026-11-07. Model sizes/licenses below were fetched live from the Hugging Face and GitHub APIs on that date.
- Working name: **LocalFlow** (rename freely).

---

## 1. Goal and hard constraints

Build a native macOS menu-bar app that behaves like Wispr Flow: hold a key, speak, release, and polished text appears at the cursor in **any** app. Everything runs on-device.

Hard constraints (acceptance-blocking):

| # | Constraint | How it is measured |
|---|---|---|
| C1 | **Fully local.** No audio, text, or telemetry leaves the machine. The only allowed network traffic is an explicit, user-initiated model download. | `nettop -p <pid>` / Little Snitch during a 10-minute dictation session shows zero connections. |
| C2 | **≤ 1 GB RAM** while running, including during dictation and cleanup. | Peak `phys_footprint` of the LocalFlow process (and any helper process it spawns), via `footprint <pid>` and `vmmap --summary`, sampled every 250 ms by a test script (§11). Activity Monitor "Memory" column must stay < 1,000 MB. |
| C3 | Idle footprint small. | ≤ 150 MB when idle with models unloaded; ≤ 700 MB idle with the default ASR model warm. |
| C4 | Latency. | Text inserted ≤ 400 ms (p50) / ≤ 800 ms (p95) after key release for a 10-second utterance, default profile. |
| C5 | Works in any text field. | Passes the insertion matrix in §7.4. |
| C6 | Free models only, with licenses compatible with personal use. | License column in §4; record exact model revision hashes. |

Honesty rule for C2: memory used by Apple system daemons (e.g. `aned`, Apple Intelligence inference processes) does not appear in our process footprint. The test harness must **report those separately** so we never claim "under 1 GB" while silently offloading RAM elsewhere. The default profile must meet 1 GB without relying on Apple's out-of-process LLM.

Non-goals (v1): Windows/iOS, cloud sync, team features, meeting recording/diarization, speaker identification, an App Store build (App Sandbox blocks the Accessibility APIs we need).

---

## 2. What was found on this Mac (context for the agent)

- Wispr Flow 1.6.1400 is installed at `/Applications/Wispr Flow.app` and **currently running** (Electron 43, bundle `com.electron.wispr-flow`, Developer ID Wispr AI INC / C9VQZ78H85). Bundle is 524 MB, of which ~277 MB is the Electron framework.
- Its only bundled ML model is a ~0.9 MB FastText language-ID model (`Contents/Resources/fasttext/lid.176.ftz`). **No local speech-recognition weights** were found in the bundle, its ASAR archive index, or its Application Support folder — transcription is done remotely. It keeps local history in `~/Library/Application Support/Wispr Flow/flow.sqlite` and audio in `meetings/*/upload.ogg`.
- Implications for us:
  1. We cannot "borrow" a model from Wispr; we ship our own.
  2. Going native Swift (no Electron) is what makes the 1 GB budget realistic.
  3. **Do not read, copy, or modify any Wispr Flow files.** While testing, quit Wispr Flow — both apps want the Fn key.

---

## 3. Feature spec (parity target)

Reference behavior is Wispr Flow's publicly described feature set. Priority: P0 = MVP, P1 = v1, P2 = later.

| Feature | Behavior | Priority |
|---|---|---|
| Push-to-talk | Hold **Fn** (configurable: Right Option, Right Cmd, any chord) → record; release → transcribe → insert. | P0 |
| Hands-free mode | Double-tap Fn (or Fn+Space) to start; tap again to stop. Auto-stop after N seconds of silence (VAD). | P0 |
| Floating pill overlay | Small non-activating panel near bottom-center: listening waveform → "processing" spinner → hides. Must never steal focus. | P0 |
| Insert into any app | Insert at cursor of the focused app (§7). | P0 |
| Basic cleanup | Punctuation, capitalization, remove "um/uh/you know", collapse stutters/repeats, number formatting ("twenty five percent" → "25%"). | P0 (rule-based) |
| Backtrack / self-correction | "Meet at 3, actually 4" → "Meet at 4." | P1 (LLM or rule heuristics) |
| Smart formatting | Spoken lists → bullet/numbered lists; "new line", "new paragraph", "comma", "period" voice commands. | P0 (commands), P1 (auto lists) |
| Personal dictionary | User words/names/jargon (e.g. "Kronos", "NIFTY", "Argus") boosted during ASR and enforced in post-processing. Auto-learn when user corrects inserted text (P2). | P1 |
| Snippets | Voice shortcut → expansion (e.g. "my email" → address). Exact-match after normalization. | P1 |
| Per-app styles | Tone/format per bundle ID: Slack/Messages casual, Mail formal, Terminal/IDE "literal" (no cleanup, no trailing period). | P1 |
| Command mode | Select text, hold hotkey+modifier, say "make this more concise" / "translate to Hindi" → selection replaced. Requires the LLM. | P2 |
| Whisper mode | Higher input gain + lower VAD threshold for quiet speech. | P1 |
| Multi-language | Auto language detection; English-first. Hindi/Hinglish is a known weak spot for small local models (§4.6). | P1 |
| History | Local searchable list of past dictations (raw + cleaned), copy/re-insert, retention setting (default 7 days), "delete all". | P1 |
| Read aloud (TTS) | Speak selected text. Optional module, loaded on demand. | P2 |
| Sounds | Start/stop chimes, configurable. | P0 |
| Mic selection | Choose input device; follow system default; handle AirPods hot-swap. | P0 |
| Onboarding | Guided permission setup (Mic, Accessibility, Input Monitoring) + model download with progress + Fn-key system setting tip. | P0 |

---

## 4. Model research (free models, verified 2026-11-07)

### 4.1 Speech-to-text (ASR) candidates

Sizes are on-disk weights from the HF API. Runtime RAM must be measured (§11). Mean WER = Hugging Face Open ASR Leaderboard average (lower is better), taken from each model's published eval file.

| Model | Runtime | Disk size | Quality | Speed | License | Verdict |
|---|---|---|---|---|---|---|
| **NVIDIA Parakeet TDT 0.6B v3** (CoreML: `FluidInference/parakeet-tdt-0.6b-v3-coreml`) | FluidAudio (Swift, ANE) | int8 encoder ~445 MB + decoder/joint ~15–30 MB | Mean WER **6.32**; 25 European languages; punctuation + casing | Open-ASR RTFx ~3,333 (GPU); ANE ~150× realtime on M-series per FluidAudio | CC-BY-4.0 | **Default ASR.** Best accuracy/size that fits. |
| Parakeet TDT 0.6B v2 (`...-v2-coreml`) | FluidAudio | similar; a 4-bit encoder variant is 305 MB | Mean WER **6.05** (English only) | same class | CC-BY-4.0 | English-only alternative; 4-bit encoder is a good RAM-saver. |
| Parakeet Ultra (`FluidInference/parakeet-ultra-coreml`) | FluidAudio | repo 632 MB, int8 encoder ~595 MB | Better than v3 on all FluidAudio benchmarks | same as v3 | CC-BY-4.0 | "Accurate" profile if it fits C2 after measurement. |
| Parakeet TDT-CTC 110M (`FluidInference/parakeet-tdt-ctc-110m-coreml`) | FluidAudio | ~110M params (repo 455 MB incl. variants) | 3.01% WER LibriSpeech clean | 96× realtime on M2 | CC-BY-4.0 | **Lean ASR** for the profile that also keeps an LLM resident. |
| Parakeet Realtime EOU 120M (`FluidInference/parakeet-realtime-eou-120m-coreml`) | FluidAudio | ~213 MB encoder per chunk size | English, streaming, end-of-utterance detection | 160/320/1280 ms chunks | NVIDIA Open Model License | Optional streaming preview text in the pill (P2). |
| Whisper base.en / small.en (`ggerganov/whisper.cpp` ggml) | whisper.cpp (Metal/CoreML) | base.en q5_1 **60 MB**, small.en q5_1 **190 MB**, large-v3-turbo q5_0 574 MB | Good; weaker than Parakeet, hallucinates on silence | Fast | MIT | Fallback and multilingual (incl. Hindi) path. |
| Moonshine streaming tiny (`UsefulSensors/moonshine-streaming-tiny`) | ONNX / moonshine libs | 176 MB | Lower accuracy | Very low latency | MIT | Not needed if Parakeet works; keep as plan B. |
| Apple `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26 SDK, confirmed present) | System framework | 0 MB in app (OS-managed asset) | Good, on-device | Streaming | Apple OS | **Zero-RAM baseline + fallback.** Benchmark it against Parakeet in M1. |
| Canary-Qwen 2.5B, LFM3-Audio-2B | — | 5.1 GB / ~2.5 GB | Best WER (5.63) | Slower | CC-BY-4.0 / other | **Rejected:** breaks 1 GB. |
| Underdog Bark 3.0 Clean (Parakeet v3 post-train that removes fillers/false starts; `FluidInference/bark-3.0-coreml`) | FluidAudio | ~410 MB encoder | Dictation-tuned | same as v3 | **Upstream CC-BY-NC-4.0** (non-commercial) and updated 2026-11-05 (< 7 days old) | Interesting for personal use only. Do **not** make it the default; revisit after it has aged and license is confirmed. |

### 4.2 Voice activity detection

| Model | Size | License | Use |
|---|---|---|---|
| **Silero VAD** (`FluidInference/silero-vad-coreml`, or `onnx-community/silero-vad`) | ~1–2 MB | MIT | Hands-free auto-stop, trimming leading/trailing silence (prevents ASR hallucination and cuts latency). |

### 4.3 Text-cleanup LLM (optional, the RAM-heavy part)

You are right that the LLM is the limiting factor. Strategy: **cleanup is rule-based by default** (fast, ~0 MB) and the LLM is an optional, on-demand stage used for backtracking, list formatting, styles, and command mode.

| Model | Quant | File size | License | Notes |
|---|---|---|---|---|
| **Qwen3-0.6B** (`unsloth/Qwen3-0.6B-GGUF`) | Q4_K_M | **397 MB** | Apache-2.0 | **Default local LLM.** Disable "thinking" (`/no_think` or chat template flag). Best instruction following at this size. |
| Gemma 3 270M IT (`unsloth/gemma-3-270m-it-GGUF`) | Q4_K_M | **253 MB** | Gemma terms (free, usage policy) | Smallest viable; good candidate for a **fine-tuned** cleanup model (§4.5). |
| Qwen3.5-0.8B (`unsloth/Qwen3.5-0.8B-GGUF`) | Q4_K_M | 533 MB | Apache-2.0 | Better quality, only fits with the Lean ASR. |
| Qwen3-0.6B MLX 4-bit (`mlx-community/Qwen3-0.6B-4bit`) | 4-bit | 336 MB | Apache-2.0 | Use if the runtime is MLX-Swift instead of llama.cpp. |
| LFM2-350M / 700M (`LiquidAI/...-GGUF`) | Q4_K_M | 229 / 469 MB | LFM Open License ("other") | Fast; check license before use. |
| SmolLM2-360M Instruct | Q8_0 | 386 MB | Apache-2.0 | Weaker; plan C. |
| Llama 3.2 1B, Gemma 3n E2B | — | ≥ 1 GB | — | **Rejected** for the 1 GB budget. |
| **Apple Foundation Models** (`FoundationModels` framework, macOS 26 SDK present; Apple Intelligence appears opted-in on this Mac — verify via `SystemLanguageModel.default.availability`) | OS-managed ~3B | 0 MB in app | Apple OS | Best quality "free" LLM. Runs **outside our process**, so it does not count toward C2 but does use system RAM. Offer as an opt-in "Enhanced cleanup (Apple Intelligence)" toggle, clearly labeled, never the default for meeting C2. |

### 4.4 Text-to-speech (optional "read aloud")

| Model | Size | License | Notes |
|---|---|---|---|
| `AVSpeechSynthesizer` (system voices; download "Premium"/"Enhanced" voices in System Settings) | 0 MB in app | Apple OS | **Default.** |
| Kitten TTS nano 0.2 (`KittenML/kitten-tts-nano-0.2`) | **24 MB** ONNX | Apache-2.0 | Tiny neural voice. |
| Kokoro-82M (CoreML `FluidInference/kokoro-82m-coreml` ~325 MB; ONNX uint8 `onnx-community/Kokoro-82M-v1.0-ONNX` 177 MB) | 177–325 MB | Apache-2.0 | **Best quality** small open TTS; available through FluidAudio. |
| Pocket TTS small / Phonon 31M (via FluidAudio) | tens of MB | Apache-2.0 (Phonon) / CC-BY-4.0 (Kyutai) | Streaming, low latency; check per-variant license. |
| Piper (`rhasspy/piper-voices`) | 20–140 MB per voice | MIT voices; engine moved to `OHF-Voice/piper1-gpl` (**GPL-3.0**); `rhasspy/piper` is archived | Avoid linking the GPL engine. |

TTS is loaded only when "read aloud" is used and must be **mutually exclusive with the LLM** in memory (§5.3).

### 4.5 Optional: fine-tune a tiny cleanup model (P2)

Rule-based cleanup + a 270M model fine-tuned on (raw transcript → clean text) pairs can match a larger general model on this narrow task. Plan: synthesize ~20k pairs (inject fillers, false starts, "actually…" corrections, spoken lists) with a large model offline, LoRA-fine-tune Gemma 3 270M or Qwen3-0.6B, export GGUF Q4_K_M. Only do this after M3 metrics show the base model is the bottleneck.

### 4.6 Known accuracy limits

- Parakeet v3 covers 25 European languages; **it does not cover Hindi**. For Hindi/Hinglish, route to Whisper small (q5_1, 190 MB) or Apple SpeechTranscriber (if the locale is supported). Language routing is P1.
- Small LLMs can over-edit (change meaning). Guardrail in §6.4.

### 4.7 Runtime libraries

| Library | Purpose | License | Status (2026-11) |
|---|---|---|---|
| **FluidAudio** (`FluidInference/FluidAudio`) | Swift SDK: Parakeet ASR, Silero VAD, Kokoro/PocketTTS on the Apple Neural Engine; used by many open-source Mac dictation apps (Hex, VoiceTypr, MiniWhisper, Dictate Anywhere) | Apache-2.0 | Active, ~3.3k stars |
| **llama.cpp** (`ggml-org/llama.cpp`) | GGUF LLM inference with Metal; use via its XCFramework / Swift package | MIT | Active |
| whisper.cpp (`ggml-org/whisper.cpp`) | Whisper fallback | MIT | Active |
| WhisperKit (now `argmaxinc/argmax-oss-swift`) | Alternative CoreML Whisper runtime | MIT | Active; optional |
| MLX-Swift (`ml-explore/mlx-swift-examples`) | Alternative LLM runtime | MIT | Optional; pick ONE of llama.cpp or MLX, default llama.cpp |
| GRDB.swift | SQLite for history/dictionary | MIT | |
| KeyboardShortcuts (sindresorhus) | Hotkey recorder UI (non-Fn chords) | MIT | |
| Sparkle | Optional self-update (off by default; C1) | MIT | P2 |

Dependency rules: pin exact versions in `Package.resolved`; prefer releases published at least 7 days before adoption; record model repo **commit hashes**; verify SHA-256 of every downloaded model file.

Reference implementations worth reading (do not copy code without checking licenses): Hex, VoiceTypr, MiniWhisper, Dictate Anywhere (all listed in FluidAudio's README as Parakeet-based macOS dictation apps).

---

## 5. Memory budget design (C2 ≤ 1 GB)

### 5.1 Profiles

| Component | **Default** ("Accurate, no LLM resident") | **Lean + LLM** | **Enhanced (Apple Intelligence)** |
|---|---|---|---|
| App shell (SwiftUI/AppKit, overlay, DB) | ≤ 100 MB | ≤ 100 MB | ≤ 100 MB |
| Audio buffers (16 kHz mono Float32; 2 min max = 7.7 MB) | ~10 MB | ~10 MB | ~10 MB |
| Silero VAD | ~5 MB | ~5 MB | ~5 MB |
| ASR | Parakeet TDT v3 int8: budget **≤ 550 MB** | Parakeet TDT-CTC 110M: budget ≤ 250 MB (or Whisper base.en q5_1 ≤ 150 MB) | Parakeet TDT v3: ≤ 550 MB |
| Cleanup | Rule-based: ~0 MB | Qwen3-0.6B Q4_K_M: weights 397 MB + KV cache (ctx 1024) + scratch: budget **≤ 500 MB** | Apple Foundation Models (out of process) |
| **Total in-process budget** | **≤ 665 MB** | **≤ 865 MB** | **≤ 665 MB** (+ system RAM reported separately) |

Headroom target: keep measured peak ≥ 100 MB below 1 GB. If a profile measures above 900 MB, it is reworked (smaller quant, smaller context, or the time-slicing in §5.2), never shipped as is.

### 5.2 Memory rules for the implementation

1. **Single resident heavy model per "slot".** A `ModelRegistry` actor owns all models, tracks estimated + measured footprint, and refuses to load a model that would push projected peak over the budget (`MemoryBudget.maxBytes = 1_000_000_000`, `softLimit = 900_000_000`).
2. **Time-slicing fallback** for users who want Parakeet v3 *and* the local LLM: after ASR completes, release ASR, load LLM (mmap'd GGUF; on Apple Silicon llama.cpp can map weights without copying), run cleanup, release LLM, re-warm ASR in the background. Only acceptable if measured added latency ≤ 300 ms; otherwise disallow this combination in the UI.
3. **Lazy load + idle unload.** ASR loads on first hotkey press after launch (show "warming up" in the pill) and is kept warm; unload after configurable idle time (default 30 min). LLM unloads after 5 min idle. TTS unloads immediately after playback.
4. LLM settings: `n_ctx` 1024 (cleanup inputs are short; split anything longer), batch 256, Metal on, mmap on, mlock off, KV cache q8_0 if supported.
5. No Electron/WebView anywhere. SwiftUI + AppKit only.
6. Respond to `DispatchSource.makeMemoryPressureSource` (warning → unload LLM/TTS; critical → unload ASR).
7. A debug HUD (hidden menu item) shows live `phys_footprint` from `task_info(TASK_VM_INFO)`.

### 5.3 Exclusivity matrix

| Loaded together? | ASR | LLM | TTS |
|---|---|---|---|
| ASR | — | Lean profile only | yes |
| LLM | Lean profile only | — | **no** |
| TTS | yes | **no** | — |

---

## 6. How the app works (runtime flow)

```
 Fn down ──► HotkeyMonitor ──► DictationSession.start()
                                  │ play start chime, show pill (listening)
                                  │ AudioCapture: AVAudioEngine input tap → resample to 16 kHz mono Float32
                                  │ ring buffer + live RMS → waveform in pill
                                  │ Silero VAD runs on 32 ms frames (hands-free: auto-stop after 1.2 s silence)
 Fn up ────► DictationSession.stop()
                                  │ trim silence (VAD), reject if < 0.3 s speech (no-op, no paste)
                                  ▼
                           ASREngine.transcribe(pcm, contextualHints: dictionary)
                                  ▼ raw text (+ token timestamps / confidence)
                           CleanupPipeline
                             1. RuleCleaner: fillers, stutters, spoken punctuation ("comma", "new line"),
                                numbers/dates/currency (₹, %), casing, dictionary + snippet substitution
                             2. (optional) LLMCleaner with per-app style prompt + guardrail
                                  ▼ final text
                           ContextProvider: focused app bundle id, secure-field check
                                  ▼
                           TextInserter.insert(final, into: focusedElement)
                                  │ hide pill, stop chime, save to History
                                  ▼
                           done (target: ≤ 400 ms p50 from Fn up)
```

### 6.1 Hotkey (Fn) handling

- Use a `CGEventTap` (`.cgSessionEventTap`, listen-only where possible) on `flagsChanged`, detecting `CGEventFlags.maskSecondaryFn`. Requires **Input Monitoring** permission.
- macOS binds Fn/Globe to emoji/dictation by default. Onboarding must instruct: System Settings → Keyboard → "Press 🌐 key to" → **Do Nothing**, and detect the current value (`defaults read com.apple.HIToolbox AppleFnUsageType`) to warn the user.
- Distinguish hold (≥ 150 ms → push-to-talk) vs double-tap (two taps < 350 ms → hands-free toggle). Ignore Fn when used as a modifier (Fn+arrow etc.): if any other key is pressed while Fn is down, cancel the session silently.
- Escape while recording = cancel.
- Alternative hotkeys via KeyboardShortcuts for users without Fn.

### 6.2 Audio capture

- `AVAudioEngine` input node tap, convert with `AVAudioConverter` to 16 kHz mono Float32.
- Start engine on key down (target ≤ 50 ms to first frame); keep a 300 ms **pre-roll** ring buffer only while the hotkey is held — never record when not activated (privacy).
- Handle device changes (`AVAudioEngineConfigurationChange`), AirPods switching to HFP, and the mic indicator in the menu bar (expected and fine).
- Whisper mode: +12 dB software gain with a limiter, VAD threshold lowered.

### 6.3 ASR engine abstraction

```swift
protocol ASREngine: Actor {
    var id: String { get }
    var estimatedFootprintBytes: Int { get }
    func load() async throws
    func unload() async
    func transcribe(_ pcm16k: [Float], hints: ASRHints) async throws -> Transcript
}
struct ASRHints { var language: String?; var vocabulary: [String] }
struct Transcript { var text: String; var words: [Word]; var language: String?; var avgConfidence: Float? }
```

Implementations: `ParakeetEngine` (FluidAudio), `AppleSpeechEngine` (SpeechAnalyzer/SpeechTranscriber), `WhisperCppEngine`. Vocabulary boosting: FluidAudio supports CTC keyword rescoring with Parakeet CTC 110M for custom terms — evaluate cost vs. post-hoc fuzzy replacement.

### 6.4 Cleanup pipeline

`RuleCleaner` (always on, deterministic, unit-tested):
- Remove fillers: um, uh, er, hmm, "you know", "I mean" (only when sentence-initial/parenthetical), "like" (only in filler position — conservative).
- Collapse immediate repeats ("I I think" → "I think").
- Spoken commands: "new line", "new paragraph", "comma", "period/full stop", "question mark", "open/close quote", "bullet point", "scratch that" (delete previous sentence).
- Simple backtrack heuristics: "X, actually Y" / "X, no, Y" / "X, I mean Y" for short spans (numbers, times, names).
- Inverse text normalization: numbers, percentages, currency (₹/Rs, $), dates, times, emails, URLs.
- Dictionary: case-exact replacement for user terms with fuzzy matching (Levenshtein/phonetic) above a threshold.
- Snippets: if the whole utterance matches a snippet trigger, replace with the expansion.
- Per-app rules: in Terminal/iTerm/VS Code/Cursor/Windsurf/Xcode, "literal mode" (no trailing period, no auto-capitalization, keep symbols).

`LLMCleaner` (optional):
- Prompt: system prompt with the style for the target app + rules ("Fix punctuation and grammar, apply corrections the speaker made, format spoken lists, keep the speaker's words and meaning, never add content, never answer questions in the text"). Output only the text.
- Few-shot examples (5–8) stored in a resource file, versioned.
- **Guardrail:** if the edit distance between rule-cleaned input and LLM output exceeds 40% of input length, or output is > 1.5× / < 0.5× input length, or output contains refusal phrases → discard LLM output and insert the rule-cleaned text.
- Hard timeout 1.5 s → fall back to rule-cleaned text.
- Skip LLM entirely for utterances < 6 words.

### 6.5 Command mode (P2)

Hotkey + Cmd (configurable). Read the selected text via AX `kAXSelectedTextAttribute` (fallback: simulate Cmd+C and read pasteboard, then restore). Prompt: "Instruction: <spoken>. Text: <selection>. Return only the rewritten text." Replace via the insertion path. Requires an LLM (local or Apple). Max selection 2,000 chars in local mode.

---

## 7. Text insertion (the hardest "works everywhere" part)

### 7.1 Strategy order

1. **Secure-field check:** if the focused element's AX role/subrole is `AXSecureTextField` or `IsSecureEventInputEnabled()` is true → do not insert; show "Secure field — copied to clipboard instead" (and only if the user enabled that).
2. **Accessibility insert:** get the system-wide focused element (`AXUIElementCreateSystemWide` → `kAXFocusedUIElementAttribute`); if `kAXSelectedTextAttribute` is settable, set it to the text (replaces selection / inserts at caret). Verify by reading back `kAXValueAttribute` length change where possible.
3. **Pasteboard paste (default fallback):** snapshot all pasteboard items (all types), write our text (mark with `org.nspasteboard.TransientType` and `org.nspasteboard.ConcealedType` so clipboard managers ignore it), post Cmd+V via `CGEvent` (`.cghidEventTap`), wait ~150 ms, then restore the original pasteboard items if `changeCount` is still ours.
4. **Keystroke typing:** `CGEvent.keyboardSetUnicodeString` in chunks — for apps that block paste (some terminals/remote desktops). Slow; only per-app opt-in.

### 7.2 Per-app overrides

A JSON table keyed by bundle ID → insertion method + style + literal mode. Ship defaults for: Terminal, iTerm2, Ghostty, VS Code, Cursor, Windsurf, Xcode, Slack, Messages, WhatsApp, Mail, Outlook, Notes, Chrome, Safari, Arc, Microsoft Word, Google Docs (in browser), Notion, ChatGPT/Claude desktop.

### 7.3 Focus rules

The overlay is an `NSPanel` with `.nonactivatingPanel`, `.canJoinAllSpaces`, `.fullScreenAuxiliary`, `ignoresMouseEvents = true`, level `.statusBar`. LocalFlow must never become the key/active app during dictation. Capture the target app/element at **key-down**; if focus changed by insertion time, insert into the originally captured element if still valid, otherwise copy to clipboard and notify.

### 7.4 Insertion test matrix (acceptance for C5)

TextEdit, Notes, Safari text area, Chrome (Gmail compose, Google Docs), Slack (Electron), VS Code (Electron), Windsurf/Devin Desktop, Terminal, iTerm2, Mail, Messages, Spotlight search field, a native password field (must refuse). Each: insert at caret, replace selection, unicode (₹, é, emoji), multi-line text, clipboard restored afterwards.

---

## 8. Permissions, signing, privacy

| Permission | Why | API to check/request |
|---|---|---|
| Microphone | Capture | `AVCaptureDevice.requestAccess(for: .audio)`; `NSMicrophoneUsageDescription` in Info.plist |
| Accessibility | AX insertion, reading selection, posting Cmd+V | `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` |
| Input Monitoring | Global Fn event tap | `CGPreflightListenEventAccess()` / `CGRequestListenEventAccess()` |
| Speech Recognition | Only if `AppleSpeechEngine` is used | `NSSpeechRecognitionUsageDescription` |

- **Not sandboxed** (App Sandbox forbids controlling other apps via AX/CGEvent). Hardened Runtime on, with `com.apple.security.device.audio-input`.
- Signing: local ad-hoc or personal Apple Development certificate. Note: TCC permissions are tied to the code signature; re-signing with a different identity resets permissions — use one stable signing identity during development.
- Privacy guarantees:
  - Network code exists only in `ModelDownloader` (HTTPS to huggingface.co, pinned revisions, SHA-256 verified). Everything else must compile without `URLSession` access (enforce via module boundaries + a CI grep check).
  - No analytics, no crash reporter that uploads.
  - Audio is never written to disk unless the user enables "Keep audio for debugging" (default off). Buffers are zeroed after use.
  - History stored in `~/Library/Application Support/LocalFlow/history.sqlite`, retention default 7 days, one-click purge. Optional: encrypt with a key in the Keychain (P2).
  - Models stored in `~/Library/Application Support/LocalFlow/Models/<model-id>/<revision>/`.

---

## 9. Architecture and project layout

Language: Swift 6 (strict concurrency), SwiftUI for settings/onboarding, AppKit for menu bar (`NSStatusItem`), overlay (`NSPanel`), and event taps. Minimum macOS: 15.0 (FluidAudio's newer models need macOS 15+; Apple SpeechAnalyzer path gated with `if #available(macOS 26, *)`).

```
local-flow/
  PLAN.md
  AGENTS.md                      # build/test commands, learned gotchas (create in M0)
  Package.swift                  # SwiftPM: app target + library modules + tests
  Sources/
    LocalFlowApp/                # @main, AppDelegate, menu bar, lifecycle, wiring
    Core/                        # DictationSession state machine, Settings, MemoryBudget, ModelRegistry
    Hotkey/                      # CGEventTap Fn monitor, chord hotkeys, tap/hold/double-tap logic
    Audio/                       # AVAudioEngine capture, resampler, ring buffer, RMS, chimes
    VAD/                         # Silero VAD wrapper
    ASR/                         # ASREngine protocol, ParakeetEngine, AppleSpeechEngine, WhisperCppEngine
    Cleanup/                     # RuleCleaner (+ITN, commands, backtrack), LLMCleaner, guardrail, styles
    LLM/                         # LLMEngine protocol, LlamaCppEngine, AppleFoundationEngine
    TTS/                         # TTSEngine protocol, SystemTTS, KokoroEngine (P2)
    Insertion/                   # AXInserter, PasteInserter, TypingInserter, SecureFieldGuard, AppOverrides
    Context/                     # focused app/element capture, selection reader
    Storage/                     # GRDB: history, dictionary, snippets, per-app styles
    Models/                      # ModelDownloader (ONLY module allowed network), manifest, checksums
    UI/                          # Overlay pill, Settings, Onboarding, History window, Debug HUD
  Resources/
    models.manifest.json         # model id, repo, revision hash, files, sha256, size, license, profile
    prompts/cleanup.v1.json      # system prompt + few-shot examples per style
    app-overrides.json
    sounds/
  Tests/
    CleanupTests/                # golden tests for RuleCleaner (hundreds of cases)
    InsertionTests/              # pasteboard snapshot/restore logic
    CoreTests/                   # state machine, budget enforcement
  Bench/
    audio/                       # user-recorded eval set (gitignored if personal)
    run_bench.swift              # WER, latency, memory harness
  scripts/
    build_app.sh                 # assemble .app bundle from SwiftPM build (Info.plist, entitlements, codesign)
    measure_memory.sh            # footprint/vmmap sampler (§11)
```

Key types:

```swift
enum SessionState { case idle, warming, listening(startedAt: Date), transcribing, cleaning, inserting, error(String) }
actor DictationSession { /* owns one utterance; strictly ordered state transitions; cancellable */ }
actor ModelRegistry { func acquire(_ id: ModelID) async throws -> any LoadedModel; func release(_ id: ModelID) async }
struct MemoryBudget { static let hardLimit = 1_000_000_000; static let softLimit = 900_000_000 }
protocol LLMEngine: Actor { func complete(system: String, user: String, maxTokens: Int, timeout: Duration) async throws -> String }
protocol TextInserting { func insert(_ text: String, target: FocusTarget) async throws -> InsertionResult }
```

Concurrency: audio tap callback → lock-free ring buffer; all model work off the main actor; UI updates on `@MainActor`. Each `DictationSession` is cancellable end-to-end (Escape, new hotkey press).

---

## 10. Milestones (each ends with a demo + measured numbers)

### M0 — Spikes and toolchain (go/no-go)
- Decide build path (§12). Create the SwiftPM skeleton and `scripts/build_app.sh` producing a signed `LocalFlow.app` that launches as a menu-bar app (`LSUIElement = YES`).
- Spike 1: CLI `bench-asr` that transcribes a WAV with **(a)** Parakeet v3 via FluidAudio, **(b)** Apple SpeechTranscriber, **(c)** whisper.cpp base.en. Record WER on the eval set, latency, and peak `phys_footprint` for each.
- Spike 2: CLI `bench-llm` running Qwen3-0.6B Q4_K_M and Gemma 3 270M Q4_K_M through llama.cpp on 50 cleanup cases: latency, peak memory, guardrail pass rate.
- Exit: a table in `Bench/RESULTS.md`; pick default ASR + LLM. If Parakeet v3 peak > 600 MB, switch default to v2 4-bit encoder or TDT-CTC 110M.

### M1 — Core dictation loop (P0)
- Fn hold-to-talk, AVAudioEngine capture, VAD trim, Parakeet transcription, RuleCleaner v1, paste insertion with pasteboard restore, overlay pill, chimes, menu bar (enable/disable, quit, profile, mic).
- Exit: dictation works in TextEdit, Notes, Safari, Chrome, Slack, VS Code; C1–C4 measured and passing for the default profile.

### M2 — Robustness + onboarding (P0)
- Onboarding (permissions, Fn setting check, model download with checksum + progress + resume), hands-free mode, Escape cancel, secure-field guard, AX insertion path, per-app overrides, device hot-swap, idle unload, memory-pressure handling, error states in pill.
- Exit: full insertion matrix (§7.4) passes; 2-hour soak test without leaks (footprint drift < 50 MB).

### M3 — Smart cleanup (P1)
- LLMCleaner with guardrail + timeout, per-app styles, backtracking, list formatting, personal dictionary, snippets, history window, whisper mode, Lean profile, optional Apple Foundation Models toggle.
- Exit: cleanup eval (§11.3) ≥ 90% "acceptable" on 200 cases; Lean profile peak < 900 MB.

### M4 — Extras (P2)
- Command mode, TTS read-aloud (System → Kokoro), language routing (Hindi → Whisper small / Apple), streaming preview text (Parakeet EOU), dictionary auto-learn, optional fine-tuned 270M cleanup model.

---

## 11. Verification and measurement

### 11.1 Memory (C2/C3) — `scripts/measure_memory.sh`
- Launch app, find PID, sample every 250 ms: `footprint -p <pid>` (phys_footprint) and `vmmap --summary <pid>`; also record RSS of `aned`, `ANECompilerService`, and any Apple Intelligence process before/after for the separate system-side report.
- Scripted scenario: idle 60 s → 20 dictations of 10 s (auto-played audio through a virtual input device such as BlackHole, or a debug "inject WAV" menu item) → LLM cleanup enabled run → TTS run → idle 5 min.
- Output CSV + summary: peak, p95, idle, drift. Fail if peak ≥ 1,000 MB (hard) or ≥ 900 MB (warning).

### 11.2 ASR accuracy and latency
- Eval set: the user records ~100 utterances (5–20 s) of real usage: emails, Slack messages, code-ish terms, Indian names/places, finance terms (NIFTY, NSE, Kronos), numbers/₹, a few Hinglish lines. Store reference transcripts. Keep the set local (gitignored).
- Metrics: WER (normalized), proper-noun accuracy, p50/p95 latency from key-up to insertion.

### 11.3 Cleanup quality
- 200 golden cases (raw → expected) covering fillers, repeats, backtracks, lists, spoken punctuation, numbers, code/terminal literal mode, "don't change meaning" traps (questions must not be answered, instructions in text must not be executed).
- RuleCleaner: exact-match unit tests. LLMCleaner: exact match or human-graded "acceptable"; track guardrail fallback rate.

### 11.4 Privacy
- Run `nettop -m route -p <pid>` (or Little Snitch) during the full M1 scenario: zero connections. CI-style grep: no `URLSession`/`Network` imports outside `Sources/Models/`.

### 11.5 Standard gates per change
- `swift build -c release`, `swift test`, `scripts/build_app.sh`, `scripts/measure_memory.sh` (for model/pipeline changes).

---

## 12. Build environment notes (important for the agent)

- Only **Command Line Tools** are installed (`xcode-select -p` → `/Library/Developer/CommandLineTools`); `xcodebuild` is unavailable. Swift 6.4 and the macOS 26 SDK are present.
- Two options — **ask the user before choosing**:
  1. **Install Xcode** (recommended): easier signing, entitlements, asset catalogs, Instruments (Allocations/Leaks) for memory profiling, and some packages (CoreML model compilation helpers, Metal shader builds for llama.cpp) are smoother.
  2. **SwiftPM-only**: build with `swift build -c release`, then `scripts/build_app.sh` assembles `LocalFlow.app/Contents/{MacOS,Resources,Info.plist}`, signs with `codesign --force --options runtime --entitlements LocalFlow.entitlements --sign <identity>`. Use prebuilt llama.cpp XCFramework releases instead of compiling Metal shaders. Profiling via `footprint`, `vmmap`, `leaks`, `heap` CLIs.
- CoreML models from FluidAudio ship as compiled `.mlmodelc`; first load triggers ANE compilation (can take seconds to minutes, cached afterwards) — do it during onboarding, not on first dictation.
- Quit Wispr Flow during development to avoid Fn-key conflicts.

---

## 13. Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Parakeet v3 runtime RAM larger than disk size suggests | Breaks C2 with LLM | Measure in M0; fall back to v2 4-bit / TDT-CTC 110M; time-slicing; LLM off by default |
| CoreML/ANE memory partly attributed to system daemons | Misleading C2 claim | Report system-side memory separately (§1, §11.1) |
| Fn key captured by macOS (emoji/dictation) | Hotkey unreliable | Onboarding check of `AppleFnUsageType`; alternative hotkeys |
| Paste blocked or clipboard clobbered | Lost user clipboard | Full multi-type snapshot/restore, transient markers, AX path first, typing fallback |
| Small LLM changes meaning / answers the text | Wrong text inserted | Guardrail + timeout + rule-only default; literal mode for terminals/IDEs |
| Hindi/Hinglish accuracy | Poor results for mixed speech | Language routing to Whisper small / Apple; set expectations |
| TCC permission resets on re-sign | Dev friction | Stable signing identity; document in AGENTS.md |
| Model license changes / NC licenses | Legal | Manifest records license per model; default stack is CC-BY-4.0 / Apache-2.0 / MIT only; attribution screen for CC-BY |
| Supply chain | Malicious package/model | Pinned versions ≥ 7 days old, SHA-256 checks, revision hashes, no auto-updates by default |

---

## 14. Open questions for the user (agent: ask before M0 ends)

1. Install Xcode, or stay SwiftPM-only? (§12)
2. Is the opt-in Apple Intelligence "Enhanced cleanup" acceptable, given its RAM is outside the app's 1 GB?
3. Languages needed beyond English (Hindi/Hinglish priority?).
4. Default hotkey: Fn, or something else?
5. History retention default (7 days?) and whether to store raw audio for debugging (default no).
6. Is personal-use-only licensing (e.g. CC-BY-NC Bark 3.0 Clean) acceptable later, or strictly permissive licenses?

---

## 15. Definition of done (v1)

- Hold Fn → speak → release inserts cleaned text in all apps in §7.4, p50 ≤ 400 ms.
- Default profile measured peak < 900 MB; Lean+LLM profile < 900 MB; idle with models unloaded ≤ 150 MB; reports archived in `Bench/RESULTS.md`.
- Zero network connections during dictation (evidence saved).
- RuleCleaner golden tests pass; LLM cleanup ≥ 90% acceptable on the 200-case set.
- Onboarding takes a fresh user from install to first dictation in under 3 minutes (excluding model download time).
- `AGENTS.md` documents build, run, test, measurement commands and all gotchas found.
