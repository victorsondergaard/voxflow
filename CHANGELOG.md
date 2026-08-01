# VoxFlow Changelog

Every release is permanently downloadable from the
[Releases page](https://github.com/victorsondergaard/voxflow/releases) — **to
revert, just download any older `VoxFlow.app.zip` and drag it into
Applications**. Settings and models are stored outside the app, so switching
versions never loses anything.

Developers: every entry below maps to commits on `main`; use
`git log --oneline`, `git revert <commit>` or `git checkout <tag>` to move
the source to any point in this history.

## Unreleased / latest

- **Read Selected Text aloud** (dyslexia accessibility): select text in any
  app → press ⌃⌥R, or right-click → Services → "Read Aloud with VoxFlow".
  Toggleable in the menu; trigger again to stop.
- **Read a PDF or Image Aloud (OCR)**: fully on-device OCR (Apple Vision) for
  PDFs, scans and photos of text — extracted text is copied to the clipboard
  and read aloud. Architecture keeps a seam for a heavyweight OCR model
  (e.g. baidu/Unlimited-OCR) as an optional future engine on powerful Macs.
- **One-click updates**: "Update available — Install…" now downloads, swaps
  and relaunches the app automatically (fallback: Releases page).
- CHANGELOG.md added (this file).

## v1.0.14 — first signed release

- Builds are signed with a persistent community certificate: macOS now
  recognizes every update as the same app, so **permissions stick across
  updates** (one final re-grant when moving onto v1.0.14+).
- Release notes updated accordingly.

## v1.0.8–v1.0.13 — accuracy & polish wave

- Missed-word fixes: 0.25 s post-release audio tail, 0.3 s silence padding
  around clips, beam-search decoding (`-bs 5`).
- Pauses no longer create line breaks (segment newlines flattened).
- Spoken self-corrections ("well actually…", "no wait…") now keep only the
  final wording — with worked examples for the small cleanup model.
- HUD: true capsule shape (straight top/bottom, semicircular ends), teal
  bars, real scrolling waveform (32 ms level windows, perceptual curve).
- Accessibility grant auto-detected — no relaunch needed after granting.

## v1.0.7 — speed & responsiveness

- Per-Mac default model: fast English on Intel, High Accuracy on Apple
  Silicon; both engines use most CPU cores.
- Floating waveform pill appears instantly while dictating; rolling-wave
  loading animation while transcribing.
- In-app update checker with version-stamped builds.

## v1.0.1–v1.0.6 — terminal-free era

- whisper-server + llama-server bundled inside the app (universal Intel +
  Apple Silicon builds via GitHub Actions).
- In-app model downloads, High Accuracy model option, Dyslexia & ADHD
  Assist mode, Read Back After Insert, Speak Last Dictation.

## v1.0.0 lineage — original LocalFlow prototype

- SwiftPM menu bar app: hold-to-talk dictation via whisper.cpp, app-aware
  AI cleanup via llama.cpp, clipboard-preserving text insertion.
