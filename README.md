# LiveTrans

![CI](https://github.com/graywzc/live-trans/actions/workflows/ci.yml/badge.svg)
![Release](https://img.shields.io/github/v/release/graywzc/live-trans)

Live Japanese captions for whatever your Mac is playing: each line appears with
furigana above the kanji and an English translation below it.

The Mac only captures audio and draws captions. Transcription (Whisper
`large-v3`) and translation (an LLM served by ollama) run on **your own GPU
machine**, reached over ssh. Nothing is sent to a third-party service, except
the words you choose to look up on [Jisho](https://jisho.org).

```
 Mac                                         GPU host (Linux + CUDA)
 BlackHole -> voice detection -> utterance ---- HTTP ----> asr_server.py
 captions  <- furigana        <- ja + en   <--------------  Whisper large-v3 + ollama
```

## Requirements

- macOS 14 or later.
- [BlackHole](https://existential.audio/blackhole/) to capture system audio
  (a microphone works too).
- A machine with an NVIDIA GPU that you can `ssh` into without a password
  prompt (key-based auth), reachable from the Mac over the network.
  [Tailscale](https://tailscale.com) works well. See [GPU host setup](#gpu-host-setup).

## Install

```
brew install graywzc/tap/livetrans
```

Homebrew re-signs the app locally during install, which clears the "damaged
app" error macOS shows for apps that aren't notarized. Because of that, macOS
asks for microphone access again after each upgrade.

<details>
<summary>Manual install</summary>

Download `LiveTrans.zip` from the
[Releases](https://github.com/graywzc/live-trans/releases) page, move
`LiveTrans.app` to `/Applications`, then:

```
xattr -cr /Applications/LiveTrans.app
codesign --force --deep --sign - /Applications/LiveTrans.app
```
</details>

## Audio setup

To caption what the Mac is playing while still hearing it:

1. In **Audio MIDI Setup**, create a Multi-Output Device containing both
   BlackHole 2ch and your speakers or headphones.
2. Set the Mac's sound **output** to that Multi-Output Device.
3. LiveTrans reads from BlackHole by default. Pick a different input in
   Settings (⌘,) to caption a microphone instead.

Step 2 is automatic: while captioning, LiveTrans moves the sound output to the
Multi-Output Device that contains both BlackHole and whatever you are
currently listening on, and moves it back when you stop. With one Multi-Output
Device per pair of headphones, the right one is picked by which is connected.
The Mac's sound *input* setting does not matter. Turn this off in Settings if
you would rather switch by hand.

## GPU host setup

On the GPU machine, once:

```
mkdir -p ~/livetrans && cd ~/livetrans
curl -LO https://raw.githubusercontent.com/graywzc/live-trans/main/server/asr_server.py
python3 -m venv ~/venvs/livetrans
~/venvs/livetrans/bin/pip install faster-whisper ctranslate2 numpy
ollama pull qwen3.5:9b
```

Then in LiveTrans, open Settings (⌘,) and set **SSH host** to whatever you type
after `ssh` to reach that machine. An alias from `~/.ssh/config` is fine.
`ssh <host> true` must succeed without prompting.

That is all: the app starts the server when you press Start and shuts it down
when you stop or quit, so the GPU is only held while you are captioning.

- **Clean stop or quit** - the app calls `/shutdown` and the GPU is free in
  about a second.
- **Crash, force-quit or a closed lid** - the app's heartbeat stops and the
  server exits on its own idle timeout (3 minutes).
- **Network blip** - nothing dies. The app retries the utterance and, if the
  server is really gone, restarts it over ssh in the background. The status dot
  turns orange meanwhile.

Whichever way the server exits, it also tells ollama to unload the translation
model, so the LLM's VRAM is freed along with Whisper's instead of lingering for
the keep-alive window. Anything else using that model in ollama simply reloads
it on its next request.

If a server is already running on the port, the app uses it and leaves it
running.

The host's address for HTTP is found by running `tailscale ip -4` on it over
ssh, falling back to the ssh host name itself, so without Tailscale the SSH
host must also be a name the Mac can resolve.

The defaults expect the server in `~/livetrans` and the venv in
`~/venvs/livetrans`; both paths and the port (8770) can be changed in Settings.
The port only needs to be reachable from the Mac, not from the internet.

### Server environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `LIVETRANS_ASR_MODEL` | `large-v3` | Whisper model. |
| `LIVETRANS_DEVICE` | `cuda` | Inference device. |
| `LIVETRANS_COMPUTE_TYPE` | `float16` | Whisper compute type. |
| `LIVETRANS_TRANSLATE_BACKEND` | `ollama` | `ollama` (LLM; falls back to `whisper` when ollama is unreachable), `whisper` (a second Whisper pass with `task=translate`) or `nllb`. |
| `LIVETRANS_OLLAMA_URL` | `http://localhost:11434` | ollama server. |
| `LIVETRANS_OLLAMA_MODEL` | `qwen3.5:9b` | Model used to split sentences and translate. |
| `LIVETRANS_OLLAMA_KEEP_ALIVE` | `30m` | How long ollama keeps the model loaded between requests while the server is running; it is unloaded when the server exits. |
| `LIVETRANS_OLLAMA_TIMEOUT` | `30` | Seconds before a translation falls back to the Whisper pass. |
| `LIVETRANS_NLLB_MODEL` | `models/nllb-200-distilled-600M-ct2` | Converted NLLB directory (`nllb` only; also needs `transformers` and `sentencepiece`). |

An LLM is the default because it is the only backend here that translates
colloquial speech well, and it splits a run-on transcript into sentences in the
same pass.

## Using it

Press **Start** (⌘↩). The status dot goes yellow while the server starts
(a few seconds once the model weights are cached), then green with the models
in use.

While someone speaks, a grey preview of the Japanese appears; when they pause,
it is replaced by the final line with furigana and its translation. The level
meter shows the input level, and the orange mark on it is the current speech
threshold. If quiet speech is missed, or background noise triggers captions,
adjust **Sensitivity** in Settings.

To look a word up, select it in the Japanese line: drag across the characters,
double-click a word, or triple-click the whole line. A **Jisho** button appears
over the selection and opens [jisho.org](https://jisho.org) on that text in a
panel on the right of the window, while the captions carry on beside it. Drag
the divider to resize the panel; ✕ or Esc closes it. Jisho copes with
conjugated forms and short phrases, so the selection doesn't have to be a
dictionary form. The button next to the Jisho one copies the selection.

Settings also has furigana on/off, text size, and **Keep window on top** for
floating the captions over a video. The share button exports the session as
text; nothing is saved otherwise.

## Development

```
brew install xcodegen
xcodegen generate        # the .xcodeproj is generated, not checked in
open LiveTrans.xcodeproj
```

`project.yml` carries the author's `DEVELOPMENT_TEAM`; change it to yours, or
build without a certificate:

```
xcodebuild -project LiveTrans.xcodeproj -scheme LiveTrans build \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

New files under `Sources/` are picked up by re-running `xcodegen generate`.

Any setting can be overridden for one run from the command line, and a debug
build can caption an audio file instead of an input device, which exercises
the whole pipeline without BlackHole or a video playing:

```
say -v Kyoko -o clip.aiff "こんにちは、今日は天気がいいですね。"
afconvert -f WAVE -d LEI16@16000 -c 1 clip.aiff clip.wav
LiveTrans.app/Contents/MacOS/LiveTrans -demoAudioPath "$PWD/clip.wav" -autoStart YES
```

Captions are echoed to stdout. Unit tests:

```
xcodebuild test -project LiveTrans.xcodeproj -scheme LiveTrans -destination platform=macOS
```

### Release

Releases are tag-driven. Pushing a `v*` tag builds `LiveTrans.zip`, publishes
it as a GitHub release, then opens a matching cask PR in
`graywzc/homebrew-tap`.

```
git switch main && git pull
git tag v0.1.0
git push origin v0.1.0
```

## License

MIT
