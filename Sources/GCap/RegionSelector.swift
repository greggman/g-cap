import AppKit

/// A region of a display, in points, with a top-left origin relative to the
/// display (the coordinate space SCStreamConfiguration.sourceRect uses).
struct ScreenRegion: Equatable {
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
}

private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Covers every screen with a dimmed overlay and lets the user drag out a rectangle.
@MainActor
final class RegionSelector {
    private var windows: [NSWindow] = []
    private var completion: ((ScreenRegion?) -> Void)?

    func begin(completion: @escaping (ScreenRegion?) -> Void) {
        self.completion = completion
        for screen in NSScreen.screens {
            guard let displayID = screen.displayID else { continue }
            let window = KeyableWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = RegionSelectionView()
            view.onSelect = { [weak self] rect in self?.finish(ScreenRegion(displayID: displayID, rect: rect)) }
            view.onCancel = { [weak self] in self?.finish(nil) }
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish(_ region: ScreenRegion?) {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        let completion = self.completion
        self.completion = nil
        completion?(region)
    }
}

private final class RegionSelectionView: NSView {
    var onSelect: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    private var anchor: CGPoint?
    private var current: CGPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    private var selection: CGRect? {
        guard let anchor, let current else { return nil }
        return CGRect(x: min(anchor.x, current.x), y: min(anchor.y, current.y),
                      width: abs(anchor.x - current.x), height: abs(anchor.y - current.y)).integral
    }

    private func clampedPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(p.x, 0), bounds.maxX), y: min(max(p.y, 0), bounds.maxY))
    }

    override func mouseDown(with event: NSEvent) {
        anchor = clampedPoint(event)
        current = anchor
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = clampedPoint(event)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = clampedPoint(event)
        if let rect = selection, rect.width >= 16, rect.height >= 16 {
            onSelect?(rect)
        } else {
            anchor = nil
            current = nil
            needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        guard let rect = selection else {
            drawLabel("Drag to select a region. Esc to cancel.", at: CGPoint(x: bounds.midX, y: bounds.midY), centered: true)
            return
        }
        NSColor.clear.setFill()
        rect.fill(using: .copy)
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        border.stroke()

        let scale = window?.backingScaleFactor ?? 1
        let label = "\(Int(rect.width)) × \(Int(rect.height)) pt  (\(Int(rect.width * scale)) × \(Int(rect.height * scale)) px)"
        drawLabel(label, at: CGPoint(x: rect.minX, y: rect.maxY + 6), centered: false)
    }

    private func drawLabel(_ text: String, at point: CGPoint, centered: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attrs)
        let size = string.size()
        var origin = centered ? CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2) : point
        origin.y = min(origin.y, bounds.maxY - size.height - 6)
        let background = CGRect(origin: origin, size: size).insetBy(dx: -6, dy: -3)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: background, xRadius: 4, yRadius: 4).fill()
        string.draw(at: origin)
    }
}

/// A click-through outline drawn around the region being recorded.
/// It belongs to this app, which is excluded from capture, so it never shows up in the recording.
@MainActor
final class RegionOutline {
    private var window: NSWindow?

    func show(_ region: ScreenRegion) {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == region.displayID }) else { return }
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
