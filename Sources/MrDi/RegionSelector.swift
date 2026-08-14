import AppKit

/// Выделение прямоугольника на экране — как в системном скриншоте.
/// Оверлей растягивается на все экраны, чтобы область можно было тянуть где угодно.
@MainActor
final class RegionSelector {
    static let shared = RegionSelector()

    private var overlays: [NSWindow] = []
    private var completion: ((NSRect, NSScreen)?) -> Void = { _ in }
    private(set) var isActive = false

    private init() {}

    func begin(completion: @escaping ((NSRect, NSScreen)?) -> Void) {
        guard !isActive else { return }
        isActive = true
        self.completion = completion

        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame,
                                  styleMask: [.borderless],
                                  backing: .buffered, defer: false, screen: screen)
            window.level = .screenSaver
            window.backgroundColor = NSColor.black.withAlphaComponent(0.22)
            window.isOpaque = false
            window.ignoresMouseEvents = false
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.contentView = SelectionView(screen: screen)
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            overlays.append(window)
        }
        overlays.first?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.crosshair.push()
    }

    fileprivate func finish(rect: NSRect?, screen: NSScreen?) {
        guard isActive else { return }
        isActive = false
        NSCursor.pop()
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()

        if let rect, let screen, rect.width > 6, rect.height > 6 {
            completion((rect, screen))
        } else {
            completion(nil)
        }
        completion = { _ in }
    }
}

private final class SelectionView: NSView {
    private let screenRef: NSScreen
    private var origin: NSPoint?
    private var currentRect: NSRect = .zero

    init(screen: NSScreen) {
        self.screenRef = screen
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        origin = convert(event.locationInWindow, from: nil)
        currentRect = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin else { return }
        let point = convert(event.locationInWindow, from: nil)
        currentRect = NSRect(x: min(origin.x, point.x), y: min(origin.y, point.y),
                             width: abs(point.x - origin.x), height: abs(point.y - origin.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard origin != nil else {
            RegionSelector.shared.finish(rect: nil, screen: nil)
            return
        }
        // из координат окна — в глобальные, которыми оперирует захват экрана
        let global = NSRect(x: currentRect.minX + screenRef.frame.minX,
                            y: currentRect.minY + screenRef.frame.minY,
                            width: currentRect.width, height: currentRect.height)
        RegionSelector.shared.finish(rect: global, screen: screenRef)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {   // Esc
            RegionSelector.shared.finish(rect: nil, screen: nil)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard currentRect.width > 0, currentRect.height > 0 else { return }

        // «дырка» в затемнении: видно ровно то, что попадёт в захват
        NSColor.clear.setFill()
        currentRect.fill(using: .copy)

        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: currentRect.insetBy(dx: -0.5, dy: -0.5))
        path.lineWidth = 1.5
        path.stroke()

        let label = "\(Int(currentRect.width)) × \(Int(currentRect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = label.size(withAttributes: attrs)
        let badge = NSRect(x: currentRect.minX, y: currentRect.maxY + 6,
                           width: size.width + 10, height: size.height + 5)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
        label.draw(at: NSPoint(x: badge.minX + 5, y: badge.minY + 2), withAttributes: attrs)
    }
}
