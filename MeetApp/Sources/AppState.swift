// AppState.swift — what the app is doing right now, and the commands to change it.

import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        case working(String)
    }

    @Published var phase: Phase = .idle
    @Published var typedNotes: String = ""
    @Published var elapsed: TimeInterval = 0
    @Published var meetings: [Meeting] = Meeting.load()
    @Published var selected: Meeting.ID?
    @Published var problem: String?

    private let mic = Microphone()
    private var slug = ""
    private var startedAt = Date()
    private var ticker: Timer?

    var isRecording: Bool { phase == .recording }

    var selectedMeeting: Meeting? {
        meetings.first { $0.id == selected }
    }

    func start() {
        problem = nil
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        slug = f.string(from: Date())

        do {
            try mic.start(slug: slug)
        } catch {
            problem = error.localizedDescription
            return
        }

        typedNotes = ""
        startedAt = Date()
        elapsed = 0
        phase = .recording
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.elapsed = Date().timeIntervalSince(self.startedAt)
            }
        }
    }

    func stop() {
        guard isRecording, let audioURL = mic.fileURL else { return }
        mic.stop()
        ticker?.invalidate()
        ticker = nil
        let length = Date().timeIntervalSince(startedAt)
        let notes = typedNotes
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let slug = self.slug
        phase = .working("Listening back…")

        Task {
            let transcript = await Transcriber.run(audioURL)
            self.phase = .working("Writing up the notes…")
            let cleaned = await Summarizer.run(transcript: transcript, myNotes: notes) { msg in
                self.phase = .working(msg)
            }
            self.save(slug: slug, length: length, notes: notes,
                      cleaned: cleaned, transcript: transcript)
            self.meetings = Meeting.load()
            self.selected = slug
            self.phase = .idle
        }
    }

    /// Re-run an old recording through transcription and write-up again.
    func redo(_ meeting: Meeting) {
        let audioURL = Library.recordings.appendingPathComponent("\(meeting.id).caf")
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            problem = "The audio for this meeting is gone, so it can't be redone."
            return
        }
        let old = meeting.body
        var notes: [String] = []
        if let start = old.range(of: "## What I typed") {
            let rest = old[start.upperBound...]
            let section = rest.components(separatedBy: "## Transcript").first ?? ""
            notes = section.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("- ") }
                .map { String($0.dropFirst(2)) }
        }
        phase = .working("Listening back…")
        Task {
            let transcript = await Transcriber.run(audioURL)
            self.phase = .working("Writing up the notes…")
            let cleaned = await Summarizer.run(transcript: transcript, myNotes: notes) { msg in
                self.phase = .working(msg)
            }
            self.save(slug: meeting.id, length: 0, notes: notes,
                      cleaned: cleaned, transcript: transcript)
            self.meetings = Meeting.load()
            self.selected = meeting.id
            self.phase = .idle
        }
    }

    func delete(_ meeting: Meeting) {
        try? FileManager.default.removeItem(at: meeting.url)
        try? FileManager.default.removeItem(
            at: Library.recordings.appendingPathComponent("\(meeting.id).caf"))
        meetings = Meeting.load()
        if selected == meeting.id { selected = meetings.first?.id }
    }

    private func save(slug: String, length: TimeInterval, notes: [String],
                      cleaned: String, transcript: String) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        let date = f.date(from: slug) ?? Date()
        let pretty = DateFormatter()
        pretty.dateFormat = "EEEE d MMMM, h:mm a"

        let lengthLine = length > 0
            ? "\nLength: \(Int(length) / 60)m \(Int(length) % 60)s"
            : ""
        let typed = notes.isEmpty
            ? "_(You didn't type any notes.)_"
            : notes.map { "- \($0)" }.joined(separator: "\n")

        let markdown = """
        # \(pretty.string(from: date))
        \(lengthLine)

        \(cleaned)

        ---

        ## What I typed

        \(typed)

        ## Transcript

        \(transcript)
        """
        let url = Library.root.appendingPathComponent("\(slug).md")
        try? markdown.write(to: url, atomically: true, encoding: .utf8)
    }
}
