// meet — a tiny Granola-style meeting notetaker for macOS.
//
// It records your microphone while you type scrappy notes, then transcribes
// the audio on-device with Apple's Speech engine and writes both into one
// markdown file.
//
// Nothing leaves your Mac. No API keys, no internet.

import Foundation
import AVFoundation
import Speech
import FoundationModels

// A tiny box so the audio file can be written from the audio thread.
final class Recorder: @unchecked Sendable {
    let file: AVAudioFile
    init(file: AVAudioFile) { self.file = file }
    func write(_ buffer: AVAudioPCMBuffer) { try? file.write(from: buffer) }
}

func timestamp(_ format: String) -> String {
    let f = DateFormatter()
    f.dateFormat = format
    return f.string(from: Date())
}

@main
struct Meet {
    /// Turn an audio file into text, entirely on this Mac.
    static func transcribe(_ url: URL) async -> String {
        do {
            let audioFile = try AVAudioFile(forReading: url)
            guard audioFile.length > 2000 else {
                return "_(The recording was too short to transcribe.)_"
            }
            let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"),
                                                transcriptionOptions: [],
                                                reportingOptions: [],
                                                attributeOptions: [])
            let analyzer = SpeechAnalyzer(modules: [transcriber])

            let collector = Task {
                var out = ""
                for try await result in transcriber.results {
                    out += String(result.text.characters)
                }
                return out
            }
            try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
            let text = try await collector.value
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "_(Nothing was heard. Check System Settings -> Sound -> Input.)_"
                : trimmed
        } catch {
            return "_(Transcription failed: \(error.localizedDescription))_"
        }
    }

    /// Tidy up the model's output: enforce markdown headings and drop a
    /// stray "None mentioned." that follows real action items.
    static func tidy(_ text: String) -> String {
        var lines = text.components(separatedBy: .newlines)
        lines = lines.map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "*", with: "")
                .trimmingCharacters(in: .whitespaces)
            if t.lowercased().hasPrefix("what was discussed") { return "## What was discussed" }
            if t.lowercased().hasPrefix("action item") { return "## Action items" }
            return line
        }
        if let idx = lines.firstIndex(of: "## Action items") {
            let after = lines[(idx + 1)...]
            let hasBullets = after.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("-") }
            if hasBullets {
                lines.removeAll { $0.trimmingCharacters(in: .whitespaces).lowercased() == "none mentioned." }
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Split a long transcript into pieces the on-device model can hold at once.
    static func chunk(_ text: String, size: Int = 4500) -> [String] {
        guard text.count > size else { return [text] }
        var chunks: [String] = []
        var current = ""
        for sentence in text.split(separator: ".", omittingEmptySubsequences: false) {
            let piece = sentence + "."
            if current.count + piece.count > size, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += piece
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Merge the notes you typed with the transcript into clean notes,
    /// using Apple's on-device model. Nothing is sent anywhere.
    static func cleanUp(transcript: String, myNotes: [String]) async -> String {
        guard case .available = SystemLanguageModel.default.availability else {
            return "_(Apple Intelligence is off, so there are no cleaned-up notes. Turn it on in System Settings -> Apple Intelligence & Siri.)_"
        }
        guard transcript.count > 80 else {
            return "_(Too short to summarise.)_"
        }

        let instructions = """
        You clean up meeting transcripts into short, plain notes.

        The transcript comes from speech recognition and is often WRONG. It
        contains misheard words, background chatter, and sometimes people or
        audio that have nothing to do with the meeting.

        Rules you must not break:
        - Use ONLY what is clearly said. Never invent names, dates, numbers or
          decisions.
        - If a sentence is garbled or you are not confident what was meant,
          LEAVE IT OUT. A short, correct note is much better than a long one
          with a guess in it.
        - Be especially careful with numbers and money. If a figure does not
          clearly belong to the discussion, do not include it at all.
        - Skip filler, side chatter, and anything that is obviously not part of
          the meeting.
        """

        let outline = myNotes.isEmpty
            ? ""
            : "\n\nWhile the meeting happened, the person took these rough notes. " +
              "They tell you which topics mattered MOST to them, so cover those " +
              "topics in more detail. Do NOT simply repeat these lines back — " +
              "expand each one using what was actually said in the transcript, " +
              "and include anything important they missed:\n" +
              myNotes.map { "- \($0)" }.joined(separator: "\n")

        let pieces = chunk(transcript)
        var partials: [String] = []

        do {
            for (i, piece) in pieces.enumerated() {
                if pieces.count > 1 { print("  summarising part \(i + 1) of \(pieces.count)…") }
                let session = LanguageModelSession(instructions: instructions)
                let r = try await session.respond(to: """
                Write notes on this part of a meeting.

                Use exactly these two markdown headings and nothing else:

                ## What was discussed
                (bullet points covering what was actually SAID — the problems
                raised, the numbers, the decisions made and why. Each bullet
                should tell someone who missed the meeting something they did
                not already know. Do not just list topic names.)

                ## Action items
                (bullet points, each saying who owns it and by when, or
                "unassigned" if nobody was named)

                Write "None mentioned." under Action items ONLY if there are no
                action items at all. If you list any action items, do not write
                "None mentioned."\(outline)

                TRANSCRIPT:
                \(piece)
                """)
                partials.append(r.content)
            }

            if partials.count == 1 { return tidy(partials[0]) }

            // More than one piece — fold them into a single set of notes.
            let session = LanguageModelSession(instructions: instructions)
            let r = try await session.respond(to: """
            These are notes from consecutive parts of one meeting. Combine them
            into a single set of notes, removing repetition. Use exactly the
            two markdown headings "## What was discussed" and "## Action items".
            Do not write "None mentioned." if any action items are listed.

            \(partials.joined(separator: "\n\n---\n\n"))
            """)
            return tidy(r.content)
        } catch {
            return "_(Couldn't summarise: \(error.localizedDescription))_"
        }
    }

    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)

        // `meet redo <file>` re-transcribes a recording you already have.
        let args = CommandLine.arguments
        if args.count > 2, args[1] == "redo" {
            let url = URL(fileURLWithPath: args[2])
            let slug = url.deletingPathExtension().lastPathComponent
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let noteURL = cwd.appendingPathComponent("notes/\(slug).md")

            // Reuse the notes you typed the first time, if we still have them.
            var typed: [String] = []
            if let old = try? String(contentsOf: noteURL, encoding: .utf8),
               let start = old.range(of: "## What I typed") {
                let rest = old[start.upperBound...]
                let section = rest.components(separatedBy: "## Transcript").first ?? ""
                typed = section.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.hasPrefix("- ") }
                    .map { String($0.dropFirst(2)) }
            }

            print("Transcribing \(url.lastPathComponent)…")
            let transcript = await transcribe(url)
            print("Writing up the notes…")
            let cleaned = await cleanUp(transcript: transcript, myNotes: typed)

            let typedBlock = typed.isEmpty
                ? "_(You didn't type any notes this time.)_"
                : typed.map { "- \($0)" }.joined(separator: "\n")
            let markdown = """
            # Meeting — \(slug)

            Audio: `recordings/\(slug).caf`

            \(cleaned)

            ---

            ## What I typed

            \(typedBlock)

            ## Transcript

            \(transcript)
            """
            try? markdown.write(to: noteURL, atomically: true, encoding: .utf8)
            print("\n✓ Rewrote notes/\(slug).md\n")
            print(cleaned)
            return
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let recordingsDir = cwd.appendingPathComponent("recordings")
        let notesDir = cwd.appendingPathComponent("notes")
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)

        let slug = timestamp("yyyy-MM-dd-HHmm")
        let audioURL = recordingsDir.appendingPathComponent("\(slug).caf")

        // ---------- 1. start the microphone ----------
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        let recorder: Recorder
        do {
            recorder = Recorder(file: try AVAudioFile(forWriting: audioURL, settings: format.settings))
        } catch {
            print("Couldn't create the recording file: \(error.localizedDescription)")
            return
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            recorder.write(buffer)
        }

        do {
            try engine.start()
        } catch {
            print("""

            Couldn't start the microphone.

            Give your terminal permission:
              System Settings  ->  Privacy & Security  ->  Microphone
              turn ON the app you're running this from (Warp or Terminal)

            Then quit that app completely and open it again.

            (\(error.localizedDescription))
            """)
            return
        }

        let started = Date()
        print("""

        ● Recording.  \(timestamp("h:mm a"))

          Type your notes below — one thought per line, however scrappy.
          When the meeting is over, type a single dot  .  and press Enter.

        """)

        // ---------- 2. collect the notes you type ----------
        var myNotes: [String] = []
        while let line = readLine() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "." { break }
            if !trimmed.isEmpty { myNotes.append(trimmed) }
        }

        engine.stop()
        input.removeTap(onBus: 0)

        let minutes = Int(Date().timeIntervalSince(started)) / 60
        let seconds = Int(Date().timeIntervalSince(started)) % 60
        print("\n■ Stopped after \(minutes)m \(seconds)s. Transcribing — this takes a few seconds…")

        // ---------- 3. transcribe it, on this Mac ----------
        let transcript = await transcribe(audioURL)

        print("Writing up the notes…")
        let cleaned = await cleanUp(transcript: transcript, myNotes: myNotes)

        // ---------- 4. write it all down ----------
        let notesBlock = myNotes.isEmpty
            ? "_(You didn't type any notes this time.)_"
            : myNotes.map { "- \($0)" }.joined(separator: "\n")

        let markdown = """
        # Meeting — \(timestamp("EEEE d MMMM yyyy, h:mm a"))

        Length: \(minutes)m \(seconds)s
        Audio: `recordings/\(slug).caf`

        \(cleaned)

        ---

        ## What I typed

        \(notesBlock)

        ## Transcript

        \(transcript)
        """

        let outURL = notesDir.appendingPathComponent("\(slug).md")
        do {
            try markdown.write(to: outURL, atomically: true, encoding: .utf8)
            print("""

            ✓ Saved to  notes/\(slug).md

              Open it with:   open notes/\(slug).md

            """)
        } catch {
            print("Couldn't save the notes: \(error.localizedDescription)")
            print(markdown)
        }
    }
}
