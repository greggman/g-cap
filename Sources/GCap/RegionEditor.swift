import AppKit
import Combine
import SwiftUI

/// A region of a display, in points, with a top-left origin relative to the
/// display (the coordinate space SCStreamConfiguration.sourceRect uses).
struct ScreenRegion: Equatable, Codable {
    var displayID: CGDirectDisplayID
    var rect: CGRect
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Converts a top-left-origin rect in this screen's points to global Cocoa coordinates.
    func cocoaRect(fromTopLeft rect: CGRect) -> CGRect {
        CGRect(x: frame.minX + rect.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    static func withDisplayID(_ id: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == id }
    }
}

enum AspectRatio: String, CaseIterable, Identifiable {
    case free = "Free"
    case r16x9 = "16:9"
    case r16x10 = "16:10"
    case r4x3 = "4:3"
    case r1x1 = "1:1"
    case r9x16 = "9:16"
    case r4x5 = "4:5"

    var id: String { rawValue }

    /// Width divided by height, or nil for free.
    var value: CGFloat? {
        guard self != .free else { return nil }
        let parts = rawValue.split(separator: ":").compactMap { Double($0) }
        return CGFloat(parts[0] / parts[1])
    }

    static func matching(width: CGFloat, height: CGFloat) -> AspectRatio {
        allCases.first { $0.value.map { abs($0 - width / height) < 0.001 } ?? false } ?? .free
    }
}

struct SizePreset: Identifiable {
    var name: String
    var width: Int
    var height: Int
    var id: String { name }

    static let all = [
        SizePreset(name: "720p — 1280 × 720", width: 1280, height: 720),
        SizePreset(name: "1080p — 1920 × 1080", width: 1920, height: 1080),
        SizePreset(name: "1440p — 2560 × 1440", width: 2560, height: 1440),
        SizePreset(name: "4K — 3840 × 2160", width: 3840, height: 2160),
        SizePreset(name: "Square — 1080 × 1080", width: 1080, height: 1080),
        SizePreset(name: "Portrait — 1080 × 1350", width: 1080, height: 1350),
        SizePreset(name: "Vertical — 1080 × 1920", width: 1080, height: 1920),
    ]
}

/// The part of the rectangle a drag grabbed.
enum RegionHandle {
    case move, draw
    case top, bottom, left, right
    case topLeft, topRight, bottomLeft, bottomRight

    var movesLeft: Bool { [.left, .topLeft, .bottomLeft].contains(self) }
    var movesRight: Bool { [.right, .topRight, .bottomRight].contains(self) }
    var movesTop: Bool { [.top, .topLeft, .topRight].contains(self) }
    var movesBottom: Bool { [.bottom, .bottomLeft, .bottomRight].contains(self) }
    var isCorner: Bool { [.topLeft, .topRight, .bottomLeft, .bottomRight].contains(self) }
}

/// Region geometry shared by every screen's overlay and the HUD.
@MainActor
final class RegionEditorModel: ObservableObject {
    static let minimumSize: CGFloat = 16

    @Published var region: ScreenRegion
    @Published private(set) var aspect: AspectRatio {
        didSet { UserDefaults.standard.set(aspect.rawValue, forKey: "regionAspect") }
    }

    init(region: ScreenRegion) {
        self.region = region
        aspect = UserDefaults.standard.string(forKey: "regionAspect").flatMap(AspectRatio.init(rawValue:)) ?? .free
    }

    var scale: CGFloat { NSScreen.withDisplayID(region.displayID)?.backingScaleFactor ?? 2 }
    var bounds: CGRect { Self.bounds(of: region.displayID) }

    static func bounds(of displayID: CGDirectDisplayID) -> CGRect {
        CGRect(origin: .zero, size: NSScreen.withDisplayID(displayID)?.frame.size ?? CGSize(width: 1920, height: 1080))
    }

    var pixelWidth: Int { Int((region.rect.width * scale).rounded()) }
    var pixelHeight: Int { Int((region.rect.height * scale).rounded()) }

    func setAspect(_ aspect: AspectRatio) {
        self.aspect = aspect
        guard let r = aspect.value else { return }
        let rect = region.rect
        var size = CGSize(width: rect.width, height: rect.width / r)
        size = fit(size, ratio: r, in: bounds.size)
        setSize(size, keepingCenterOf: rect)
    }

