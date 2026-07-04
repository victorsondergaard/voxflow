# SPEC — VoxFlow: local, free voice dictation for macOS

> **v1.1 addendum (terminal-free + accessibility).** Added on top of v1:
> A1. Server binaries are searched first in `VoxFlow.app/Contents/Resources/bin` (bundled), then Homebrew paths — a CI-built app needs no Homebrew.
> A2. `.github/workflows/build-release.yml` builds whisper-server, llama-server, and VoxFlow on Intel + ARM macOS runners, lipo-merges a universal `VoxFlow.app` with servers bundled, ad-hoc signs, zips, and attaches to a GitHub Release on `v*` tags.
> A3. In-app model downloader (URLSession, sequential, `.part`-safe, size-verified) replaces `setup.sh` for end users; menu shows "Download models…" / live progress; first launch auto-offers the download; switching to a missing model or enabling cleanup triggers the needed download.
> A4. Third whisper model option: High Accuracy (`ggml-large-v3-turbo-q5_0.bin`, language auto).
> A5. "Dyslexia & ADHD Assist" toggle (persisted): when on (auto-enables cleanup), cleanup prompts additionally reorder scattered ideas, merge repeats, fix homophones from context, and complete only unmistakable sentence endings — never dropping or inventing ideas.
> A6. "Read Back After Insert" toggle + "Speak Last Dictation" menu item via AVSpeechSynthesizer (proofread by ear).
> setup.sh/build.sh remain as the developer path.

## Goal

