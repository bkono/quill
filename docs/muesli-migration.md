# Reuse Muesli's local setup

Quill can read the speech models Muesli has already downloaded and use the same
local Ollama model for meeting notes. Muesli remains installed; Quill does not
move, copy, delete, repair, or download imported model assets.

## On the work laptop

Build and install this fork using the normal instructions, then launch Quill.
On first launch, if Muesli or MuesliDev has a configuration, **Models & Notes**
opens with an offer showing the exact speech and local Ollama models. Choose
**Use this setup**. Existing model/note selections are previewed as replacements;
other configuration keys are kept and the old file is backed up.

Choose **Keep my setup**, dismiss the window, or leave an invalid offer: the
attempt and its outcome are remembered. Normal later launches do not repeat it.
If neither Muesli configuration exists on first discovery, that result is also
remembered. Open **Models & Notes… → Check Muesli again…** whenever you want to
retry, including after installing Muesli later. The window also lets you choose a
custom config file or MuesliDev when both installations exist. Discovery and
validation do not block recording and never start a large default download.

**Models & Notes** shows:

- The saved transcription model/backend, a cached-model picker, and the model
  currently running when it differs during a settings change.
- Quill's own configuration path and import provenance. Import makes a snapshot
  of settings; Quill does not follow Muesli's future configuration changes.
- Exact model and tokenizer paths, shared FluidAudio/Hugging Face versus custom
  cache location, missing-file status, and **Show in Finder**.
- Saved and running note models, local Ollama address, installed-model lookup,
  and controls to enable/disable or change notes without restarting Quill.

Shared cache location is not an ownership claim: Muesli and other apps can use
these files. Removing **Muesli.app alone** does not delete those caches. An
uninstaller or cleanup that deletes the referenced model/tokenizer folders will
break that selection. Keep or restore the files, choose another cached model,
or re-import after repairing the source setup. **Retry pending transcripts**
resumes recordings that have no transcript yet. Existing transcripts are kept.
Ollama owns its separate model storage; keep the local service and selected model
available for notes. Quill never downloads or moves any of these assets silently.

Quit Muesli and disable its launch-at-login setting when ready to switch, to
avoid duplicate recording prompts or competing dictation hotkeys. Leave shared
caches intact. Quill and Parrot still need their own macOS permissions. Record a
short synthetic meeting to verify actual Core ML loading and audio permissions;
file checks alone cannot prove those.

Parrot's companion PR offers to import Muesli's **dictation** selection in its
native app onboarding/Settings. Quill imports the **meeting** selection and owns
meeting-note generation. Capture and completion behavior stay independent of
Muesli.

### Optional command-line diagnostics and re-import

No command is required for initial app onboarding. For scripting or troubleshooting:

```sh
quill models
quill doctor
quill import-muesli                 # preview
quill import-muesli --replace --write # explicit re-import with backup
```

Use `--config '/path/to/config.json'` for a custom Muesli installation. Only model
and local Ollama fields are copied; provider credentials are excluded. CLI writes
record the same provenance and accepted decision as the app. A preview does not
consume the first-run offer. Existing `transcription.enabled: false` is preserved;
use the app's **Transcribe finished recordings** toggle when ready to enable it.
Malformed Quill config is reported and left untouched, including symlinked files.

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
trigger cache repair or network downloads. The unconfigured Parakeet v2 default also requires a local cache; recording
remains available when no model is ready.

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
provider is local Ollama. Invalid or remote summary settings produce an import
warning and preserve Quill's current note settings while valid speech settings
can still be imported. An unavailable Ollama server or invalid summary config never
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
