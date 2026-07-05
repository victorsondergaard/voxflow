import AppKit

/// Floating, soft rounded "pill" that appears while you dictate.
/// Listening: waveform bars bounce with your voice (the pill also gently
/// swells with volume). Processing: the same bars play a rolling wave as a
/// loading animation until your text is inserted.
final class HUDController {
    private let panel: NSPanel
    private let effect: NSVisualEffectView
    private let barsView: WaveBarsView
    private static let size = NSSize(width: 220, height: 56)

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: HUDController.size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: HUDController.size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = HUDController.size.height / 2
        effect.layer?.masksToBounds = true

        barsView = WaveBarsView(frame: NSRect(x: 26, y: 10,
                                              width: HUDController.size.width - 52,
                                              height: HUDController.size.height - 20))
        barsView.autoresizingMask = [.width, .height]
        effect.addSubview(barsView)
        panel.contentView = effect
        panel.alphaValue = 0
    }

    func showListening() {
        barsView.mode = .listening
        position()
        panel.orderFrontRegardless()
        fade(to: 1)
    }

    func showProcessing() {
        barsView.mode = .processing
        if !panel.isVisible {
            position()
            panel.orderFrontRegardless()
        }
        fade(to: 1)
    }

    /// level 0…1 — drives the bars and a gentle "breathing" of the pill.
    func setLevel(_ level: Float) {
        barsView.push(level: level)
        let scale = 1.0 + CGFloat(min(max(level, 0), 1)) * 0.04
        if let layer = effect.layer {
            layer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale)
                .translatedBy(x: HUDController.size.width * (1 - scale) / 2,
                              y: HUDController.size.height * (1 - scale) / 2))
        }
    }

    func hide() {
        fade(to: 0) { [weak self] in
            self?.panel.orderOut(nil)
            self?.effect.layer?.setAffineTransform(.identity)
        }
    }

    /// Bottom-center of the screen the user is working on (the mouse's screen).
    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let origin = NSPoint(x: frame.midX - HUDController.size.width / 2,
                             y: frame.minY + 84)
        panel.setFrameOrigin(origin)
    }

    private func fade(to alpha: CGFloat, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = alpha
        }, completionHandler: completion)
    }
}

/// Rounded waveform bars. Listening: heights follow the mic level history,
/// eased for a smooth bounce. Processing: a phase-shifted sine wave rolls
/// across the bars (the loading animation).
final class WaveBarsView: NSView {
    enum Mode { case listening, processing }

    var mode: Mode = .listening

    private let barCount = 14
    private var targets: [CGFloat]
    private var displayed: [CGFloat]
    private var phase: CGFloat = 0
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        targets = Array(repeating: 0.1, count: barCount)
        displayed = Array(repeating: 0.1, count: barCount)
        super.init(frame: frameRect)
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit {
        timer?.invalidate()
    }

    func push(level: Float) {
        let clamped = CGFloat(min(max(level, 0), 1))
        targets.removeFirst()
        targets.append(max(0.1, clamped))
    }

    private func tick() {
        switch mode {
        case .listening:
            for i in 0..<barCount {
                displayed[i] += (targets[i] - displayed[i]) * 0.45
            }
        case .processing:
            phase += 0.22
            for i in 0..<barCount {
                let s = sin(phase - CGFloat(i) * 0.55)
                displayed[i] = 0.16 + 0.34 * (s + 1) / 2
            }
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let barWidth = bounds.width / CGFloat(barCount * 2 - 1)
        let color: NSColor = mode == .listening ? .controlAccentColor : .secondaryLabelColor
        color.setFill()
        for i in 0..<barCount {
            let height = max(bounds.height * displayed[i], barWidth)
            let x = CGFloat(i) * barWidth * 2
            let y = (bounds.height - height) / 2
            let rect = NSRect(x: x, y: y, width: barWidth, height: height)
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }
}