An open-source, fully on-device Wispr Flow alternative: hold a hotkey anywhere on macOS, speak, release, and the transcribed (optionally AI-cleaned) text is inserted into the focused app — running on both Intel (2019 MBP 16") and Apple Silicon, buildable with only Command Line Tools + Swift Package Manager (no Xcode).

## In scope

- SwiftPM executable target that runs as a menu bar (NSStatusItem) accessory app; a build script wraps the binary into a proper `.app` bundle with Info.plist (mic usage string) and ad-hoc codesign so TCC permissions work.
- Hold-to-talk global hotkey (default: hold **Right Option**; alternates selectable in menu: Fn, Right Command) via a CGEventTap listening to flagsChanged. Press = start recording, release = stop and process.
- Recording with AVAudioEngine, converted to 16 kHz mono 16-bit WAV in a temp file.
- Transcription via **whisper.cpp** installed from Homebrew (`whisper-cpp`), run as a managed child process using `whisper-server` (HTTP on localhost, model stays loaded). App POSTs the WAV, receives text.
- Two model options in the menu: English (fast) = `ggml-base.en.bin`, Multilingual (Danish/Spanish/auto) = `ggml-small.bin`. Setup script downloads both from Hugging Face (ggerganov/whisper.cpp).
- Optional AI cleanup via **llama.cpp** from Homebrew (`llama.cpp`), run as managed `llama-server` child process with Qwen2.5-1.5B-Instruct Q4_K_M GGUF, OpenAI-compatible chat endpoint. Toggle in menu, off by default on first run; server only launched when enabled.
- Context-aware cleanup: read frontmost app bundle ID via NSWorkspace at hotkey-press time, map to a category, and pick the system prompt:
  - `aiChat` (Claude, ChatGPT desktop, Cursor, etc.): restructure into a clear prompt — fix punctuation, break into paragraphs/bullets where dictated, keep ALL content/context, never answer the prompt.
  - `email` (Mail, Outlook, Spark): light cleanup — remove filler words, fix punctuation/capitalization, natural prose, no restructuring.
  - `messaging` (Messages, Slack, WhatsApp, Discord, Telegram): minimal — fix obvious errors only, keep casual tone.
  - `default` (everything else, incl. browsers): light cleanup as email.
- Text insertion: save current NSPasteboard contents, write transcript, synthesize Cmd-V via CGEvent, restore previous pasteboard contents after 0.5 s.
- Menu bar UI: icon reflects state (idle / recording / processing); menu contains: last transcript (click = copy), Enable AI cleanup toggle, Model submenu (English fast / Multilingual), Hotkey submenu, Launch at Login toggle (SMAppService), "Permissions help…", Quit. Settings persisted in UserDefaults.
- `setup.sh`: checks/install Homebrew deps (`whisper-cpp`, `llama.cpp`), downloads models to `~/Library/Application Support/VoxFlow/models/`, prints status.
- `build.sh`: `swift build -c release`, assembles `VoxFlow.app` into `dist/`, ad-hoc codesigns, prints "move to /Applications" instruction. Universal note: builds natively for the host arch (Intel on the user's MBP; ARM on Apple Silicon); optional `--universal` flag attempts both-arch build + `lipo` when SDK allows.
- `README.md`: plain-language install (3 commands), permissions walkthrough (Microphone + Accessibility), usage, troubleshooting, model/latency guidance for Intel, iOS future-phase architecture notes, MIT license note.
- Graceful onboarding: on first run, if models or brews are missing, menu shows "Setup needed…" item that opens README/help alert with the exact commands.

## Out of scope (v1)

- iOS/iPadOS app or custom keyboard (future phase; README contains architecture notes only).
- Real-time streaming transcription while speaking (release-to-transcribe only).
- Per-browser-tab context detection (browsers get `default` category).
- Custom vocabulary, speaker profiles, transcript history database (only the single last transcript is kept, in memory).
- Settings window/GUI beyond the status menu; no Sparkle auto-update; no notarization/distribution signing (ad-hoc only).
- Bundling whisper/llama binaries inside the repo (Homebrew provides per-arch builds; keeps repo tiny and license-clean).
- Voice commands ("new line", "delete that").

## Requirements

1. `swift build -c release` succeeds with only Command Line Tools installed (no Xcode) on macOS 13+, Intel and Apple Silicon. No Xcode-project files in repo.
2. `./build.sh` produces `dist/VoxFlow.app` containing the binary, `Info.plist` with `NSMicrophoneUsageDescription`, `LSUIElement=true`, and passes `codesign --verify`.
3. Launching the app shows a menu bar icon and no Dock icon.
4. If Accessibility permission is missing, the app detects it (AXIsProcessTrusted), shows an alert with instructions, and the menu item "Permissions help…" reopens System Settings to the right pane.
5. Holding the configured hotkey ≥150 ms produces a dictation (icon changes to recording once the hold passes 150 ms); releasing stops it. Taps shorter than 150 ms are discarded entirely: audio capture starts at press so no speech is lost, but the captured audio is thrown away — no transcription, no insertion, no icon change.
6. Recorded audio is written as 16 kHz mono 16-bit PCM WAV regardless of input device sample rate.
7. On app start (and on model switch) the app spawns `whisper-server` with the selected model; the child process is killed on quit and on model switch. Termination handlers are identity-checked so deliberate restarts can't orphan the replacement server, and child PIDs are recorded to a pidfile that is used to kill stale children left behind by a crash/force-quit on next launch.
8. A 5-second English utterance returns transcribed text and inserts it into the focused app via Cmd-V; prior clipboard contents are restored afterwards.
9. With Multilingual model selected, language is auto-detected (whisper `language=auto`), so Danish or Spanish speech transcribes in that language.
10. With AI cleanup OFF, raw whisper text (trimmed, whisper artifacts like `[BLANK_AUDIO]` removed) is inserted; llama-server is not running.
11. With AI cleanup ON, transcript is sent to llama-server with the category-specific system prompt; on any cleanup failure or timeout (>20 s) the raw transcript is inserted instead (never lose the user's words).
12. Frontmost-app category mapping matches the table in this spec; unknown bundle IDs map to `default`.
13. All settings (hotkey, model, cleanup toggle) persist across relaunches via UserDefaults.
14. `setup.sh` is idempotent: safe to run twice; skips already-installed brews and already-downloaded models; verifies model file sizes are > 100 MB after download.
15. If whisper-server is not reachable when the user finishes speaking, the app shows an alert/menu error state instead of silently doing nothing.
16. No network calls anywhere except: Homebrew installs and model downloads in `setup.sh`, and localhost HTTP to the two servers. The Swift app itself makes no external requests (verifiable by code inspection).
17. README covers: install steps, both permissions with exact System Settings paths, latency expectations on Intel vs Apple Silicon, how to switch models/hotkey, troubleshooting (server port busy, permission reset via `tccutil`), MIT license, iOS phase-2 notes.
18. MIT LICENSE file present.

Assumption: default whisper-server port 8321 and llama-server port 8322 (uncommon ports to avoid clashes); if busy, the app probes up to 10 ports starting at the base (8321–8330), skipping ports already assigned to the other child server.
Assumption: menu bar icon uses SF Symbols (mic / waveform) via NSImage(systemSymbolName:), available macOS 11+.
Assumption: minimum deployment target macOS 13 (Ventura) — the user's 2019 MBP supports up to macOS 26, so this is safe, and SMAppService requires 13+.
Assumption: Qwen2.5-1.5B-Instruct-Q4_K_M (~1.0 GB) is the default cleanup model; menu has no model picker for the LLM in v1.

## Structure

```
VoxFlow/
├── SPEC.md
├── LICENSE                     (MIT)
├── README.md
├── Package.swift               (swift-tools 5.9, single executable target)
├── setup.sh                    (brew deps + model downloads)
├── build.sh                    (release build → dist/VoxFlow.app)
├── Resources/Info.plist        (template used by build.sh)
└── Sources/VoxFlow/
    ├── main.swift              (NSApplication bootstrap, accessory policy)
    ├── AppDelegate.swift       (wires everything, lifecycle, server mgmt start/stop)
    ├── StatusItemController.swift  (menu bar icon, menu, state display)
    ├── Settings.swift          (UserDefaults-backed settings + app category map)
    ├── HotkeyMonitor.swift     (CGEventTap flagsChanged, press/release callbacks)
    ├── AudioRecorder.swift     (AVAudioEngine capture → 16k mono WAV)
    ├── ServerManager.swift     (spawn/monitor/kill whisper-server & llama-server, port probing)
    ├── Transcriber.swift       (HTTP client for whisper-server /inference)
    ├── Cleaner.swift           (HTTP client for llama-server /v1/chat/completions, prompts per category)
    ├── ContextDetector.swift   (frontmost bundle id → category)
    └── TextInserter.swift      (pasteboard save/set/Cmd-V/restore)
```

## Workstreams

- **A — App shell & settings**: `main.swift`, `AppDelegate.swift`, `StatusItemController.swift`, `Settings.swift`, `Package.swift`. Defines the shared protocols/types (`DictationState`, `AppCategory`, settings keys) that other streams build against — the contracts are pinned in this spec, so B–D can proceed in parallel once type names below are fixed.
- **B — Capture**: `HotkeyMonitor.swift`, `AudioRecorder.swift`.
- **C — Inference**: `ServerManager.swift`, `Transcriber.swift`, `Cleaner.swift`.
- **D — Output & context**: `ContextDetector.swift`, `TextInserter.swift`.
- **E — Scripts & docs**: `setup.sh`, `build.sh`, `Resources/Info.plist`, `README.md`, `LICENSE`.

Shared contract (pinned): `enum AppCategory { case aiChat, email, messaging, general }`; `Settings` exposes `hotkey: Hotkey`, `modelChoice: ModelChoice (.englishFast/.multilingual)`, `cleanupEnabled: Bool`; capture reports via `func hotkeyPressed()` / `hotkeyReleased()` on AppDelegate; Transcriber/Cleaner are `async throws -> String`.

Dependency note: E is fully independent. B, C, D depend only on the pinned contract. A integrates last.

## Edge cases

- Hotkey tapped accidentally (<150 ms) → ignore entirely.
- Silence / empty transcription → insert nothing, flash icon, keep last transcript unchanged.
- whisper-server crash mid-session → ServerManager detects termination and relaunches once; second failure surfaces error in menu.
- Model file missing → menu shows "Setup needed…", recording disabled, alert with `./setup.sh` instruction.
- Another app occupies chosen ports → probe up to +10 ports before failing with a clear error.
- Secure input fields (passwords) → Cmd-V may be blocked by the OS; document in README, do not attempt workarounds.
- Clipboard held transient data (e.g., password manager) → restore original pasteboard after paste; document the 0.5 s window in README.
- Mic permission denied → alert with System Settings deep link.
- Very long dictation (>60 s) → allowed; whisper-server handles chunking; UI stays in processing state until done.
- App switched between press and release → category is captured at press time (where the user started dictating).

## Done checklist

- [ ] Builds with `swift build -c release` using CLT only, no Xcode files in repo (R1)
- [ ] build.sh emits signed dist/VoxFlow.app with mic usage string + LSUIElement (R2)
- [ ] Menu bar icon, no Dock icon (R3)
- [ ] Accessibility check + guidance flow present (R4)
- [ ] Hold-≥150 ms-to-record, short-tap ignored (R5)
- [ ] 16 kHz mono 16-bit WAV output regardless of device rate (R6)
- [ ] whisper-server lifecycle: spawn on start/model-switch, kill on quit/switch (R7)
- [ ] End-to-end dictation inserts text and restores clipboard (R8)
- [ ] Multilingual model uses language auto-detect (R9)
- [ ] Cleanup OFF → raw text, no llama-server process (R10)
- [ ] Cleanup ON → category prompt; failure/timeout falls back to raw text (R11)
- [ ] Category map implemented as specified; unknown → default (R12)
- [ ] Settings persist via UserDefaults (R13)
- [ ] setup.sh idempotent, verifies model sizes (R14)
- [ ] Unreachable whisper-server surfaces a visible error (R15)
- [ ] No non-localhost network calls in Swift code (R16)
- [ ] README complete per R17 (R17)
- [ ] MIT LICENSE present (R18)
