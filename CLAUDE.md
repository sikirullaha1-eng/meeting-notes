# Meeting Notes — project notes for Claude Code

A Granola-style meeting notetaker. Records the mic, transcribes on-device,
writes markdown. One Swift file, no dependencies, no network.

## Two front ends, one engine
- `MeetApp/` — the real Mac app (SwiftUI). Built by `MeetApp/build-app.sh` into
  `Meeting Notes.app`, also copied to `/Applications`.
- `Sources/meet.swift` — the original terminal version. Still works. The app
  does NOT share code with it; the logic was copied into `MeetApp/Sources/Engine.swift`.
  If you change a prompt, change it in BOTH or delete one.

## How the app is built without Xcode
Only Command Line Tools are installed — there is no `.xcodeproj`. `build-app.sh`
compiles with `swiftc -O -parse-as-library Sources/*.swift`, then hand-assembles
the bundle (`Contents/MacOS`, `Contents/Info.plist`, `Contents/Resources`) and
ad-hoc signs it with `codesign --sign -`. The Info.plist MUST carry
`NSMicrophoneUsageDescription` or the mic prompt never appears.
`AppIcon.icns` was generated from a PNG drawn in pure Python (no Pillow on
this Mac) via `sips` + `iconutil`.

## Gotcha worth knowing
The window's owner name for `CGWindowListCopyWindowInfo` is **"Meeting Notes"**
(CFBundleName), not the executable name "MeetingNotes".

## Layout
- `Sources/meet.swift` — the entire program (~340 lines)
- `build.sh` — `swiftc -O -parse-as-library Sources/meet.swift -o meet`
- `notes/` — output markdown, one file per meeting
- `recordings/` — raw `.caf` audio

## How it works
1. `AVAudioEngine` taps the input node, writes buffers to an `AVAudioFile`
2. `readLine()` on the main thread collects the user's typed notes until `.`
3. `SpeechTranscriber` + `SpeechAnalyzer` (macOS 26 Speech framework) transcribe
   the finished file. `en_US` is already installed; no model download needed.
4. `FoundationModels` (`SystemLanguageModel` / `LanguageModelSession`) — Apple's
   ON-DEVICE model — merges the typed notes with the transcript into clean
   notes. Confirmed `.available` on this Mac. No API key, no network, no cost.
5. All three are written into one markdown file

## Things that bit us already
- The source file is not named `main.swift`, so `-parse-as-library` is REQUIRED
- `SpeechTranscriber.Preset.offlineTranscription` does NOT exist on this SDK.
  Use the full init: `transcriptionOptions:reportingOptions:attributeOptions:`
- Transcribing a near-empty audio file hangs forever — there's a
  `audioFile.length > 2000` guard before transcription. Keep it.
- `setvbuf(stdout, nil, _IONBF, 0)` is needed or prompts don't appear when piped
- The `Recorder` class is `@unchecked Sendable` because the audio tap closure
  runs on the audio thread

## The user
Complete beginner — this is his first project. Explain what you're doing in
plain language, and give him one command at a time to run.

## Commands
- `./meet` — record, transcribe, write up
- `./meet redo recordings/<slug>.caf` — regenerate the note from an existing
  recording, reusing the typed notes parsed out of the old markdown. This is
  how you test prompt changes without recording again.

## Deliberately NOT using the Claude API
The user has no API key and Claude Code was not logged in. Everything runs on
the device for free. Do not introduce a paid dependency without asking him.

## Things that bit us in the summarizer
- The on-device model has a small context window. `chunk()` splits transcripts
  at ~4500 characters and a second pass folds the partials together.
- It kept appending a stray "None mentioned." AFTER listing real action items,
  and dropped markdown `##`. Fixed with a tighter prompt plus `tidy()`, which
  normalises the headings and strips the stray line. Keep `tidy()`.
- Speech recognition mishears names ("Kalen" -> "Caitlin"). That's the ASR, not
  the summarizer. Speaker labels would help.
- It HALLUCINATED money figures ("$150,000 allocated") from garbled speech and
  stated them as fact. Fixed by telling the model the transcript is often wrong,
  to leave out anything it isn't confident about, and to be especially careful
  with numbers. Verified: the invented figures disappeared, the real ones stayed.
  Do not loosen these instructions.
- The typed notes used to DOMINATE: "What was discussed" just echoed them back.
  Fixed by telling the model the notes show which topics mattered most and to
  EXPAND them from the transcript rather than repeat them, plus requiring each
  bullet to tell a reader something they didn't already know.

## The real ceiling right now
Speech recognition accuracy, not the summarizer. On a 2-minute recording with
room noise it produced "Tunde" -> "Teddy", "roadmap" -> "route matter", and
dropped an action item entirely. No prompt fixes that. What would:
- capturing system audio directly instead of through the air
- speaker labels so cross-talk is separable
- a better model (whisper.cpp) if he ever installs one

## Next up
- Capture system audio, not just the mic, so it hears the other side of a call
- Speaker labels
- A menu bar app instead of a terminal command
