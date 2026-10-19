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
    Runtime and needs about 120 MB of RAM while loaded (Core ML decoder on macOS 15+).
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
  - ←/→ jumps a section and space plays/pauses (when the reader has focus;
    globally via ⌃⌥[ / ⌃⌥]).
  - ↑/↓ changes speed (globally ⌃⌥= / ⌃⌥-) (0.5–3×, applied at playback so it's identical for every
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
| `⌃⌥[` / `⌃⌥]` | Previous / next section |
| `⌃⌥=` / `⌃⌥-` | Faster / slower |
| `⌃⌥X` | Stop |

## Use it from anything: CLI, MCP, local API

Every way in uses the same section planner, per-language engine chains and fallbacks as the hotkey.
Leave the voice options out and you get exactly what the hotkey would read.

### CLI

`narrateify` ships inside the app (`Narrateify.app/Contents/SharedSupport/narrateify`).
`scripts/install-local.sh` symlinks it to `~/.local/bin`; otherwise run `…/narrateify install`.
It starts the app in the background if it isn't running.

```bash
narrateify say "Read this aloud"                 # through the reader, like ⌃⌥R
narrateify say --wait < notes.txt                # stdin; returns when it's done talking
narrateify synth "Hallo zusammen" -o hi.wav      # render to a file (or .m4a)
narrateify synth -o - "Stream me" | ffplay -     # WAV stream to stdout, starts with the first section
narrateify synth "…" -o clip.wav --json --words  # exact duration, engine/voice per section, word times
narrateify batch clips.json --out-dir vo/        # [{"id","text",…}] → vo/<id>.wav + JSON manifest
narrateify voices --language de                  # * = in your chain
narrateify engines
narrateify stop
```

Voice options work on every command:

| Option | What it does |
|---|---|
| `--voice` | Voice id or name: `de-DE-KatjaNeural`, `edge:en-US-AvaNeural`, `F1`, `Anna`. A voice pins the language. |
| `--engine` | `edge`, `supertonic`, `apple`, `elevenLabs` or `openAI`. |
| `--language` | Skips language detection. |
| `--strict` | No fallback. |
| `--speed` | 0.5–3. |
| `--raw` | Skips text cleanup and pronunciation rules. |

Files render at 1× unless you pass `--speed`. `say` uses the app's speed.
Text that starts with `-` goes after `--`, as in `narrateify say -- "-5 degrees"`. Unknown flags are errors.
`-o` must be a `.wav`/`.m4a` file path. It is never a directory.

### MCP

```bash
claude mcp add --scope user narrateify -- ~/.local/bin/narrateify mcp
codex mcp add narrateify -- ~/.local/bin/narrateify mcp
```

| Tool | What it does |
|---|---|
| `speak` | Reads aloud through the reader, like the hotkey. |
| `synthesize` | Text → file, returning the path, exact duration and sections, plus words if asked. |
| `synthesize_batch` | Clips → `<out_dir>/<id>.wav`, returning a manifest with durations. |
| `list_voices` | Voices you can pass as `voice`. |
| `list_engines` | Engines and their health per language. |
| `status` | Whether it's reading, plus the current chains. |
| `stop` | Stops reading. |

### Local API

It runs on `http://127.0.0.1:47801`. If that port is taken, the real port is in
`~/Library/Application Support/Narrateify/api.json`.
It only listens on loopback. It refuses requests that carry a browser `Origin`, or a `Host` that isn't localhost, so web pages can't drive it.
You can turn it off with `defaults write com.narrateify.Narrateify localAPIEnabled -bool false`.

| Endpoint | |
|---|---|
| `GET /v1/status` | Version, whether it's reading, speed, each language's chain |
| `GET /v1/engines` | Engines and their health per language |
| `GET /v1/voices?engine=&language=` | Usable voices |
| `POST /v1/speak` | `{text, voice?, engine?, language?, strict?, clean?}` |
| `POST /v1/stop` | Stops reading |
| `POST /v1/synthesize` | `{text, …voice options, speed?, format?: "wav"\|"m4a", out?, stream?, words?}` |

`/v1/synthesize` replies in one of three ways:
- With `out` (an absolute path), it writes the file and returns JSON: `path`, `duration` (read back from the file), `sections[]` (text, language, engine, voice, start, duration), `fell_back`, and `words[]` if asked.
- Without `out`, it returns the audio bytes, with `X-Narrateify-Duration` and `X-Narrateify-Voices` headers.
- With `stream: true`, it returns a WAV that starts as soon as the first section is ready.
  If the client hangs up, rendering stops. If an engine fails mid-stream, the connection drops instead of ending cleanly.

Output is 48 kHz mono.

```bash
curl -s localhost:47801/v1/synthesize -d '{"text":"Hi","out":"/tmp/hi.wav"}'
```

## Build

```bash
brew install xcodegen
xcodegen generate
open Narrateify.xcodeproj   # ⌘R
```

macOS 14+, Xcode 15+. On first use, grant **Accessibility** (to read the
selection) and **Screen Recording** (for OCR), then relaunch.

Supertonic downloads about 220 MB of model files (about 400 MB on macOS 14) from Hugging Face the first time
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
