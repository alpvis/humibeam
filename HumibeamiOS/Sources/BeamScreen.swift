import SwiftUI
import AVFoundation
import CoreMedia

/// MacBeam-Viewer: dein Mac-Bildschirm auf dem iPhone/iPad.
/// Gesten: 1 Finger bewegt den Zeiger (Tap = Klick, Doppeltipp = Doppelklick,
/// langes Drücken = Drag), 2 Finger = Scrollen, 2-Finger-Tap = Rechtsklick.
/// Tastatur über den ⌨️-Knopf; ⌘-Kürzel über die Leiste.
struct BeamScreen: View {
    @Environment(\.dismiss) private var dismiss
    let host: SSHHost

    @StateObject private var client = BeamClient()
    @State private var keyboardVisible = false
    @FocusState private var keyboardFocused: Bool
    @State private var typedBuffer = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            BeamVideoView(client: client)
                .ignoresSafeArea()

            if !client.connected {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(client.status)
                        .font(.caption).foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }
            }

            VStack {
                HStack {
                    Button {
                        client.disconnect()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2).foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                    Text(client.macName.isEmpty ? host.displayName : client.macName)
                        .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Button {
                        keyboardVisible.toggle()
                        keyboardFocused = keyboardVisible
                    } label: {
                        Image(systemName: "keyboard")
                            .font(.title3).foregroundStyle(.white.opacity(0.7))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                Spacer()

                if keyboardVisible {
                    beamKeyBar
                    // Unsichtbares Feld fängt die Tastatur ein; jedes Zeichen geht zum Mac.
                    TextField("", text: $typedBuffer)
                        .focused($keyboardFocused)
                        .opacity(0.02)
                        .frame(height: 1)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: typedBuffer) { _, value in
                            guard !value.isEmpty else { return }
                            client.send(BeamInput(kind: .text, text: value))
                            typedBuffer = ""
                        }
                        .onSubmit {
                            client.send(BeamInput(kind: .key, keyName: "return"))
                            keyboardFocused = true
                        }
                }
            }
        }
        .statusBarHidden()
        .onAppear { client.connect(host: host) }
        .onDisappear { client.disconnect() }
    }

    private var beamKeyBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                beamKey("esc") { client.send(BeamInput(kind: .key, keyName: "esc")) }
                beamKey("tab") { client.send(BeamInput(kind: .key, keyName: "tab")) }
                beamKey("⌫") { client.send(BeamInput(kind: .key, keyName: "backspace")) }
                beamKey("⌘Space") { client.send(BeamInput(kind: .key, keyName: "space", command: true)) }
                beamKey("⌘C") { client.send(BeamInput(kind: .key, keyName: "c", command: true)) }
                beamKey("⌘V") { client.send(BeamInput(kind: .key, keyName: "v", command: true)) }
                beamKey("⌘Z") { client.send(BeamInput(kind: .key, keyName: "z", command: true)) }
                beamKey("⌘Q") { client.send(BeamInput(kind: .key, keyName: "q", command: true)) }
                ForEach(["up", "down", "left", "right"], id: \.self) { dir in
                    beamKey(dir == "up" ? "↑" : dir == "down" ? "↓" : dir == "left" ? "←" : "→") {
                        client.send(BeamInput(kind: .key, keyName: dir))
                    }
                }
            }
            .padding(.horizontal, 10)
        }
        .padding(.vertical, 6)
        .background(.black.opacity(0.6))
    }

    private func beamKey(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.monospaced().weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(.white.opacity(0.15)))
                .foregroundStyle(.white)
        }
    }
}

/// Rendert den H.264-Stream (AVSampleBufferDisplayLayer) und übersetzt Touch-Gesten in BeamInput.
struct BeamVideoView: UIViewRepresentable {
    @ObservedObject var client: BeamClient

    func makeUIView(context: Context) -> BeamVideoUIView {
        let view = BeamVideoUIView()
        view.client = client
        client.onSample = { [weak view] sample in
            view?.enqueue(sample)
        }
        return view
    }

    func updateUIView(_ view: BeamVideoUIView, context: Context) {}
}

