# VoxFlow

**Free, open-source, 100% on-device voice dictation for macOS.** Hold a key, speak, release — your words appear wherever your cursor is. No subscription, no account, no audio ever leaving your Mac.

Powered by [whisper.cpp](https://github.com/ggerganov/whisper.cpp) (OpenAI's Whisper, running locally) with optional on-device AI cleanup via [llama.cpp](https://github.com/ggml-org/llama.cpp). Works on Intel Macs and Apple Silicon.

## Install — no terminal needed

1. Go to the [**Releases page**](../../releases/latest) and download `VoxFlow.app.zip`.
2. Unzip it and drag **VoxFlow.app** into your **Applications** folder.
3. Open it. If macOS warns about an unidentified developer: open **System Settings → Privacy & Security**, scroll down, click **“Open Anyway”**. (VoxFlow is unsigned because Apple charges $99/yr for code signing — the source code is right here for anyone to inspect.)
4. Grant the two permissions when asked:
   - **Microphone** — to hear you.
   - **Accessibility** — to detect the hold-to-talk key and type for you. (System Settings → Privacy & Security → Accessibility → enable VoxFlow, then relaunch.)
5. On first launch VoxFlow downloads its speech model automatically (progress shows in the menu bar menu).

## Use it

Click into any text field, **hold Right Option (⌥)**, speak, release. Done.

While you speak, a soft floating pill appears at the bottom of your screen with waveform bars that dance to your voice; while VoxFlow transcribes, the bars play a rolling wave so you always know it's working.

The menu bar mic icon shows state: outline = idle, filled = recording, waveform = thinking. Quick taps (under 150 ms) are ignored so normal typing is unaffected.

## Accuracy

VoxFlow's default **High Accuracy** model (Whisper large-v3-turbo) substantially outperforms Apple's built-in dictation in independent benchmarks and everyday use — especially with accents, technical vocabulary, fast speech, and mixed languages — and it adds proper punctuation. Two lighter models are available in the menu when you want more speed on older Intel Macs:

| Model (menu) | Best for | 10 s of speech takes about |
|---|---|---|
| High Accuracy (default on Apple Silicon) | Best-in-class accuracy, ~100 languages | Apple Silicon: 1–3 s · Intel 2019: 10–25 s |
| Multilingual | Good accuracy, Danish/Spanish/etc. | Apple Silicon: ≤2 s · Intel 2019: 5–15 s |
| English (fast) (default on Intel Macs) | Snappy dictation on Intel | Apple Silicon: ≤1 s · Intel 2019: 2–5 s |

VoxFlow picks the right default for your Mac automatically. On Intel, step up to Multilingual (still faster than High Accuracy, beats native dictation) whenever you need Danish/Spanish or tougher audio.

## Dyslexia & ADHD support

VoxFlow was built with neurodivergent writers in mind:

- **Dyslexia & ADHD Assist** (menu toggle): when your ideas come out jumbled, out of order, repeated, or trailing off — VoxFlow's on-device AI reorders related ideas so they sit together, merges repeats into the clearest version, fixes homophones (their/there, to/too) from context, and completes a sentence only when the ending is unmistakable. It never drops or invents an idea.
- **Prompt structuring:** when you dictate into an AI app (Claude, ChatGPT, Cursor, Perplexity…), your speech is organized into a clear, well-formatted prompt — paragraphs, bullets where you listed things — with every detail kept. Emails get a light polish only; chat messages stay casual. VoxFlow detects which app you're in automatically.
- **Read Back After Insert** (menu toggle): VoxFlow speaks the final text aloud so you can proofread by ear instead of eye.
- **Speak Last Dictation** (menu): re-hear the last thing it typed, anytime.
- No timers, no flashing UI, nothing to configure before speaking: hold one key, talk, release.

## Everything in the menu

**AI Cleanup** (on-device LLM: removes "um"s, fixes punctuation, app-aware formatting; if it ever fails or takes >20 s, your raw words are inserted instead — you never lose what you said) · **Dyslexia & ADHD Assist** · **Read Back After Insert** · **Model** picker · **Hotkey** (Right ⌥ / Fn / Right ⌘) · **Launch at Login** · last transcript (click to copy) · **Download models…** · **Permissions help…**

## Updating

VoxFlow checks GitHub once a day for a new version. When one exists, the menu bar menu shows **"Update available — Download…"** — click it, grab the new zip, and drag the app to Applications again. That's it.

## Privacy

Everything runs on your Mac: microphone → whisper.cpp (localhost) → optional llama.cpp (localhost) → your text field. The app's only internet use is downloading models from Hugging Face on first run and a daily version check against api.github.com (no identifiers sent). Nothing is ever uploaded.

## Troubleshooting

- **Nothing happens on release** — open the menu bar icon; a ⚠️ line explains why. Most common: Accessibility not granted (grant it, relaunch).
- **Text lands in the menu but not the app** — secure fields (passwords) block synthetic paste by design. Click the transcript in the menu to copy it.
- **First dictation is slow** — the model loads on first use; later dictations are much faster.
- **Clipboard** — your previous clipboard is restored ~0.5 s after each dictation.
- **Reset permissions**: System Settings → Privacy & Security → Microphone / Accessibility → toggle VoxFlow off and on.

## Build from source (optional, for developers)

```bash
xcode-select --install   # Apple Command Line Tools (free)
./setup.sh               # engines via Homebrew + models
./build.sh               # → dist/VoxFlow.app
```

The downloadable release is produced by [GitHub Actions](.github/workflows/build-release.yml): universal binaries (Intel + Apple Silicon), whisper-server and llama-server bundled inside the app.

## iOS / iPadOS (planned)

A system-wide iOS version means a custom keyboard extension with a mic button. whisper.cpp runs well on modern iPhones/iPads (tiny/base models inside a keyboard's memory limits). Requires Xcode and an Apple Developer account ($99/yr) for distribution — see SPEC.md notes. Contributions welcome.

## License

MIT — see [LICENSE](LICENSE). whisper.cpp & llama.cpp: MIT. Whisper models: MIT (OpenAI). Qwen 2.5 1.5B (cleanup): Apache-2.0.
