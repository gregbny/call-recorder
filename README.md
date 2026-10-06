# Call Recorder

Records your calls (microphone + audio from Teams, Zoom…) and transcribes them
**100% locally** on your Mac — nothing is sent to the internet.
Output: a timestamped markdown transcript in `~/Recordings`, with speakers told apart
(`Me`, `Interlocutor 1`, `Interlocutor 2`…).

Two ways to use it:
- **Menu bar app** (recommended): an icon in the top-right corner with a Start / Stop button.
- **Command line**: `call-recorder --name "my-call"`.

> Transcription works in any language supported by Apple's speech recognition
> (French, English, Spanish, German, Italian, Portuguese, Dutch… — `fr-FR` by default).

> [!WARNING]
> **Disclaimer — always inform participants and get their consent before recording.**
> Recording a conversation without the other participants' knowledge and consent is illegal
> in many countries (including France) and may breach your employer's policies.
> Announce the recording at the start of every call and stop if anyone objects.
> You are solely responsible for how you use this tool and for complying with the laws
> and rules that apply to you. The software is provided "as is", without warranty
> (see [LICENSE](LICENSE)).

---

## Installation (~5 minutes)

> **Why build it yourself?** The app isn't signed with an Apple Developer account.
> An app compiled on another Mac would be blocked by Gatekeeper and the permissions
> (microphone, screen recording) wouldn't work reliably. Compiled and signed locally
> on **your** Mac, everything works out of the box.

### 1. Requirements

| | |
|---|---|
| macOS | **26 (Tahoe) or later** — Apple menu  > About This Mac |
| Mac | Apple Silicon (M1 or later) |
| Tools | Apple Command Line Tools (free, installer offered automatically if missing). Xcode is **not** required. |

### 2. Install

In the **Terminal** app:

```bash
git clone https://github.com/gregbny/call-recorder.git
cd call-recorder
bash install.sh
```

> No `git`? On the GitHub page, **Code > Download ZIP**, unzip it, then in Terminal type `cd `
> (with a trailing space), drag the folder into the window, press Enter, and run `bash install.sh`.

The script takes care of everything:
- checks macOS, Swift and the Command Line Tools (offers to install them if needed — run `bash install.sh` again once done);
- compiles the app and signs it locally;
- installs **Call Recorder.app** in `/Applications` and the `call-recorder` command in `~/.local/bin`;
- downloads the speaker diarization models (~13 MB);
- launches the app.

### 3. Grant permissions (first recording)

macOS asks for three permissions — accept them all:

1. **Microphone** — for your voice
2. **Screen & System Audio Recording** — to capture the call app's audio (nothing is filmed)
3. **Speech Recognition** — for transcription

If a prompt doesn't show up: **System Settings > Privacy & Security**, enable
*Call Recorder* in the relevant section, then quit and relaunch the app.

The first transcription in a given language may take a bit longer: macOS downloads the
matching speech model once.

### Launch at login (optional)

System Settings > General > **Login Items** > "+" > *Call Recorder*.

### Update

`git pull` in the folder, then run `bash install.sh` again.
If macOS asks for permissions again afterwards, that's expected (new signature).

### Uninstall

```bash
rm -rf "/Applications/Call Recorder.app" ~/.local/bin/call-recorder ~/.call-recorder
tccutil reset All local.call-recorder.menubar
```

Your transcripts in `~/Recordings` are kept.

### Troubleshooting

| Problem | Fix |
|---|---|
| `xcode-select: error` / `swift: command not found` | Run `xcode-select --install`, finish the installation, run `bash install.sh` again. |
| "Swift 6.2+ required" | System Settings > Software Update (updates the Command Line Tools). |
| The other party is missing from the transcript | Check the *Screen & System Audio Recording* permission, then relaunch the app. |
| Permissions don't "stick" | `tccutil reset All local.call-recorder.menubar`, relaunch the app and accept again. |
| "Models missing" in the app | `bash scripts/download-models.sh` |

---

## Command line usage

```bash
call-recorder [options]
```