final class BeamVideoUIView: UIView {
    weak var client: BeamClient?
    private let displayLayer = AVSampleBufferDisplayLayer()
    /// Letzte bekannte Zeigerposition (normalisiert), Basis für relative Bewegungen.
    private var pointer = CGPoint(x: 0.5, y: 0.5)
    private var dragActive = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        layer.addSublayer(displayLayer)
        isMultipleTouchEnabled = true
        setupGestures()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer.frame = bounds
    }

    /// Seitenverhältnis des Streams — für die Touch→Bild-Koordinaten (aspect-fit).
    private var videoSize: CGSize = .zero

    func enqueue(_ sample: CMSampleBuffer) {
        if let desc = CMSampleBufferGetFormatDescription(sample) {
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            videoSize = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
        }
        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.sampleBufferRenderer.enqueue(sample)
    }

    /// Sichtbares Bild-Rechteck bei .resizeAspect (Letterbox herausrechnen).
    private var fittedVideoRect: CGRect {
        guard videoSize.width > 0, videoSize.height > 0, !bounds.isEmpty else { return bounds }
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2,
                      y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private func setupGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)

        let twoPan = UIPanGestureRecognizer(target: self, action: #selector(twoPan(_:)))
        twoPan.minimumNumberOfTouches = 2
        twoPan.maximumNumberOfTouches = 2
        addGestureRecognizer(twoPan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
        addGestureRecognizer(tap)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        tap.require(toFail: doubleTap)

        let twoTap = UITapGestureRecognizer(target: self, action: #selector(twoFingerTap(_:)))
        twoTap.numberOfTouchesRequired = 2
        addGestureRecognizer(twoTap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:)))
        longPress.minimumPressDuration = 0.4
        addGestureRecognizer(longPress)
    }

    /// Touch-Punkt → normalisierte Bildkoordinate (aspect-fit Letterboxing herausrechnen).
    private func normalized(_ point: CGPoint) -> CGPoint {
        let videoRect = fittedVideoRect
        let x = (point.x - videoRect.minX) / max(videoRect.width, 1)
        let y = (point.y - videoRect.minY) / max(videoRect.height, 1)
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    @objc private func onePan(_ g: UIPanGestureRecognizer) {
        let p = normalized(g.location(in: self))
        pointer = p
        if dragActive {
            client?.send(BeamInput(kind: .dragMove, x: p.x, y: p.y))
        } else {
            client?.send(BeamInput(kind: .move, x: p.x, y: p.y))
        }
        if g.state == .ended || g.state == .cancelled, dragActive {
            dragActive = false
            client?.send(BeamInput(kind: .dragEnd, x: p.x, y: p.y))
        }
    }

    @objc private func twoPan(_ g: UIPanGestureRecognizer) {
        let translation = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        client?.send(BeamInput(kind: .scroll, x: pointer.x, y: pointer.y,
                               dx: translation.x, dy: translation.y))
    }

    @objc private func tap(_ g: UITapGestureRecognizer) {
        let p = normalized(g.location(in: self))
        pointer = p
        client?.send(BeamInput(kind: .click, x: p.x, y: p.y))
    }

    @objc private func doubleTap(_ g: UITapGestureRecognizer) {
        let p = normalized(g.location(in: self))
        client?.send(BeamInput(kind: .doubleClick, x: p.x, y: p.y))
    }

    @objc private func twoFingerTap(_ g: UITapGestureRecognizer) {
        let p = normalized(g.location(in: self))
        client?.send(BeamInput(kind: .rightClick, x: p.x, y: p.y))
    }

    @objc private func longPress(_ g: UILongPressGestureRecognizer) {
        let p = normalized(g.location(in: self))
        switch g.state {
        case .began:
            dragActive = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            client?.send(BeamInput(kind: .dragStart, x: p.x, y: p.y))
        case .changed:
            client?.send(BeamInput(kind: .dragMove, x: p.x, y: p.y))
        case .ended, .cancelled:
            dragActive = false
            client?.send(BeamInput(kind: .dragEnd, x: p.x, y: p.y))
        default: break
        }
    }
}