    /// Sets the size in pixels. With an aspect lock, `changedWidth` says which value the user typed.
    func setPixelSize(width: Int, height: Int, changedWidth: Bool) {
        var size = CGSize(width: CGFloat(max(width, 1)) / scale, height: CGFloat(max(height, 1)) / scale)
        if let r = aspect.value {
            if changedWidth { size.height = size.width / r } else { size.width = size.height * r }
            size = fit(size, ratio: r, in: bounds.size)
        }
        setSize(size, keepingCenterOf: region.rect)
    }

    func applyPreset(_ preset: SizePreset) {
        aspect = AspectRatio.matching(width: CGFloat(preset.width), height: CGFloat(preset.height))
        let size = CGSize(width: CGFloat(preset.width) / scale, height: CGFloat(preset.height) / scale)
        let ratio = size.width / size.height
        setSize(fit(size, ratio: ratio, in: bounds.size), keepingCenterOf: region.rect)
    }

    func nudge(dx: CGFloat, dy: CGFloat) {
        region.rect = clampPosition(region.rect.offsetBy(dx: dx, dy: dy), in: bounds)
    }

    /// Computes the rectangle for a drag of `handle` that started with `start` and has moved by `delta`.
    func drag(_ handle: RegionHandle, displayID: CGDirectDisplayID, start: CGRect, anchor: CGPoint, current: CGPoint) {
        let bounds = Self.bounds(of: displayID)
        let ratio = aspect.value
        let delta = CGPoint(x: current.x - anchor.x, y: current.y - anchor.y)
        var rect: CGRect

        switch handle {
        case .move:
            rect = clampPosition(start.offsetBy(dx: delta.x, dy: delta.y), in: bounds)
        case .draw:
            rect = cornerResize(fixed: anchor, moving: clamp(current, to: bounds), ratio: ratio, bounds: bounds)
        default:
            let m = Self.minimumSize
            var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
            if handle.movesLeft { minX = min(max(start.minX + delta.x, bounds.minX), maxX - m) }
            if handle.movesRight { maxX = max(min(start.maxX + delta.x, bounds.maxX), minX + m) }
            if handle.movesTop { minY = min(max(start.minY + delta.y, bounds.minY), maxY - m) }
            if handle.movesBottom { maxY = max(min(start.maxY + delta.y, bounds.maxY), minY + m) }
            rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

            if let r = ratio {
                if handle.isCorner {
                    let fixed = CGPoint(x: handle.movesLeft ? start.maxX : start.minX,
                                        y: handle.movesTop ? start.maxY : start.minY)
                    let moving = CGPoint(x: handle.movesLeft ? minX : maxX, y: handle.movesTop ? minY : maxY)
                    rect = cornerResize(fixed: fixed, moving: moving, ratio: r, bounds: bounds)
                } else if handle.movesLeft || handle.movesRight {
                    // Width drives; height follows, centered on the original.
                    let size = atLeastMinimum(fit(CGSize(width: rect.width, height: rect.width / r), ratio: r, in: bounds.size), ratio: r)
                    let x = handle.movesLeft ? start.maxX - size.width : start.minX
                    rect = clampPosition(CGRect(x: x, y: start.midY - size.height / 2, width: size.width, height: size.height), in: bounds)
                } else {
                    let size = atLeastMinimum(fit(CGSize(width: rect.height * r, height: rect.height), ratio: r, in: bounds.size), ratio: r)
                    let y = handle.movesTop ? start.maxY - size.height : start.minY
                    rect = clampPosition(CGRect(x: start.midX - size.width / 2, y: y, width: size.width, height: size.height), in: bounds)
                }
            }
        }
        region = ScreenRegion(displayID: displayID, rect: rect.roundedToPoints)
    }

    // MARK: Geometry helpers

