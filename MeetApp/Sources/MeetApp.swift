import SwiftUI

@main
struct MeetingNotesApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup("Meeting Notes") {
            ContentView().environmentObject(app)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button(app.isRecording ? "Stop Recording" : "Start Recording") {
                    app.isRecording ? app.stop() : app.start()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
