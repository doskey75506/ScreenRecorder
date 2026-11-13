import AppKit
import RecorderCore

@MainActor
final class ScreenRegionSelector {
    struct Selection {
        let displayID: CGDirectDisplayID
        let appKitRect: CGRect
        let displaySize: CGSize
    }

    private var panels: [NSPanel] = []
    private var hiddenWindows: [NSWindow] = []
    private var continuation: CheckedContinuation<Selection?, Never>?
    private var screenObserver: NSObjectProtocol?

    func select(displayID: CGDirectDisplayID? = nil) async -> Selection? {
        guard continuation == nil else { return nil }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            hiddenWindows = NSApp.windows.filter { $0.isVisible && $0.level == .normal }
            hiddenWindows.forEach { $0.orderOut(nil) }
            for screen in NSScreen.screens {
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
                if let displayID, number.uint32Value != displayID { continue }
                let panel = RegionPanel(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
                panel.setFrame(screen.frame, display: false)
                panel.level = .screenSaver
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false
                panel.hidesOnDeactivate = false
                panel.sharingType = .none
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                let view = RegionSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size),
                                               pixelScale: screen.backingScaleFactor)
                let displaySize = screen.frame.size
                view.onSelection = { [weak self] rect in
                    self?.finish(rect.map { Selection(displayID: number.uint32Value, appKitRect: $0, displaySize: displaySize) })
                }
                panel.contentView = view
                panel.makeFirstResponder(view)
                panels.append(panel)
                panel.orderFrontRegardless()
            }
            guard !panels.isEmpty else { finish(nil); return }
            let active = panels.first { $0.frame.contains(NSEvent.mouseLocation) } ?? panels[0]
            NSApp.activate(ignoringOtherApps: true)
            active.makeKeyAndOrderFront(nil)
            // Moving/disconnecting a screen invalidates the geometry being selected.
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.cancel() }
            }
        }
    }

    func cancel() { finish(nil) }

    private func finish(_ selection: Selection?) {
        guard let continuation else { return }
        self.continuation = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        hiddenWindows.forEach { $0.orderFront(nil) }
        hiddenWindows.first?.makeKeyAndOrderFront(nil)
        hiddenWindows.removeAll()
        continuation.resume(returning: selection)
    }
}

private final class RegionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class RegionSelectionView: NSView {
    var onSelection: ((CGRect?) -> Void)?
    private let pixelScale: CGFloat
    private var start: CGPoint?
    private var selection: CGRect?

    init(frame: CGRect, pixelScale: CGFloat) {
        self.pixelScale = pixelScale
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.text("Drag to select a screen area. Escape cancels.", "拖动选择屏幕区域，按 Esc 取消。"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        start = convert(event.locationInWindow, from: nil)
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let end = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                           width: abs(start.x - end.x), height: abs(start.y - end.y)).intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        guard let selection,
              (try? CaptureRegion(appKitRect: selection, displaySize: bounds.size, pixelScale: pixelScale)) != nil else { return }
        onSelection?(selection)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onSelection?(nil) }
        else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onSelection?(nil) }
    override func rightMouseDown(with event: NSEvent) { onSelection?(nil) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        if let selection, !selection.isEmpty {
            NSGraphicsContext.current?.cgContext.clear(selection)
            NSColor.white.setStroke()
            let outline = NSBezierPath(rect: selection.insetBy(dx: 1, dy: 1))
            outline.lineWidth = 2
            outline.stroke()
            if let region = try? CaptureRegion(appKitRect: selection, displaySize: bounds.size, pixelScale: pixelScale) {
                drawLabel("\(Int(region.pixelSize.width)) × \(Int(region.pixelSize.height)) px",
                          at: CGPoint(x: max(8, min(selection.minX, bounds.width - 180)),
                                      y: max(8, min(selection.maxY + 8, bounds.height - 85))))
            }
        }
        drawLabel(L10n.text("Drag an area to record · Release to confirm · Esc to cancel",
                            "拖动框选录制区域 · 松开鼠标确认 · Esc 取消"),
                  at: CGPoint(x: 20, y: bounds.height - 60))
    }

    private func drawLabel(_ text: String, at point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium),
                                                        .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: CGRect(origin: point, size: CGSize(width: size.width + 20, height: size.height + 14)),
                     xRadius: 8, yRadius: 8).fill()
        (text as NSString).draw(at: CGPoint(x: point.x + 10, y: point.y + 7), withAttributes: attributes)
    }
}
