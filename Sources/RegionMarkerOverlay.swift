import AppKit
import CoreGraphics

/// Small, mouse-transparent labels for the regions selected in Quartz coordinates.
/// UI methods are called on the main thread, like the rest of the AppKit interface.
final class RegionMarkerOverlay {
    private struct Marker {
        let regionIndex: Int
        let panel: MarkerPanel
        let view: MarkerView
    }

    private var markers: [Marker] = []
    private var activeRegion: Int?
    private var enabled = true

    var windowIDs: [CGWindowID] {
        markers.compactMap { marker in
            let number = marker.panel.windowNumber
            return marker.panel.isVisible && number > 0 ? CGWindowID(number) : nil
        }
    }

    func show(regions: [CGRect], activeRegion: Int?, enabled: Bool = true) {
        precondition(Thread.isMainThread)
        self.activeRegion = activeRegion
        self.enabled = enabled

        // NSScreen.main may be the screen containing the currently focused window.
        // The first screen, in contrast, defines Quartz's global coordinate origin.
        let primaryTop = NSScreen.screens.first?.frame.maxY
            ?? CGDisplayBounds(CGMainDisplayID()).height
        let validRegions = regions.enumerated().filter { _, rect in
            rect.origin.x.isFinite && rect.origin.y.isFinite
                && rect.width.isFinite && rect.height.isFinite
                && rect.width > 0 && rect.height > 0
        }
        let oldMarkers = Dictionary(uniqueKeysWithValues: markers.map { ($0.regionIndex, $0) })
        let wantedIndices = Set(validRegions.map { $0.offset })
        for marker in markers where !wantedIndices.contains(marker.regionIndex) {
            marker.panel.orderOut(nil)
        }

        markers = validRegions.map { index, quartzRect in
            let frame = CGRect(x: quartzRect.minX,
                               y: primaryTop - quartzRect.maxY,
                               width: quartzRect.width,
                               height: quartzRect.height)
            let marker = oldMarkers[index] ?? makeMarker(regionIndex: index, frame: frame)
            marker.panel.setFrame(frame, display: false)
            marker.view.active = index == activeRegion
            marker.view.enabled = enabled
            marker.view.needsDisplay = true
            // A nonactivating panel can be ordered in front without changing the
            // key window, target application, or keyboard focus.
            if !marker.panel.isVisible {
                marker.panel.orderFrontRegardless()
            }
            return marker
        }
    }

    func setActive(_ region: Int?) {
        precondition(Thread.isMainThread)
        guard activeRegion != region else { return }
        activeRegion = region
        for marker in markers {
            marker.view.active = marker.regionIndex == region
            marker.view.needsDisplay = true
        }
    }

    func hide() {
        precondition(Thread.isMainThread)
        for marker in markers { marker.panel.orderOut(nil) }
        markers.removeAll()
        activeRegion = nil
    }

    private func makeMarker(regionIndex: Int, frame: CGRect) -> Marker {
        let panel = MarkerPanel(contentRect: frame,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered,
                                defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        let view = MarkerView(frame: CGRect(origin: .zero, size: frame.size), number: regionIndex + 1)
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        return Marker(regionIndex: regionIndex, panel: panel, view: view)
    }
}

private final class MarkerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class MarkerView: NSView {
    private let number: Int
    var active = false
    var enabled = true

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init(frame: CGRect, number: Int) {
        self.number = number
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let isActive = active && enabled
        let brightness: CGFloat = enabled ? 1 : 0.52
        let color = isActive ? NSColor(calibratedRed: 0.05, green: 0.94, blue: 0.98, alpha: 1)
                             : NSColor(calibratedRed: 1, green: 0.68, blue: 0.18, alpha: 1)
        let lineWidth: CGFloat = min(isActive ? 3 : 1.5, min(bounds.width, bounds.height) / 2)
        let outline = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let radius = min(6, min(outline.width, outline.height) / 4)
        let path = NSBezierPath(roundedRect: outline, xRadius: radius, yRadius: radius)
        color.withAlphaComponent((isActive ? 0.1 : 0.025) * brightness).setFill()
        path.fill()
        color.withAlphaComponent((isActive ? 1 : 0.72) * brightness).setStroke()
        path.lineWidth = lineWidth
        path.stroke()

        // Keep the badge inside the selected area. It scales down for narrow
        // buttons, and grows only to 30 points so large regions stay unobscured.
        let side = min(30, min(max(14, bounds.height * 0.72),
                              min(bounds.width, bounds.height) - 4))
        guard side >= 5 else { return }
        let margin = min(4, max(1, (min(bounds.width, bounds.height) - side) / 2))
        let badge = CGRect(x: margin, y: margin, width: side, height: side)
        let badgePath = NSBezierPath(roundedRect: badge,
                                    xRadius: min(6, side / 4),
                                    yRadius: min(6, side / 4))
        NSColor.black.withAlphaComponent((isActive ? 0.88 : 0.72) * brightness).setFill()
        badgePath.fill()
        color.withAlphaComponent((isActive ? 1 : 0.88) * brightness).setStroke()
        badgePath.lineWidth = isActive ? 1.5 : 1
        badgePath.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let font = NSFont.monospacedDigitSystemFont(ofSize: side * 0.7, weight: .heavy)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: (isActive ? color : NSColor.white).withAlphaComponent(brightness),
            .paragraphStyle: paragraph
        ]
        if isActive {
            let glow = NSShadow()
            glow.shadowColor = color.withAlphaComponent(0.7)
            glow.shadowBlurRadius = 4
            glow.shadowOffset = .zero
            attributes[.shadow] = glow
        }
        let label = "\(number)" as NSString
        let labelHeight = label.size(withAttributes: attributes).height
        label.draw(in: CGRect(x: badge.minX, y: badge.midY - labelHeight / 2,
                              width: badge.width, height: labelHeight),
                   withAttributes: attributes)
    }
}
