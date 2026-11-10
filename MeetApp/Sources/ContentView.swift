// ContentView.swift — everything you see.

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        NavigationSplitView {
            Sidebar()
        } detail: {
            Detail()
        }
        .frame(minWidth: 860, minHeight: 560)
        .alert("Something went wrong",
               isPresented: Binding(get: { app.problem != nil },
                                    set: { if !$0 { app.problem = nil } })) {
            Button("OK") { app.problem = nil }
        } message: {
            Text(app.problem ?? "")
        }
    }
}

// MARK: - the list down the left

struct Sidebar: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $app.selected) {
                ForEach(app.meetings) { m in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(m.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(m.date, style: .date)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .tag(m.id)
                    .contextMenu {
                        Button("Write up again") { app.redo(m) }
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([m.url])
                        }
                        Divider()
                        Button("Delete", role: .destructive) { app.delete(m) }
                    }
                }
            }
            .listStyle(.sidebar)

            if app.meetings.isEmpty {
                VStack(spacing: 6) {
                    Text("No meetings yet").font(.system(size: 13, weight: .medium))
                    Text("Press Record to make your first one.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxHeight: .infinity)
                .padding()
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
    }
}

// MARK: - the big area on the right

struct Detail: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        switch app.phase {
        case .recording:   RecordingView()
        case .working(let msg): WorkingView(message: msg)
        case .idle:
            if let m = app.selectedMeeting {
                NoteView(meeting: m)
            } else {
                WelcomeView()
            }
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.secondary)
            Text("Meeting Notes").font(.system(size: 24, weight: .semibold))
            Text("Records your meeting, listens back, and writes up the notes.\nEverything happens on this Mac — nothing is sent anywhere.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            RecordButton()
                .padding(.top, 6)

            if !Summarizer.isAvailable {
                Label("Apple Intelligence is off, so you'll get a transcript but no written-up notes.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.top, 8)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RecordButton: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Button {
            app.isRecording ? app.stop() : app.start()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: app.isRecording ? "stop.fill" : "record.circle")
                Text(app.isRecording ? "Stop" : "Record")
            }
            .font(.system(size: 14, weight: .medium))
            .frame(width: 150, height: 34)
        }
        .buttonStyle(.borderedProminent)
        .tint(app.isRecording ? .red : .accentColor)
        .keyboardShortcut("r", modifiers: .command)
    }
}

struct RecordingView: View {
    @EnvironmentObject var app: AppState

    var timeString: String {
        let t = Int(app.elapsed)
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(.red).frame(width: 10, height: 10)
                    .opacity(Int(app.elapsed * 2) % 2 == 0 ? 1 : 0.25)
                Text("Recording").font(.system(size: 14, weight: .semibold))
                Text(timeString).font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                RecordButton()
            }
            .padding(16)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Your notes")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Type whatever you'd jot down — one thought per line. These steer how the notes get written.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextEditor(text: $app.typedNotes)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2)))
            }
            .padding(16)
        }
    }
}

struct WorkingView: View {
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(message).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - a finished note

struct NoteView: View {
    let meeting: Meeting
    @EnvironmentObject var app: AppState
    @State private var showTranscript = false

    private var parts: (notes: String, typed: String, transcript: String) {
        let body = meeting.body
        let transcript = body.components(separatedBy: "## Transcript").last ?? ""
        let beforeTranscript = body.components(separatedBy: "## Transcript").first ?? body
        let typed = beforeTranscript.components(separatedBy: "## What I typed").last ?? ""
        var notes = beforeTranscript.components(separatedBy: "## What I typed").first ?? ""
        if let r = notes.range(of: "\n") { notes = String(notes[r.upperBound...]) }
        notes = notes.replacingOccurrences(of: "---", with: "")
        return (notes.trimmingCharacters(in: .whitespacesAndNewlines),
                typed.trimmingCharacters(in: .whitespacesAndNewlines),
                transcript.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title).font(.system(size: 16, weight: .semibold))
                }
                Spacer()
                Button {
                    let p = parts
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(p.notes, forType: .string)
                } label: { Label("Copy notes", systemImage: "doc.on.doc") }
                RecordButton()
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Markdown(parts.notes)

                    if !parts.typed.isEmpty {
                        Divider()
                        Text("What you typed")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Markdown(parts.typed)
                    }

                    Divider()
                    DisclosureGroup(isExpanded: $showTranscript) {
                        Text(parts.transcript)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.top, 8)
                    } label: {
                        Text("Full transcript")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// A very small markdown renderer — enough for headings and bullets.
struct Markdown: View {
    let text: String
    init(_ t: String) { text = t }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(text.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("## ") {
                    Text(line.dropFirst(3))
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.top, 8)
                } else if line.hasPrefix("# ") {
                    Text(line.dropFirst(2)).font(.system(size: 18, weight: .bold))
                } else if line.hasPrefix("- ") {
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(line.dropFirst(2)).font(.system(size: 13))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if !line.isEmpty {
                    Text(line).font(.system(size: 13))
                        .foregroundStyle(line.hasPrefix("_") ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
    }
}
