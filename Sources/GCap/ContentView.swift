import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            Form {
                sourceSection
                audioSection
                videoSection
                outputSection
            }
            .formStyle(.grouped)
            .disabled(state.isRecording || state.isBusy)

            Divider()
            footer
                .padding(16)
        }
        .frame(width: 500)
        .task { await state.refreshSources() }
    }

    // MARK: Sections

    private var sourceSection: some View {
        Section("Capture") {
            Picker("Source", selection: $state.sourceKind) {
                ForEach(SourceKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            switch state.sourceKind {
            case .display:
                Picker("Display", selection: $state.selectedDisplayID) {
                    ForEach(state.displays, id: \.displayID) { display in
                        Text(state.displayLabel(display)).tag(Optional(display.displayID))
                    }
                }
            case .window:
                HStack {
                    Picker("Window", selection: $state.selectedWindowID) {
                        ForEach(state.windows, id: \.windowID) { window in
                            Text(state.windowLabel(window)).lineLimit(1).tag(Optional(window.windowID))
                        }
                    }
                    Button {
                        Task { await state.refreshSources() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh window list")
                }
            case .region:
                LabeledContent("Region") {
                    HStack {
                        Text(state.regionDescription)
                            .foregroundStyle(.secondary)
                        Button("Select…") { state.selectRegion() }
                    }
                }
            }
            Toggle("Show cursor", isOn: $state.showsCursor)
        }
    }

    private var audioSection: some View {
        Section("Audio") {
            Toggle("System audio", isOn: $state.captureSystemAudio)
            Toggle("Microphone", isOn: $state.captureMicrophone)
            if state.captureMicrophone {
                Picker("Input", selection: $state.selectedMicrophoneID) {
                    ForEach(state.microphones, id: \.uniqueID) { mic in
                        Text(mic.localizedName).tag(Optional(mic.uniqueID))
                    }
                }
            }
            if state.captureSystemAudio && state.captureMicrophone {
                Text("System audio and microphone are saved as separate audio tracks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var videoSection: some View {
        Section("Video") {
            Picker("Codec", selection: $state.codec) {
                ForEach(VideoCodec.allCases) { Text($0.rawValue).tag($0) }
            }
            if !state.codec.isProRes {
                Picker("Quality", selection: $state.quality) {
                    ForEach(Quality.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            Picker("Frame rate", selection: $state.fps) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            Text(qualityNote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var qualityNote: String {
        if state.codec.isProRes {
            return "ProRes is visually lossless with 24-bit PCM audio. Files are large (roughly 1–3 GB per minute at Retina resolutions)."
        }
        if let display = state.displays.first(where: { $0.displayID == state.selectedDisplayID }) {
            let scale = NSScreen.screens.first(where: { $0.displayID == display.displayID })?.backingScaleFactor ?? 2
            let w = Int(CGFloat(display.width) * scale), h = Int(CGFloat(display.height) * scale)
            let mbps = Double(state.quality.bitrate(width: w, height: h, fps: state.fps)) / 1_000_000
            return "About \(Int(mbps.rounded())) Mbps for a full \(w) × \(h) screen, with 256 kbps AAC audio."
        }
        return "Native pixel resolution, with 256 kbps AAC audio."
    }

    private var outputSection: some View {
        Section("Output") {
            LabeledContent("Save to") {
                HStack {
                    Text(state.outputFolder.path(percentEncoded: false))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("Choose…") { chooseFolder() }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = state.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if let start = state.recordingStart {
                    TimelineView(.periodic(from: start, by: 1)) { context in
                        Text(Duration.seconds(context.date.timeIntervalSince(start)),
                             format: .time(pattern: .hourMinuteSecond))
                            .monospacedDigit()
                            .font(.title3)
                    }
                } else if let last = state.lastRecording {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([last])
                    } label: {
                        Label(last.lastPathComponent, systemImage: "film")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.link)
                    .help("Show in Finder")
                }
                Spacer()
                Button {
                    Task { await state.toggleRecording() }
                } label: {
                    Label(state.isRecording ? "Stop" : "Record",
                          systemImage: state.isRecording ? "stop.fill" : "record.circle")
                        .frame(minWidth: 90)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(state.isRecording ? .red : .accentColor)
                .disabled(state.isBusy || !canRecord)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var canRecord: Bool {
        if state.isRecording { return true }
        switch state.sourceKind {
        case .display: return state.selectedDisplayID != nil
        case .window: return state.selectedWindowID != nil
        case .region: return state.region != nil
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = state.outputFolder
        if panel.runModal() == .OK, let url = panel.url {
            state.setOutputFolder(url)
        }
    }
}
