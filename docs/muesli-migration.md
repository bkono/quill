# Reuse Muesli's local setup

Quill can read the speech models Muesli has already downloaded and use the same
local Ollama model for meeting notes. Muesli remains installed; Quill does not
move, copy, delete, repair, or download imported model assets.

## On the work laptop

Build this branch using the normal installation instructions, then run:

```sh
quill models                 # list compatible caches and missing files
quill import-muesli          # preview the selected meeting model + Ollama settings
quill import-muesli --write  # save to ~/.config/quill/config.json
quill doctor                # selected cache + Ollama reachability/model preflight
```

If Quill already has a `transcription` or `summaries` section, preview with
`quill import-muesli --replace` and apply with `--replace --write`. Replacement
changes model/summary selections only; it preserves your recording directory,
hooks, microphone processing, meeting awareness, and transcription enabled flag.
Every existing config receives a separate backup before a write. Malformed
configs fail instead of being overwritten. Restart a running Quill afterward.

Import reads `~/Library/Application Support/Muesli/config.json`. For MuesliDev or
a custom installation, pass `--config '/path/to/config.json'`. Only meeting-model
and Ollama fields are imported; provider credentials and unrelated Muesli settings
are never copied. The command needs Muesli's explicit meeting model selection.
If it is absent, select a meeting model in Muesli first.

Quit Muesli and disable its launch-at-login setting when ready to switch, so it
will not also offer to record or intercept dictation shortcuts. Leave its model
caches intact. Quill and Parrot still need their own macOS microphone,
accessibility (Parrot), and system-audio (Quill) permissions. Record a short
synthetic meeting before relying on the installation. This validates actual Core
ML loading and audio permissions, which file checks alone cannot prove.

Parrot's companion PR imports Muesli's **dictation** selection. Quill imports the
**meeting** selection and owns meeting-note generation. Their recording and
completion behavior remains independent of Muesli.

## Supported assets

| Muesli selection | Quill engine/model | Existing cache |
| --- | --- | --- |
| Parakeet v2 | `parakeet` / `v2` | `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v2` |
| Parakeet v3 | `parakeet` / `v3` | same parent, `parakeet-tdt-0.6b-v3` |
| Parakeet Redux | `parakeet` / `redux` | same parent, `parakeet-redux` |
| Parakeet Unified | `parakeet-unified` / `unified` | same parent, `parakeet-unified-en-0.6b-coreml` |
| Whisper Tiny/Small (multilingual or English), Medium English, Large Turbo | `whisperkit` / Muesli's variant ID | `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-<variant>` |

Whisper also needs its tokenizer already cached under
`~/Documents/huggingface/models/openai/whisper-<base variant>/` (or bundled with
the model). Both `tokenizer.json` and `tokenizer_config.json` must exist and parse.
If missing, finish setup/transcribe once in Muesli, then retry the import.
WhisperKit Core ML assets are not interchangeable with whisper.cpp GGML files,
MLX weights, or Ollama models. Unsupported selections fail explicitly with no
silent fallback. Muesli's other experimental speech backends are not supported.

An explicit `model_directory` always uses strict local loading. Missing weights,
partial downloads, invalid Muesli completion manifests, or load failures do not
trigger cache repair or network downloads. The original unconfigured Quill
Parakeet v2 default retains its existing first-use download behavior.

To select a compatible cache manually:

```json
{
  "transcription": {
    "enabled": true,
    "engine": "parakeet",
    "model": "v3",
    "model_directory": "~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3"
  },
  "summaries": {
    "enabled": true,
    "url": "http://localhost:11434",
    "model": "qwen3:8b"
  }
}
```

Use your installed Ollama model name; `qwen3:8b` above is only an example.
Quill never runs `ollama pull`. `quill doctor` lists installed Ollama model names
and verifies that the configured model uses local weights. The URL must be a
loopback HTTP(S) origin; remote servers, redirects, and cloud models are rejected.

## Meeting notes and retries

Summaries are off by default and imported only when Muesli's selected summary
provider is Ollama. An unavailable Ollama server or invalid summary config never
blocks recording. Transcription writes `transcript.json` and `transcript.md`
first and fires the existing `on_stop` hook as before. An independent serial
queue then writes `summary.md`; failures go to `summary.log` and a notification.
The hook does **not** wait for notes.

Long transcripts are split into bounded requests and their notes synthesized;
Quill does not silently truncate the end of a meeting. Qwen-style thinking-only,
empty, or incomplete responses are treated as failures rather than final notes.
AI notes can still contain errors; the original speaker-tagged transcript remains
the source of truth.

```sh
quill summarize ~/Recordings/2026.11.03-1000             # retry one session
quill summarize ~/Recordings/2026.11.03-1000 --overwrite # regenerate existing notes
```

Pending summary jobs carry `.summary-pending` and resume on the next Quill launch.
Turning summaries on does not summarize your historical recording collection.
Existing notes are not overwritten unless explicitly requested. Keep the daemon
closed when manually regenerating the same pending session.

## Compatibility evidence and invariants

Integration was checked against [Muesli source commit 5a94fa0](https://github.com/Muesli-HQ/muesli/tree/5a94fa0f20fe712617124f561e476e227322586d):
`ManagedASRModelDownloads.swift` (shared paths and completeness contracts),
`Models.swift` (wire keys and backend IDs), `FluidAudioBackend.swift`,
`ParakeetUnifiedBackend.swift`, `WhisperCppBackend.swift`, and
`MeetingSummaryClient.swift`.

FluidAudio is pinned to 0.17.3 for its strict `loadLocal` API. WhisperKit is pinned
to Muesli's resolved revision, with its tokenizer explicitly injected to avoid
WhisperKit's network fallback. No Muesli recorder, silence detector, or meeting
completion logic is imported. Quill continues to prompt before stopping; it
never stops a recording automatically.

Validation uses synthetic cache files and mocked HTTP responses. Actual Core ML
inference, microphone/system audio permissions, and the work laptop's cache must
be checked on that laptop. No user meetings were used as test inputs.
