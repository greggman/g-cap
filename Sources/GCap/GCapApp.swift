import SwiftUI

@main
struct GCapApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("G-Cap", id: "main") {
            ContentView()
                .environmentObject(state)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandMenu("Recording") {
                Button(state.isRecording ? "Stop Recording" : "Start Recording") {
                    Task { await state.toggleRecording() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(state.isBusy)
            }
        }

        MenuBarExtra(isInserted: .constant(state.isRecording)) {
            RecordingMenu()
                .environmentObject(state)
        } label: {
            Image(systemName: "record.circle.fill")
        }
    }
}

private struct RecordingMenu: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if let start = state.recordingStart {
            Text("Recording — started \(start.formatted(date: .omitted, time: .standard))")
        }
        Button("Stop Recording") {
            Task { await state.stopRecording() }
        }
    }
}
