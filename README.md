<p align="center">
  <img src="brand/assets/banner.png" alt="Capipaste — screenshot, talk, paste" width="100%">
</p>

<p align="center">
  <b>Press ⌘⇧S, drag over the problem, say what should change, press ↩.</b><br>
  The marked-up screenshot and your note land on the clipboard, ready for Claude Code, Codex or any chat.
</p>

<p align="center">
  <img src="brand/assets/steps.png" alt="1 ⌘⇧S drag to capture · 2 talk or type the change · 3 ↩ image + note copied" width="100%">
</p>

## What it does

Capipaste is a small macOS menu-bar app for giving visual feedback to coding agents.

- **Setup** — the menu bar walks you through the permissions macOS needs (Screen Recording, Microphone, plus Accessibility for dictation) and hides itself once they're granted.
- **Settings** — a window (⌘, from the menu, and on first launch) for shortcuts, hold-to-talk key, microphone, models, permissions and updates.
- **Dictate** — hold **right ⌘**, say it, let go. A bar shows the words as they land; the text goes on the clipboard and pastes into whatever you were typing in. No screenshot involved. (Hold-to-talk and auto-paste need Accessibility.)
- **Capture** — ⌘⇧S opens the native macOS region picker (Space switches to window capture, Esc cancels).
- **Talk** — a card pops up with the screenshot and starts listening. Speech is transcribed **on your Mac**; nothing is uploaded.
- **Mark it up** — draw on the screenshot, erase just the part under the eraser, undo per stroke. Pinch or ⌘+ / ⌘− to zoom, two-finger scroll to pan.
- **Never lose a take** — if the transcript fails or comes back empty while you were talking, it retries once, then keeps the card open and asks you to say it again. Typing takes over from dictation so speech never overwrites your edits.
- **Paste** — ↩ copies the annotated PNG and your note, hands focus back to the app you captured from, and closes. The PNG is also saved to `~/Pictures/Capipaste`, and the note ends with its path:

  ```
  Make the header sticky and give the Upgrade button more room.

  [screenshot: /Users/you/Pictures/Capipaste/Capipaste 2026-09-17 at 01.14.53.png]
  ```

<p align="center">
  <img src="docs/card.png" alt="The Capipaste card: screenshot with drawing tools, live waveform, transcript and keyboard hints" width="720">
</p>

### Where the paste goes

| You pressed ⌘⇧S from… | Clipboard gets | Why |
|---|---|---|
| A terminal (cmux, Ghostty, Terminal, iTerm2, Warp, WezTerm, kitty, Alacritty) | Note + image path only | Claude Code attaches a clipboard image and drops the text; the path lets it open the image instead. |
| Anything else (Codex, chat apps, docs) | PNG **and** note | Each app takes what it supports. |

After ↩ Capipaste hands focus back to the app you started from, so ⌘V lands there.

If transcription fails or comes back empty while you were talking, Capipaste retries once. If that fails too, the card stays open and asks you to say it one more time.

### Updates

Capipaste checks GitHub releases and can install them itself if you turn that on in Settings (an automatic install only accepts a build signed with the same identity). Cut one with:

```sh
scripts/release.sh 0.2.0 "What changed"
```

### Website

The landing page and FAQ live in their own repo: [Chordlini/capipaste-site](https://github.com/Chordlini/capipaste-site). `brand/make.sh` refreshes its copies of the artwork when they sit side by side.

## Speech models

Pick a model and microphone from the menu bar. Models download on demand (via [FluidAudio](https://github.com/FluidInference/FluidAudio), CoreML on the Neural Engine) and can be deleted from the same menu.

| Model | Released | Best for |
|---|---|---|
| **Nemotron 3.5 Streaming** (default) | Jun 2026 | Live text while you talk |
| Parakeet TDT-CTC 110M | Mar 2026 | Fastest, English only (~450 MB) |
| Cohere Transcribe | Mar 2026 | Most accurate, slower (1.8 GB) |
| Apple Speech | built in | No download; used until another model is on disk |

## Keyboard

| Key | Action |
|---|---|
| ⌘⇧S | Capture |
| hold right ⌘ | Dictate (configurable) |
| ↩ | Stop, transcribe, copy, close |
| ⇧↩ | New line in the note |
| Esc | Cancel |
| D / E | Draw / erase |
| ⌘Z | Undo |
| ⌘+ / ⌘− / ⌘0 | Zoom in / out / reset |

Typing in the note stops listening, so dictation never overwrites your edits.

## Install

Requirements: Apple Silicon Mac, macOS 26, Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
git clone https://github.com/Chordlini/capipaste.git
cd capipaste
./scripts/install.sh      # builds Release and installs /Applications/Capipaste.app
```

`project.yml` signs with an Apple Development identity so macOS keeps the Microphone and Screen Recording permissions across rebuilds — change `DEVELOPMENT_TEAM` to your own team ID.

On first use macOS asks for **Microphone** and **Screen Recording** access (System Settings › Privacy & Security).

## Project layout

```
Capipaste/
  App.swift          menu-bar app, ⌘⇧S hotkey, capture, terminal detection
  CaptureCard.swift  floating panel + card model (recording, drawing, zoom, submit)
  CardView.swift     the card UI
  Waveform.swift     dot-matrix level meter
  Recorder.swift     microphone list (Core Audio) and 16 kHz capture
  STT.swift          model catalog, downloads, transcription with retry
  Output.swift       flattens strokes onto the PNG, saves, writes the clipboard
brand/
  BRAND.md           brand bible: palette, type, the dither engine, motion
  make-art.swift     the engine (icon, mark, dot map, loops, banners, steps)
  assets/            generated brand assets
design/
  mockup.html        app UI reference
scripts/install.sh
```

### Test hooks

For checking the app without clicking through it (results go to `~/Library/Logs/Capipaste.log`):

```sh
open -n /Applications/Capipaste.app --args -autocapture 200,150,1000,600 -autosubmit   # capture a fixed rect, draw, erase, zoom, submit
open -n /Applications/Capipaste.app --args -demo design/sample-shot.png -snapshot /tmp/card.png
open -n /Applications/Capipaste.app --args -sttfile speech.aiff                         # transcribe a file with the active model
open -n /Applications/Capipaste.app --args -setupdemo -menushot /tmp/menu.png            # render the menu, with the setup steps unmet
```

### Brand and artwork

Every mark, banner and animation comes from one Swift script; the palette, type, motion and usage rules live in [`brand/BRAND.md`](brand/BRAND.md).

```sh
brand/make.sh    # rebuilds all brand assets, the app icon and the site copies
```

## License

MIT. Speech runs on [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0); global hotkey by [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) (MIT).
