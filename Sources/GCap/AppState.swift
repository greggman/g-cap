import AVFoundation
import AppKit
import ScreenCaptureKit

enum SourceKind: String, CaseIterable, Identifiable {
    case display = "Screen"
    case window = "Window"
    case region = "Region"
    var id: String { rawValue }
}

@MainActor
final class AppState: ObservableObject {
    // Source
    @Published var sourceKind = SourceKind.display
    @Published private(set) var displays: [SCDisplay] = []
    @Published private(set) var windows: [SCWindow] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var selectedWindowID: CGWindowID?
    @Published var region: ScreenRegion? {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(region), forKey: "region") }
    }

    // Audio
    @Published var captureSystemAudio = true
    @Published var captureMicrophone = false
    @Published private(set) var microphones: [AVCaptureDevice] = []
    @Published var selectedMicrophoneID: String?

    // Video
    @Published var codec = VideoCodec.hevc
    @Published var quality = Quality.veryHigh
    @Published var fps = 60
    @Published var showsCursor = true

    // Output
    @Published var outputFolder: URL

    // Status
    @Published private(set) var isRecording = false
    @Published private(set) var isBusy = false
    @Published private(set) var recordingStart: Date?
    @Published private(set) var lastRecording: URL?
    @Published var errorMessage: String?

    private var content: SCShareableContent?
    private let engine = CaptureEngine()
    private let regionEditor = RegionEditor()
    private let regionOutline = RegionOutline()

    init() {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let saved = UserDefaults.standard.url(forKey: "outputFolder")
        outputFolder = saved ?? movies.appendingPathComponent("G-Cap", isDirectory: true)
        region = UserDefaults.standard.data(forKey: "region").flatMap { try? JSONDecoder().decode(ScreenRegion.self, from: $0) }
        engine.onUnexpectedStop = { [weak self] error in
            guard let self, self.isRecording else { return }
            Task { await self.stopRecording(reason: error) }
        }
    }

    func setOutputFolder(_ url: URL) {
        outputFolder = url
        UserDefaults.standard.set(url, forKey: "outputFolder")
    }

    // MARK: Sources

    func refreshSources() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            self.content = content
            displays = content.displays
            let pid = ProcessInfo.processInfo.processIdentifier
            windows = content.windows
                .filter { w in
                    w.windowLayer == 0 && w.frame.width >= 64 && w.frame.height >= 64
                        && w.owningApplication != nil && w.owningApplication?.processID != pid
                }
                .sorted { windowLabel($0).localizedCaseInsensitiveCompare(windowLabel($1)) == .orderedAscending }
            if selectedDisplayID.map({ id in !displays.contains { $0.displayID == id } }) ?? true {
                selectedDisplayID = displays.first(where: { $0.displayID == CGMainDisplayID() })?.displayID
                    ?? displays.first?.displayID
            }
            if let id = selectedWindowID, !windows.contains(where: { $0.windowID == id }) {
                selectedWindowID = nil
            }
            if selectedWindowID == nil {
                selectedWindowID = windows.first?.windowID
            }
            if errorMessage == Self.permissionMessage { errorMessage = nil }
        } catch {
            errorMessage = Self.permissionMessage
        }
        refreshMicrophones()
    }

    static let permissionMessage =
        "G-Cap needs Screen Recording permission. Enable it in System Settings › Privacy & Security › Screen & System Audio Recording, then relaunch G-Cap."

    func refreshMicrophones() {
        microphones = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices
        if selectedMicrophoneID.map({ id in !microphones.contains { $0.uniqueID == id } }) ?? true {
            selectedMicrophoneID = AVCaptureDevice.default(for: .audio)?.uniqueID ?? microphones.first?.uniqueID
        }
    }

    func displayLabel(_ display: SCDisplay) -> String {
        let name = NSScreen.screens.first(where: { $0.displayID == display.displayID })?.localizedName ?? "Display \(display.displayID)"
        return "\(name) — \(display.width) × \(display.height)"
    }

    func windowLabel(_ window: SCWindow) -> String {
        let app = window.owningApplication?.applicationName ?? "Unknown"
        guard let title = window.title, !title.isEmpty else { return app }
        return "\(app) — \(title)"
    }

    func editRegion() {
        regionEditor.begin(initial: region) { [weak self] result in
            guard let self else { return }
            switch result {
            case .cancel:
                NSApp.activate(ignoringOtherApps: true)
            case .done(let region):
                self.region = region
                self.sourceKind = .region
                NSApp.activate(ignoringOtherApps: true)
            case .record(let region):
                self.region = region
                self.sourceKind = .region
                Task { await self.startRecording() }
            }
        }
    }

    var regionDescription: String {
        guard let region, let screen = NSScreen.withDisplayID(region.displayID) else { return "No region selected" }
        let r = region.rect, scale = screen.backingScaleFactor
        return "\(Int(r.width * scale)) × \(Int(r.height * scale)) px on \(screen.localizedName)"
    }

    // MARK: Recording

    func toggleRecording() async {
        if isRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    func startRecording() async {
        guard !isRecording, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil

        if captureMicrophone, !(await AVCaptureDevice.requestAccess(for: .audio)) {
            errorMessage = "G-Cap needs Microphone permission. Enable it in System Settings › Privacy & Security › Microphone."
            return
        }

        // Re-fetch so window and display objects are current.
        await refreshSources()
        guard let content else { return }

        do {
            let (filter, config, outlineRegion) = try makeFilterAndConfiguration(content: content)
            try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
            let recorder = try Recorder(
                url: nextOutputURL(), width: config.width, height: config.height, fps: fps,
                codec: codec, quality: quality,
                systemAudio: config.capturesAudio, microphone: config.captureMicrophone)
            try await engine.start(filter: filter, configuration: config, recorder: recorder)
            if let outlineRegion { regionOutline.show(outlineRegion) }
            recordingStart = Date()
            isRecording = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopRecording(reason: Error? = nil) async {
        guard isRecording else { return }
        isBusy = true
        defer { isBusy = false }
        regionOutline.hide()
        isRecording = false
        recordingStart = nil
        do {
            lastRecording = try await engine.stop()
            if let reason, (reason as NSError).code != SCStreamError.userStopped.rawValue {
                errorMessage = "Recording stopped: \(reason.localizedDescription)"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private struct SetupError: LocalizedError {
        var errorDescription: String?
    }

    private func makeFilterAndConfiguration(content: SCShareableContent)
        throws -> (SCContentFilter, SCStreamConfiguration, ScreenRegion?) {
        let config = SCStreamConfiguration()
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownApp = content.applications.filter { $0.processID == pid }
        let filter: SCContentFilter
        var outline: ScreenRegion?

        func displayFilter(_ id: CGDirectDisplayID?) throws -> SCContentFilter {
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw SetupError(errorDescription: "The selected display is no longer available.")
            }
            return SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
        }

        var size: CGSize
        switch sourceKind {
        case .display:
            filter = try displayFilter(selectedDisplayID)
            size = filter.contentRect.size
        case .window:
            guard let window = content.windows.first(where: { $0.windowID == selectedWindowID }) else {
                throw SetupError(errorDescription: "The selected window is no longer available. Pick another one.")
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            size = filter.contentRect.size
            config.ignoreShadowsSingleWindow = true
        case .region:
            guard let region else {
                throw SetupError(errorDescription: "Select a region first.")
            }
            filter = try displayFilter(region.displayID)
            config.sourceRect = region.rect
            size = region.rect.size
            outline = region
        }

        // Capture at native pixel resolution. Encoders want even dimensions.
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int((size.width * scale).rounded()) & ~1
        config.height = Int((size.height * scale).rounded()) & ~1
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 8
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = showsCursor

        config.capturesAudio = captureSystemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2

        config.captureMicrophone = captureMicrophone
        if captureMicrophone {
            config.microphoneCaptureDeviceID = selectedMicrophoneID
        }
        return (filter, config, outline)
    }

    private func nextOutputURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "G-Cap \(formatter.string(from: Date()))"
        var url = outputFolder.appendingPathComponent(base).appendingPathExtension("mov")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = outputFolder.appendingPathComponent("\(base) \(n)").appendingPathExtension("mov")
            n += 1
        }
        return url
    }
}