    /// A rectangle from a fixed corner toward a moving point, honoring the aspect ratio and screen bounds.
    private func cornerResize(fixed: CGPoint, moving: CGPoint, ratio: CGFloat?, bounds: CGRect) -> CGRect {
        let signX: CGFloat = moving.x >= fixed.x ? 1 : -1
        let signY: CGFloat = moving.y >= fixed.y ? 1 : -1
        var w = abs(moving.x - fixed.x)
        var h = abs(moving.y - fixed.y)
        if let r = ratio {
            // Grow to cover the pointer, then shrink to fit the room available from the fixed corner.
            if w / max(h, 1) > r { h = w / r } else { w = h * r }
            let roomW = signX > 0 ? bounds.maxX - fixed.x : fixed.x - bounds.minX
            let roomH = signY > 0 ? bounds.maxY - fixed.y : fixed.y - bounds.minY
            let s = min(1, roomW / max(w, 1), roomH / max(h, 1))
            w *= s
            h *= s
        }
        let size = ratio.map { atLeastMinimum(CGSize(width: w, height: h), ratio: $0) }
            ?? CGSize(width: max(w, Self.minimumSize), height: max(h, Self.minimumSize))
        w = size.width
        h = size.height
        let rect = CGRect(x: signX > 0 ? fixed.x : fixed.x - w, y: signY > 0 ? fixed.y : fixed.y - h, width: w, height: h)
        return clampPosition(rect, in: bounds)
    }

    /// Grows `size` so neither side is below the minimum, keeping the ratio.
    private func atLeastMinimum(_ size: CGSize, ratio: CGFloat) -> CGSize {
        let s = max(1, Self.minimumSize / size.width, Self.minimumSize / size.height)
        return CGSize(width: size.width * s, height: size.height * s)
    }

    private func fit(_ size: CGSize, ratio: CGFloat, in limit: CGSize) -> CGSize {
        let s = min(1, limit.width / size.width, limit.height / size.height)
        return CGSize(width: size.width * s, height: size.height * s)
    }

    private func setSize(_ size: CGSize, keepingCenterOf rect: CGRect) {
        let w = min(max(size.width, Self.minimumSize), bounds.width)
        let h = min(max(size.height, Self.minimumSize), bounds.height)
        let r = CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
        region.rect = clampPosition(r, in: bounds).roundedToPoints
    }

    private func clampPosition(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        var r = rect
        r.size.width = min(r.width, bounds.width)
        r.size.height = min(r.height, bounds.height)
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        return r
    }

    private func clamp(_ p: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
    }
}

private extension CGRect {
    /// Rounds origin and size independently, so the size isn't grown the way `integral` does.
    var roundedToPoints: CGRect {
        CGRect(x: minX.rounded(), y: minY.rounded(), width: width.rounded(), height: height.rounded())
    }
}

private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Covers every screen with a dimmed overlay showing an editable rectangle.
@MainActor
final class RegionEditor {
    enum Result {
        case cancel
        case done(ScreenRegion)
        case record(ScreenRegion)
    }

    private var windows: [NSWindow] = []
    private var model: RegionEditorModel?
    private var completion: ((Result) -> Void)?
    private var observer: AnyCancellable?

    var isActive: Bool { model != nil }

    func begin(initial: ScreenRegion?, completion: @escaping (Result) -> Void) {
        guard !isActive else { return }
        self.completion = completion
        let model = RegionEditorModel(region: Self.validated(initial) ?? Self.defaultRegion())
        self.model = model

        var views: [RegionOverlayView] = []
        for screen in NSScreen.screens {
            guard let displayID = screen.displayID else { continue }
            let window = KeyableWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.acceptsMouseMovedEvents = true
            // Clicks on fully transparent pixels otherwise fall through to the windows below.
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = RegionOverlayView(displayID: displayID, model: model) { [weak self] result in
                self?.finish(result)
            }
            window.contentView = view
            window.orderFrontRegardless()
            windows.append(window)
            views.append(view)
        }
        observer = model.objectWillChange.sink { _ in
            DispatchQueue.main.async { views.forEach { $0.modelDidChange() } }
        }
        NSApp.activate(ignoringOtherApps: true)
        if let active = views.first(where: { $0.displayID == model.region.displayID }) {
            active.window?.makeKeyAndOrderFront(nil)
            active.window?.makeFirstResponder(active)
        }
        views.forEach { $0.modelDidChange() }
    }

    private func finish(_ result: Result) {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        observer = nil
        model = nil
        let completion = self.completion
        self.completion = nil
        completion?(result)
    }

    private static func validated(_ region: ScreenRegion?) -> ScreenRegion? {
        guard let region, NSScreen.withDisplayID(region.displayID) != nil else { return nil }
        let bounds = RegionEditorModel.bounds(of: region.displayID)
        return bounds.contains(region.rect) ? region : nil
    }

