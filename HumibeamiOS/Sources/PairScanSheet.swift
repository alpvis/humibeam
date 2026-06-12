import SwiftUI
import AVFoundation

/// „Mac koppeln": scannt den QR-Code aus der Mac-App (Einstellungen → Konto → iPhone koppeln)
/// und legt sofort ein fertiges Server-Profil mit gekoppeltem Schlüssel an.
struct PairScanSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var error: String?
    @State private var manualCode = ""
    @State private var done: SSHHost?

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                if let done {
                    ContentUnavailableView {
                        Label("Gekoppelt!", systemImage: "checkmark.circle.fill")
                    } description: {
                        Text("\(done.displayName) ist eingerichtet. Tippe in der Serverliste darauf — du musst im selben WLAN sein wie dein Mac.")
                    } actions: {
                        Button("Fertig") { dismiss() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    QRScannerView { code in
                        handle(code)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .frame(maxHeight: 360)
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.cyan.opacity(0.5)))

                    Text("Am Mac: Einstellungen → Konto → iPhone koppeln, dann den QR-Code hierher halten.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }

                    DisclosureGroup("Code manuell einfügen") {
                        TextField("humibeam-pair:…", text: $manualCode, axis: .vertical)
                            .font(.caption.monospaced())
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Übernehmen") { handle(manualCode) }
                            .disabled(manualCode.isEmpty)
                    }
                    .font(.caption)
                }
            }
            .padding()
            .navigationTitle("Mac koppeln")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
    }

    private func handle(_ code: String) {
        guard done == nil else { return }
        guard let payload = MacPairingPayload.parse(code) else {
            error = "Kein gültiger humibeam-Kopplungs-Code."
            return
        }
        guard let raw = payload.rawKey else {
            error = "Schlüssel im Code ist beschädigt."
            return
        }
        var host = SSHHost()
        host.name = "Mac · \(payload.host.replacingOccurrences(of: ".local", with: ""))"
        host.host = payload.host
        host.port = payload.port
        host.username = payload.user
        host.authKind = .pairedKey
        host.useTmux = payload.tmux
        SSHKeyManager.savePairedKey(raw, hostID: host.id.uuidString)
        model.hostStore.add(host)
        done = host
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

/// AVFoundation-QR-Scanner als SwiftUI-View (Kamera-Berechtigung nötig).
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.onCode = onCode
        return vc
    }

    func updateUIViewController(_ vc: ScannerViewController, context: Context) {}

    final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var lastCode = ""

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async { if granted { self?.setup() } }
            }
        }

        private func setup() {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.addSublayer(preview)
            DispatchQueue.global(qos: .userInitiated).async { [session] in
                session.startRunning()
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            view.layer.sublayers?.first { $0 is AVCaptureVideoPreviewLayer }?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            session.stopRunning()
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  obj.type == .qr, let value = obj.stringValue, value != lastCode else { return }
            lastCode = value
            onCode?(value)
        }
    }
}
