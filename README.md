# Narrateify (fork)

A macOS menu-bar app that reads selected text aloud the moment you press a
hotkey. Fork of [yasarkaancan/Narrateify](https://github.com/yasarkaancan/Narrateify),
rebuilt around fast engines, multilingual reading, and a section-based reader.

**No Python. No venvs. No PyTorch.** Every engine runs natively in Swift.

## What's different from upstream

- **Engines**
  - **Edge TTS**: Microsoft's neural Read Aloud voices (the same ones SuperCmd
    and the Read Aloud extension use). Free and online.
  - **Supertonic 3**: on-device and multilingual. It runs on the CPU through ONNX
    Runtime and needs about 400 MB of RAM while loaded.
  - **Apple voices**: always available.
  - **ElevenLabs** and **OpenAI**: optional.
  - Kokoro and Chatterbox are gone. They needed a system Python and several GB of
    PyTorch, and Kokoro can't speak German anyway.
- **Languages you read.** Pick the one or two languages you actually read. Only
  those are detected:
  - Detection runs per sentence, constrained to your languages.
  - Short or ambiguous bits inherit the language around them.
  - Anything else, French for example, is read as whichever of your languages
    it's closest to.
  - With a single language, detection is skipped.
- **A fallback chain per language.** For example, German could be Edge Seraphina,
  then Supertonic M1, then Apple Anna.
  - The first engine that works reads the section.
  - An unreachable online engine is skipped for 10 minutes, so you don't pay the
    failure latency on every sentence.
- **A reader overlay instead of a scrubber.**
  - Text is split into sensible sections, and the spoken word is highlighted.
  - ←/→ jumps a section and space plays/pauses.
  - ↑/↓ changes speed (0.5–3×, applied at playback so it's identical for every
    engine and changes instantly).
- **Fast start.**
  - The first sentence is synthesized on its own and starts playing while the
    rest is prefetched.
  - Local models can stay loaded or unload after N idle minutes.
- **Engine cards** (Settings → Engines) show VoiceInk-style speed/quality
  ratings, RAM, disk and privacy. **Measure speed** times each engine on your Mac.

## Hotkeys (customizable)

| Shortcut | Action |
|---|---|
| `⌃⌥R` | Read selected text |
| `⌃⌥S` | Read a screen region (OCR) |
| `⌃⌥V` | Read clipboard |
| `⌃⌥N` | Quick Narrate window |
| `⌃⌥Space` | Play / pause |
| `⌃⌥←` / `⌃⌥→` | Previous / next section |
| `⌃⌥↑` / `⌃⌥↓` | Faster / slower |
| `⌃⌥X` | Stop |

## Build

```bash
brew install xcodegen
xcodegen generate
open Narrateify.xcodeproj   # ⌘R
```

macOS 14+, Xcode 15+. On first use, grant **Accessibility** (to read the
selection) and **Screen Recording** (for OCR), then relaunch.

Supertonic downloads about 400 MB of model files from Hugging Face the first time
you enable it (Settings → Engines). They're stored in
`~/Library/Application Support/Narrateify/Models/`.

## Caveats

- **Edge TTS uses Microsoft's unofficial Read Aloud endpoint.**
  - On 2026-10-10 the old endpoint started returning 403 in parts of Europe
    ([edge-tts#490](https://github.com/rany2/edge-tts/issues/490)).
  - This app uses the newer `api.msedgeservices.com` host, which still accepts the
    current token, and falls back to the old host.
  - If Microsoft breaks it for good, your chain falls through to Supertonic.
- **Supertonic weights** are licensed OpenRAIL-M by Supertone. The upstream repo is
  archived; the weights stay on Hugging Face.

MIT licensed, like upstream.