    /// 1280 × 720 pixels (or as close as fits) centered on the screen under the mouse.
    private static func defaultRegion() -> ScreenRegion {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let size = screen.frame.size
        var w = 1280 / screen.backingScaleFactor, h = 720 / screen.backingScaleFactor
        let s = min(1, size.width * 0.8 / w, size.height * 0.8 / h)
        w *= s
        h *= s
        let rect = CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h).integral
        return ScreenRegion(displayID: screen.displayID ?? CGMainDisplayID(), rect: rect)
    }
}

private final class RegionOverlayView: NSView {
    let displayID: CGDirectDisplayID
    private let model: RegionEditorModel
    private let onFinish: (RegionEditor.Result) -> Void
    private let hud: NSHostingView<RegionHUD>

    private var dragHandle: RegionHandle?
    private var dragStartRect = CGRect.zero
    private var dragAnchor = CGPoint.zero

    init(displayID: CGDirectDisplayID, model: RegionEditorModel, onFinish: @escaping (RegionEditor.Result) -> Void) {
        self.displayID = displayID
        self.model = model
        self.onFinish = onFinish
        hud = NSHostingView(rootView: RegionHUD(
            model: model,
            onCancel: { onFinish(.cancel) },
            onDone: { onFinish(.done(model.region)) },
            onRecord: { onFinish(.record(model.region)) }))
        super.init(frame: .zero)
        addSubview(hud)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var isActive: Bool { model.region.displayID == displayID }
    private var rect: CGRect? { isActive ? model.region.rect : nil }

    func modelDidChange() {
        needsDisplay = true
        needsLayout = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        hud.isHidden = !isActive
        guard let rect else { return }
        let size = hud.fittingSize
        let gap: CGFloat = 12
        var y = rect.maxY + gap
        if y + size.height > bounds.maxY - gap {
            y = rect.minY - gap - size.height
            if y < bounds.minY + gap { y = rect.maxY - gap - size.height }
        }
        let x = min(max(rect.midX - size.width / 2, bounds.minX + gap), bounds.maxX - size.width - gap)
        hud.frame = CGRect(x: x, y: y, width: size.width, height: size.height).integral
    }

    // MARK: Hit testing

    private func handle(at p: CGPoint) -> RegionHandle {
        guard let r = rect else { return .draw }
        let grab: CGFloat = 8
        let nearLeft = abs(p.x - r.minX) <= grab, nearRight = abs(p.x - r.maxX) <= grab
        let nearTop = abs(p.y - r.minY) <= grab, nearBottom = abs(p.y - r.maxY) <= grab
        let inX = p.x >= r.minX - grab && p.x <= r.maxX + grab
        let inY = p.y >= r.minY - grab && p.y <= r.maxY + grab
        switch (nearLeft, nearRight, nearTop, nearBottom) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        default: break
        }
        if nearLeft && inY { return .left }
        if nearRight && inY { return .right }
        if nearTop && inX { return .top }
        if nearBottom && inX { return .bottom }
        return r.contains(p) ? .move : .draw
    }

    private func cursor(for handle: RegionHandle) -> NSCursor {
        switch handle {
        case .move: return dragHandle == .move ? .closedHand : .openHand
        case .draw: return .crosshair
        case .top: return .frameResize(position: .top, directions: .all)
        case .bottom: return .frameResize(position: .bottom, directions: .all)
        case .left: return .frameResize(position: .left, directions: .all)
        case .right: return .frameResize(position: .right, directions: .all)
        case .topLeft: return .frameResize(position: .topLeft, directions: .all)
        case .topRight: return .frameResize(position: .topRight, directions: .all)
        case .bottomLeft: return .frameResize(position: .bottomLeft, directions: .all)
        case .bottomRight: return .frameResize(position: .bottomRight, directions: .all)
        }
    }

