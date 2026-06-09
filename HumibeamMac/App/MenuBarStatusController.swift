import AppKit

enum MenuBarStatus: Equatable {
    case idle
    case recording(WorkflowType)
    case processing(WorkflowType)
    case success(WorkflowType?)
    case error(WorkflowType?)
}

@MainActor
final class MenuBarStatusController {
    private weak var button: NSStatusBarButton?
    private var animationTimer: Timer?
    private var animationFrame = 0
    private var currentStatus: MenuBarStatus = .idle

    func attach(to button: NSStatusBarButton) {
        self.button = button
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        renderCurrentStatus()
    }

    func update(to status: MenuBarStatus) {
        currentStatus = status
        animationFrame = 0
        configureAnimationIfNeeded()
        renderCurrentStatus()
    }

    private func configureAnimationIfNeeded() {
        stopAnimation()
        switch currentStatus {
        case .recording:
            startAnimation(interval: 0.5)
        case .processing:
            startAnimation(interval: 0.22)
        default:
            break
        }
    }

    private func startAnimation(interval: TimeInterval) {
        animationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        RunLoop.main.add(animationTimer!, forMode: .common)
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func tick() {
        animationFrame = (animationFrame + 1) % 4
        renderCurrentStatus()
    }

    private func renderCurrentStatus() {
        guard let button else { return }
        button.image = MenuBarStatusIconRenderer.makeImage(for: currentStatus, frame: animationFrame)
        button.toolTip = tooltip(for: currentStatus)
    }

    private func tooltip(for status: MenuBarStatus) -> String {
        switch status {
        case .idle:
            return "Humibeam ist bereit"
        case .recording(let type):
            return "\(type.displayName): Aufnahme läuft"
        case .processing(let type):
            return "\(type.displayName): Verarbeitung läuft"
        case .success(let type):
            return type.map { "\($0.displayName): Fertig" } ?? "Humibeam: Fertig"
        case .error(let type):
            return type.map { "\($0.displayName): Fehler" } ?? "Humibeam: Fehler"
        }
    }

    deinit {
        animationTimer?.invalidate()
    }
}

/// Zeichnet das farbige humiqa-Logo in der Menueleiste, mit dezentem Status-Punkt.
private enum MenuBarStatusIconRenderer {
    static func makeImage(for status: MenuBarStatus, frame: Int) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let logo = NSImage(named: "menubar_icon")
        let image = NSImage(size: size, flipped: false) { bounds in
            logo?.draw(in: bounds, from: .zero, operation: .sourceOver,
                       fraction: logoOpacity(for: status, frame: frame))
            if let color = dotColor(for: status, frame: frame) {
                drawStatusDot(color: color, in: bounds)
            }
            return true
        }
        image.isTemplate = false
        image.size = size
        return image
    }

    private static func logoOpacity(for status: MenuBarStatus, frame: Int) -> CGFloat {
        switch status {
        case .processing:
            let pulse: [CGFloat] = [1.0, 0.82, 0.66, 0.82]
            return pulse[frame % pulse.count]
        default:
            return 1.0
        }
    }

    private static func dotColor(for status: MenuBarStatus, frame: Int) -> NSColor? {
        switch status {
        case .idle:
            return nil
        case .recording:
            let a: [CGFloat] = [1.0, 0.45, 1.0, 0.45]
            return NSColor.systemRed.withAlphaComponent(a[frame % a.count])
        case .processing:
            let a: [CGFloat] = [0.55, 0.85, 1.0, 0.75]
            return NSColor(srgbRed: 0.055, green: 0.647, blue: 0.914, alpha: a[frame % a.count])
        case .success:
            return NSColor.systemGreen
        case .error:
            return NSColor.systemOrange
        }
    }

    private static func drawStatusDot(color: NSColor, in bounds: CGRect) {
        let d: CGFloat = 7.5
        let rect = CGRect(x: bounds.maxX - d, y: bounds.minY, width: d, height: d)
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -1.0, dy: -1.0))
        NSColor.white.setFill()
        ring.fill()
        let dot = NSBezierPath(ovalIn: rect)
        color.setFill()
        dot.fill()
    }
}
