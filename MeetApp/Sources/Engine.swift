// Engine.swift — the parts that do actual work: record, transcribe, write up.
// No user interface in here at all.

import Foundation
import AVFoundation
import Speech
import FoundationModels

/// Where finished meetings live: ~/Documents/Meeting Notes
enum Library {
    static var root: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Meeting Notes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var recordings: URL {
        let dir = root.appendingPathComponent("Recordings")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// A meeting that has been saved to disk.
struct Meeting: Identifiable, Hashable {
    let id: String              // the slug, e.g. 2026-09-22-1650
    let url: URL
    let date: Date
    var title: String

    static func load() -> [Meeting] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Library.root, includingPropertiesForKeys: nil)) ?? []
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return files
            .filter { $0.pathExtension == "md" }
            .compactMap { url -> Meeting? in
                let slug = url.deletingPathExtension().lastPathComponent
                guard let date = f.date(from: slug) else { return nil }
                let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let first = body.components(separatedBy: .newlines)
                    .first { $0.hasPrefix("# ") }
                let title = first.map { String($0.dropFirst(2)) } ?? slug
                return Meeting(id: slug, url: url, date: date, title: title)
            }
            .sorted { $0.date > $1.date }
    }

    var body: String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
}

/// Wraps the audio file so the audio thread can write to it safely.
private final class Sink: @unchecked Sendable {
    let file: AVAudioFile
    init(_ f: AVAudioFile) { file = f }
    func write(_ b: AVAudioPCMBuffer) { try? file.write(from: b) }
}

/// Records the microphone to a file.
final class Microphone {
    private let engine = AVAudioEngine()
    private var sink: Sink?
    private(set) var fileURL: URL?

    enum Failure: LocalizedError {
        case noPermission(String)
        var errorDescription: String? {
            switch self {
            case .noPermission(let d): return d
            }
        }
    }

    func start(slug: String) throws {
        let url = Library.recordings.appendingPathComponent("\(slug).caf")
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let sink = Sink(file)
        self.sink = sink
        self.fileURL = url

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            sink.write(buffer)
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw Failure.noPermission(
                "Couldn't start the microphone. Open System Settings → Privacy & Security → Microphone and turn on Meeting Notes, then open the app again.")
        }
    }

    func stop() {
        guard engine.isRunning else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        sink = nil
    }
}

enum Transcriber {
    static func run(_ url: URL) async -> String {
        do {
            let audio = try AVAudioFile(forReading: url)
            guard audio.length > 2000 else { return "_(Too short to transcribe.)_" }
            let t = SpeechTranscriber(locale: Locale(identifier: "en-US"),
                                      transcriptionOptions: [],
                                      reportingOptions: [],
                                      attributeOptions: [])
            let analyzer = SpeechAnalyzer(modules: [t])
            let collector = Task {
                var out = ""
                for try await r in t.results { out += String(r.text.characters) }
                return out
            }
            try await analyzer.start(inputAudioFile: audio, finishAfterFile: true)
            let text = try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "_(Nothing was heard.)_" : text
        } catch {
            return "_(Transcription failed: \(error.localizedDescription))_"
        }
    }
}

enum Summarizer {
    static let instructions = """
    You clean up meeting transcripts into short, plain notes.

    The transcript comes from speech recognition and is often WRONG. It
    contains misheard words, background chatter, and sometimes audio that has
    nothing to do with the meeting.

    Rules you must not break:
    - Use ONLY what is clearly said. Never invent names, dates, numbers or
      decisions.
    - If a sentence is garbled or you are not confident what was meant, LEAVE
      IT OUT. A short, correct note is much better than one with a guess in it.
    - Be especially careful with numbers and money. If a figure does not
      clearly belong to the discussion, do not include it at all.
    - Skip filler, side chatter, and anything obviously not part of the meeting.
    """

    static func chunk(_ text: String, size: Int = 4500) -> [String] {
        guard text.count > size else { return [text] }
        var chunks: [String] = []
        var current = ""
        for s in text.split(separator: ".", omittingEmptySubsequences: false) {
            let piece = s + "."
            if current.count + piece.count > size, !current.isEmpty {
                chunks.append(current); current = ""
            }
            current += piece
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    static func tidy(_ text: String) -> String {
        var lines = text.components(separatedBy: .newlines).map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "*", with: "")
                .trimmingCharacters(in: .whitespaces)
            if t.lowercased().hasPrefix("what was discussed") { return "## What was discussed" }
            if t.lowercased().hasPrefix("action item") { return "## Action items" }
            if t.hasPrefix("*   ") { return "- " + t.dropFirst(4) }
            return line.replacingOccurrences(of: "*   ", with: "- ")
        }
        if let i = lines.firstIndex(of: "## Action items") {
            let after = lines[(i + 1)...]
            if after.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("-") }) {
                lines.removeAll { $0.trimmingCharacters(in: .whitespaces).lowercased() == "none mentioned." }
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static func run(transcript: String, myNotes: [String],
                    progress: @MainActor @escaping (String) -> Void) async -> String {
        guard isAvailable else {
            return "_(Apple Intelligence is off, so there are no written-up notes. Turn it on in System Settings → Apple Intelligence & Siri.)_"
        }
        guard transcript.count > 80 else { return "_(Too short to write up.)_" }

        let outline = myNotes.isEmpty ? "" : """


        While the meeting happened, the person took these rough notes. They tell \
        you which topics mattered MOST to them, so cover those in more detail. Do \
        NOT simply repeat these lines back — expand each using what was actually \
        said, and include anything important they missed:
        \(myNotes.map { "- \($0)" }.joined(separator: "\n"))
        """

        let pieces = chunk(transcript)
        var partials: [String] = []
        do {
            for (i, piece) in pieces.enumerated() {
                if pieces.count > 1 {
                    await progress("Writing up part \(i + 1) of \(pieces.count)…")
                }
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
                action items at all.\(outline)

                TRANSCRIPT:
                \(piece)
                """)
                partials.append(r.content)
            }
            if partials.count == 1 { return tidy(partials[0]) }
            await progress("Combining the parts…")
            let session = LanguageModelSession(instructions: instructions)
            let r = try await session.respond(to: """
            These are notes from consecutive parts of one meeting. Combine them
            into a single set of notes, removing repetition. Use exactly the two
            markdown headings "## What was discussed" and "## Action items".

            \(partials.joined(separator: "\n\n---\n\n"))
            """)
            return tidy(r.content)
        } catch {
            return "_(Couldn't write up the notes: \(error.localizedDescription))_"
        }
    }
}