| Flag | Description | Default |
|---|---|---|
| `--name <str>` | Call name (markdown title + file name) | `"call"` |
| `--output-dir <path>` | Folder for the final `.md` files | `~/Recordings` |
| `--temp-dir <path>` | Folder for temporary `.m4a` files | `~/Recordings/.tmp` |
| `--lang <locale>` | Transcription language | `fr-FR` |
| `--app <name>` | App whose audio is captured | `"Microsoft Teams"` |
| `--keep-audio` | Keep the `.m4a` files after transcription | `false` |
| `--diarize` | Tell remote speakers apart | `false` |
| `--models-dir <path>` | Diarization models folder | `~/.call-recorder/models/speaker-diarization-coreml` |
| `--process <mic> <sys>` | Transcribe two existing `.m4a` files (interrupted session) without recording; audio is kept | — |
| `--help`, `-h` | Help | |
| `--version` | Version | |

### Examples

```bash
call-recorder
call-recorder --name "weekly-sync" --output-dir ~/Documents/Meetings
call-recorder --name "client-demo" --lang en-US --keep-audio
call-recorder --app "zoom.us" --name "interview" --diarize
```

Ctrl+C stops cleanly → transcription → markdown → cleanup (unless `--keep-audio`).

### macOS Shortcut

In the Shortcuts app, create a shortcut with a **Run Shell Script** action:

```bash
~/.local/bin/call-recorder --name "call-$(date +%H%M)"
```

Assign it a global keyboard shortcut to start/stop quickly.

## Speaker diarization

By default the whole system track is labelled `Interlocutor`. With diarization enabled
(`--diarize`, or the "Identify speakers" toggle in the app), remote speakers are
told apart (`Interlocutor 1`, `Interlocutor 2`, …) using
[FluidAudio](https://github.com/FluidInference/FluidAudio) — CoreML models, inference 100% local
on the Apple Neural Engine.

The models (~13 MB) are downloaded once by `install.sh` (or `bash scripts/download-models.sh`).
After that, no network connection is ever made at runtime. If only one speaker is detected,
labels stay generic.

## Sample output

```markdown
# Call: weekly-sync — 2026-04-12 14:32

**Duration**: 23 min 14 s

## Transcript

**[00:00:03] Interlocutor 1**: Hi, can you hear me okay?

**[00:00:05] Me**: Yes, perfectly. Let's get started.

**[00:00:09] Interlocutor 2**: Great, let's start with the sprint review.
```

## Architecture

- `Sources/CallRecorderKit/` — shared library:
  - `Recorder.swift` — microphone (AVAudioEngine) + system audio (ScreenCaptureKit) capture
  - `Transcriber.swift` / `LiveTranscriber.swift` — transcription with SpeechAnalyzer
  - `Diarizer.swift` — speaker diarization (FluidAudio, local CoreML)
  - `Assembler.swift` — chronological merge and markdown generation
- `Sources/call-recorder/main.swift` — CLI: argument parsing, orchestration, SIGINT handling
- `Sources/CallRecorderMenuBar/` — menu bar app
- `Info.plist` / `MenuBarInfo.plist` — permission keys embedded with `-sectcreate`
- `install.sh`, `scripts/` — build, app bundle, model download

Apple frameworks + FluidAudio only. No network calls at runtime; only
`scripts/download-models.sh` (once) and Swift package resolution touch the network.

## Credits

- Transcription: Apple [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer).
- Diarization: [FluidAudio](https://github.com/FluidInference/FluidAudio) by FluidInference (Apache 2.0),
  with the [speaker-diarization-coreml](https://huggingface.co/FluidInference/speaker-diarization-coreml)
  CoreML models, converted from [pyannote.audio](https://github.com/pyannote/pyannote-audio) (segmentation)
  and [WeSpeaker](https://github.com/wenet-e2e/wespeaker) (speaker embeddings). The models are not
  included in this repository: they are downloaded from Hugging Face and remain under their own licenses.
- SpeechAnalyzer usage inspired by [finnvoor/yap](https://github.com/finnvoor/yap).

## License

[MIT](LICENSE)
