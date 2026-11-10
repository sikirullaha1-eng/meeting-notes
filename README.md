# Meeting Notes

A Granola-style meeting notetaker for macOS. Two ways to use it:

- **Meeting Notes.app** — a real Mac app with a window. Installed in your
  Applications folder. Open it from Spotlight (⌘Space → "Meeting Notes").
- **`./meet`** — the same thing as a terminal command, if you prefer typing.

Both do exactly the same work. The app saves to **Documents → Meeting Notes**;
the terminal version saves into this folder's `notes/`.

## The app

Press **Record** (or ⌘R). Type your notes in the box while the meeting runs.
Press **Stop**. It listens back, writes up the notes, and adds the meeting to
the list down the left side. Right-click any meeting to write it up again,
show it in Finder, or delete it.

To rebuild it after changing the code:

```
cd MeetApp && ./build-app.sh
```

---

## The terminal version

It records your microphone while you type scrappy notes, transcribes the audio
on this Mac, and writes both into one markdown file.

**Nothing leaves your computer.** No API key, no internet, no subscription.
It uses the speech engine that's already built into macOS 26.

## Using it

```
cd ~/Projects/meeting-notes
./meet
```

It starts recording. Type your notes as the meeting goes — one thought per
line, however messy. When it's over, type a single dot `.` and press Enter.

It saves to `notes/2026-09-22-1628.md`. Open it with:

```
open notes/
```

## Redoing a meeting you already recorded

```
./meet redo recordings/2026-09-22-1628.caf
```

This transcribes it again and rewrites the notes, keeping the notes you typed
the first time. Useful if you change how the notes are written.

## If the microphone doesn't work

macOS asks permission the first time. If you missed the prompt:

1. System Settings → Privacy & Security → Microphone
2. Turn ON the app you run this from (Warp, or Terminal)
3. **Quit that app completely** (⌘Q) and open it again — it won't work until you do

## Changing it

The whole thing is one file: `Sources/meet.swift`, about 160 lines.
After you edit it, rebuild:

```
./build.sh
```

## What it writes

Each note has three parts:

1. **Clean notes** — what was discussed and action items with owners, written
   by Apple's on-device AI, using your typed notes as the outline
2. **What I typed** — your scrappy notes, kept as you wrote them
3. **Transcript** — the full raw text, so you can check anything

## Requirements

- macOS 26 or later (the speech and AI engines are built in)
- Apple Intelligence turned on, for the clean notes
  (System Settings -> Apple Intelligence & Siri). Without it you still get
  the transcript.

## What's not done yet

Things worth adding:
- capture the other side of a video call, not just your microphone
  (right now it only hears your microphone, so on Zoom it catches the room
  but not the people on the call)
- speaker labels ("you said" vs "they said")
- a menu bar icon instead of a terminal