    private func point(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    private func updateCursor(_ event: NSEvent) {
        let p = point(event)
        if !hud.isHidden && hud.frame.contains(p) {
            NSCursor.arrow.set()
        } else {
            cursor(for: dragHandle ?? handle(at: p)).set()
        }
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(event) }
    override func mouseMoved(with event: NSEvent) { updateCursor(event) }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        let p = point(event)
        dragHandle = handle(at: p)
        dragAnchor = p
        dragStartRect = rect ?? CGRect(origin: p, size: .zero)
        if event.clickCount == 2, dragHandle == .move {
            dragHandle = nil
            onFinish(.done(model.region))
            return
        }
        updateCursor(event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragHandle else { return }
        let p = point(event)
        // A plain click on empty space shouldn't collapse the region; wait for real movement.
        if dragHandle == .draw, hypot(p.x - dragAnchor.x, p.y - dragAnchor.y) < 4 { return }
        model.drag(dragHandle, displayID: displayID, start: dragStartRect, anchor: dragAnchor, current: p)
        updateCursor(event)
    }

    override func mouseUp(with event: NSEvent) {
        dragHandle = nil
        updateCursor(event)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 53: onFinish(.cancel) // Escape
        case 36, 76: onFinish(.done(model.region)) // Return, Enter
        case 123: model.nudge(dx: -step, dy: 0)
        case 124: model.nudge(dx: step, dy: 0)
        case 125: model.nudge(dx: 0, dy: step)
        case 126: model.nudge(dx: 0, dy: -step)
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onFinish(.cancel)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.4).setFill()
        bounds.fill()
        guard let r = rect else { return }

        // Not fully clear: the window server passes clicks on alpha 0 pixels
        // through to whatever is underneath, which would make the region undraggable.
        NSColor.black.withAlphaComponent(0.01).setFill()
        r.fill(using: .copy)

        let border = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        NSColor.white.setStroke()
        border.stroke()

        // Rule-of-thirds guides while dragging.
        if dragHandle != nil {
            let guides = NSBezierPath()
            for i in 1...2 {
                let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
                guides.move(to: CGPoint(x: x, y: r.minY)); guides.line(to: CGPoint(x: x, y: r.maxY))
                guides.move(to: CGPoint(x: r.minX, y: y)); guides.line(to: CGPoint(x: r.maxX, y: y))
            }
            guides.lineWidth = 1
            NSColor.white.withAlphaComponent(0.35).setStroke()
            guides.stroke()
        }

        let knob: CGFloat = 8
        let xs = [r.minX, r.midX, r.maxX], ys = [r.minY, r.midY, r.maxY]
        for (i, x) in xs.enumerated() {
            for (j, y) in ys.enumerated() where !(i == 1 && j == 1) {
                let k = NSBezierPath(roundedRect: CGRect(x: x - knob / 2, y: y - knob / 2, width: knob, height: knob),
                                     xRadius: 2, yRadius: 2)
                NSColor.white.setFill()
                k.fill()
                NSColor.black.withAlphaComponent(0.5).setStroke()
                k.lineWidth = 1
                k.stroke()
            }
        }
    }
}

private struct RegionHUD: View {
    @ObservedObject var model: RegionEditorModel
    var onCancel: () -> Void
    var onDone: () -> Void
    var onRecord: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                TextField("Width", value: Binding(
                    get: { model.pixelWidth },
                    set: { model.setPixelSize(width: $0, height: model.pixelHeight, changedWidth: true) }
                ), format: .number.grouping(.never))
                .frame(width: 60)
                Text("×")
                TextField("Height", value: Binding(
                    get: { model.pixelHeight },
                    set: { model.setPixelSize(width: model.pixelWidth, height: $0, changedWidth: false) }
                ), format: .number.grouping(.never))
                .frame(width: 60)
                Text("px").foregroundStyle(.secondary)

                Picker("Aspect", selection: Binding(get: { model.aspect }, set: { model.setAspect($0) })) {
                    ForEach(AspectRatio.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                .help("Lock the aspect ratio")

                Menu("Size") {
                    ForEach(SizePreset.all) { preset in
                        Button(preset.name) { model.applyPreset(preset) }
                    }
                }
                .fixedSize()
            }
            .textFieldStyle(.roundedBorder)

            HStack {
                Text("Drag to move or resize · Arrows nudge · Esc cancels")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 16)
                Button("Cancel", action: onCancel)
                Button("Done", action: onDone)
                Button(action: onRecord) {
                    Label("Record", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.15)))
        .fixedSize()
    }
}

/// A click-through outline drawn around the region being recorded.
/// It belongs to this app, which is excluded from capture, so it never shows up in the recording.
@MainActor
final class RegionOutline {
    private var window: NSWindow?

    func show(_ region: ScreenRegion) {
        guard let screen = NSScreen.withDisplayID(region.displayID) else { return }
        let frame = screen.cocoaRect(fromTopLeft: region.rect).insetBy(dx: -3, dy: -3)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.borderColor = NSColor.systemRed.cgColor
        view.layer?.borderWidth = 2
        window.contentView = view
        window.orderFrontRegardless()
        self.window = window
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}
