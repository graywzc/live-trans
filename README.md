# LiveTrans

![CI](https://github.com/graywzc/live-trans/actions/workflows/ci.yml/badge.svg)
![Release](https://img.shields.io/github/v/release/graywzc/live-trans)

Live Japanese captions for whatever your Mac is playing: each line appears with
furigana above the kanji and an English translation below it.

The Mac only captures audio and draws captions. Transcription (Whisper
`large-v3`) and translation (an LLM served by ollama) run on **your own GPU
machine**, reached over ssh. Nothing is sent to a third-party service, except
the words you choose to look up on [Jisho](https://jisho.org). A sentence can
also be [taken apart word by word](#sentence-analysis) by an LLM of your own.

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

The speaker menu at the top of the window shows what you are listening on,
read through any Multi-Output Device, and lists the other outputs. Choosing
one there is the same as choosing it in System Settings, so when the Mac is
left on the wrong output (the speakers after a session, say, when you want
the dock) there is no need to leave the app. Each entry says which
Multi-Output Device will carry the captions for it, or that none does.
Paired AirPods and other Bluetooth headphones are listed even when they are
not connected; choosing them connects them first, which asks for Bluetooth
access once, and they need to be out of their case for it to work.

## GPU host setup

On the GPU machine, once:

```
mkdir -p ~/livetrans && cd ~/livetrans
curl -LO https://raw.githubusercontent.com/graywzc/live-trans/main/server/asr_server.py
python3 -m venv ~/venvs/livetrans
~/venvs/livetrans/bin/pip install faster-whisper ctranslate2 numpy
ollama pull qwen3.5:9b
```

To caption videos ahead from their own audio, the host also needs `ffmpeg`,
and `yt-dlp` with a JavaScript runtime for sites like YouTube:

```
pip install -U yt-dlp
curl -fsSL https://deno.land/install.sh | sh -s -- --no-modify-path
```

Then in LiveTrans, open Settings (⌘,) and set **SSH host** to whatever you type
after `ssh` to reach that machine. An alias from `~/.ssh/config` is fine.
`ssh <host> true` must succeed without prompting.

That is all: the app starts the server when you press Start and shuts it down
when you stop or quit, so the GPU is only held while you are captioning.

- **Clean stop or quit** - the app calls `/shutdown` and the GPU is free in
  about a second. The circular arrow in the header does the same and opens
  the app again: a fresh start with nothing kept, for when a page's stream
  link has gone stale or the window has got into a state.
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

### Sentence analysis

Point at a caption and a button appears at its end. It has an LLM explain the
sentence in the same panel as Jisho (the switch at the top of the panel flips
between the two): the sentence with its readings, a Chinese translation, then a
table with a row per word giving its dictionary form, how that became the form
in the sentence (食べる → 可能形 → 否定 → 过去), and what it means here. Rows
appear as the model writes them.

Anything in the panel can be selected: the sentence, the translation, a cell of
the table, part of an answer. The **Jisho** button over the selection works
here too, but the entry comes from the LLM instead of jisho.org and is added
under the table: set out like a Jisho entry, in Chinese, with the word's
dictionary form and reading, its meanings with an example each (本句 marks the
one it has in this sentence), and the grammar in what was selected, such as the
steps of a conjugation. It also explains what Jisho can't, like a grammar term
in an answer, and an entry's own text can be looked up in turn. It is as
reliable as the model is; jisho.org is a selection in a caption away.

To ask more about the sentence (why は and not が, what else a word can mean,
how to say it more politely), type in the field at the bottom of the panel and
press Return. The answers collect under the table, and each question is sent
along with the analysis on screen and the earlier questions about this
sentence, so it can refer back to them.

Under **Sentence analysis** in Settings, enter an OpenAI-compatible server
(vLLM, llama.cpp's `llama-server`, or ollama) and a model:

```
LLM server   http://gpu-host:8000/v1
Model        qwen3.8-27b
```

This is separate from the GPU server above, so it works on captions that are
already on screen after you press Stop, and it can be a bigger model on another
machine than the one that translates the captions.

Nothing about an analysis is remembered. The app calls the inference server
directly and each request holds the instructions and that one sentence, never
an earlier sentence or answer. A follow-up question is the one exception to
"or answer": the server keeps no conversation, so the app sends what the panel
shows about the current sentence with it. A lookup sends the selected text and
the sentence. The analysis with its questions and entries exists only in the
panel until the next sentence replaces it: nothing is cached or written to disk. Give the address of the inference server itself; an
agent or a memory layer in front of it would see the traffic. Whether the
server logs its requests (vLLM's `--enable-log-requests`) is up to its own
configuration.

When the sound is a video playing in Chrome, each caption notes where in the
video its sentence was said, and shows when it starts and ends. Click a caption to
play its
sentence again from there; the video pauses when the sentence ends. What is
When the video is one whose audio the GPU host can fetch (a plain file, an
HLS or DASH stream, or a page yt-dlp knows), LiveTrans can caption it **ahead
of you** from that audio instead of listening. It starts paused: while
captioning, press **Caption ahead** under the captions to begin, and **Pause**
to hold it (the host stops transcribing, the captions already fetched stay,
and taking it up again goes on from there). Running, the host fetches the audio
from where you are in the video, not from its start, cuts
it at silences into chunks of about a minute, and transcribes and translates
each, so the captions are in place before the video gets there, with exact
times. The whole script is listed as it arrives, the line being spoken is
lit and kept in view. Between sentences an orange line, with the video's time
at its right end, sits after the last one spoken. Pause, seek and replay as you like; the fetch never touches the
player.

A sentence can go uncaptioned: the model drops one now and then, and the
live listener stands down over a fetched stretch, so playing through the
gap does not catch it. Where the gap between two captions is two seconds
or more, resting the pointer in it shows a grey line with an ear button at
its right end; the orange line has the same button while the video is in
such a gap. Press it and the gap is heard again from the fetched audio,
with the wider search and the captions before it as context, and anything
found lands where it was said. Only the speech in the gap is decoded, so a
gap of music or silence gives nothing rather than invented lines; of a
long gap, at most twenty seconds are heard at once, from the sentence
before it or around where the video is. When you jump to a part it has not captioned and is not about to
reach, it starts again from there, keeping the captions it has; a part you
skipped over is captioned when you go back to it, and a stretch already
captioned is passed over rather than done twice.

A bar above the level meter shows where you are in the Chrome video, between
the time and the video's length. Drag the orange dot, or press anywhere on
the bar, to move the video; it moves when you let go. Rest the pointer on
the bar and the time under it floats above, so a press lands where you
meant it to. The bar is there
whenever LiveTrans knows of a video in Chrome, captioning ahead or not. On
it are the stretches captioned ahead (green, yellow while paused) and the
audio fetched for the next (grey). Encrypted streams (most subscription services) cannot be fetched and
stay on live captioning, as does any page the host cannot resolve. The live
listener stands down over the stretch that has been fetched and picks up
again past it. **Offer captioning a Chrome video ahead from its own audio**
in Settings hides the button altogether. For YouTube the host needs a JavaScript runtime for
yt-dlp (`deno`), and without a YouTube token the fetch runs at playback pace,
so captions catch up rather than run ahead until you pause or go back.

Anything heard from a stretch of the video that already has captions, whether
a replayed sentence, the video played on from there with Space, or a skip
back, is transcribed again taking its time over it (a wider search, with the
captions before it as context) and corrects those captions rather than
repeating them. So when a line looks wrong, click it: it is heard once more,
and corrected if the model does better the second time. A caption that ran two sentences
together is split where the speaker paused between them when it is heard
again from the fetched audio, each part with its own time and translation. Something heard that
is not the sentence again (only the context, or a line with nothing of the
original in it, as the model produces over music or silence) leaves the
caption as it was. Sentence times come from where Whisper heard the words,
so this needs a current `asr_server.py` on the GPU host; an older one still
works, with the sentences placed by their share of the text instead.

Settings also has furigana on/off, text size, and **Keep window on top** for
floating the captions over a video. Nothing of a session outlives the app: the
captions, analyses and lookups exist only in memory, network responses and the
Jisho panel's pages are never cached on disk, and the app empties its cache
and cookie folders at launch and at quit. On the GPU host the fetched audio
lives in the server's memory, the log names no video and quotes nothing heard,
and it is emptied when the server shuts down (a crash leaves it for a look).

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

The window opens with the captions and the side panel side by side;
`-sidePanel jisho`, `-sidePanel analysis` or `-sidePanel closed` picks what
the panel shows at launch, or starts with the captions alone.

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
