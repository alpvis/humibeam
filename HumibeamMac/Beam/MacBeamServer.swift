import Foundation
import AppKit
import Network
import ScreenCaptureKit
import VideoToolbox
import CryptoKit
import Observation

/// MacBeam: streamt den Mac-Bildschirm (ScreenCaptureKit → H.264) an die iPhone-App und
/// führt deren Eingaben als CGEvents aus. Lauscht auf TCP :8765 (Bonjour `_macbeam._tcp`),
/// alle Pakete E2E-verschlüsselt mit dem Pairing-beamSecret.
/// Berechtigungen: Bildschirmaufnahme (Capture) + Bedienungshilfen (Eingabe) — einmalig erteilen.
@Observable
@MainActor
final class MacBeamServer: NSObject {
    static let port: UInt16 = 8765

    private(set) var running = false
    private(set) var clientConnected = false
    private(set) var lastError: String?

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var assembler = BeamFrameAssembler()
    @ObservationIgnored private var key: SymmetricKey?
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var encoder: VTCompressionSession?
    @ObservationIgnored private var screenSize = CGSize(width: 1, height: 1)
    @ObservationIgnored private var sentConfig = false
    @ObservationIgnored private var dragging = false

    func start() {
        guard !running else { return }
        guard let secret = SSHKeyManager.loadBeamSecret() else {
            lastError = "Erst ein iPhone koppeln (Einstellungen → Konto) — dabei entsteht das MacBeam-Geheimnis."
            return
        }
        key = BeamCrypto.key(fromSecret: secret)
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
            listener.service = NWListener.Service(name: Host.current().localizedName ?? "Mac",
                                                  type: "_macbeam._tcp")
            listener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            listener.start(queue: .main)
            self.listener = listener
            running = true
            lastError = nil
            startRelayStandby(secret: secret)
        } catch {
            lastError = "Listener fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel(); listener = nil
        relayStandby?.cancel(); relayStandby = nil
        relayRetry?.invalidate(); relayRetry = nil
        disconnectClient()
        running = false
    }

    // MARK: - Beam-Tunnel (unterwegs): Standby-Verbindung zum Rendezvous-Server.
    // Sobald dort ein iPhone andockt, fließen dieselben E2E-Pakete durch den Tunnel.

    @ObservationIgnored private var relayStandby: NWConnection?
    @ObservationIgnored private var relayRetry: Timer?

    private func startRelayStandby(secret: Data) {
        guard UserDefaults.standard.object(forKey: "beam.relay.enabled") as? Bool ?? true else { return }
        let relay = UserDefaults.standard.string(forKey: "beam.relay") ?? BeamCrypto.defaultRelay
        let parts = relay.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]) else { return }
        let conn = NWConnection(host: NWEndpoint.Host(String(parts[0])),
                                port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        relayStandby = conn
        let channel = BeamCrypto.channelID(fromSecret: secret)
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    let hello = "{\"role\":\"mac\",\"channel\":\"\(channel)\"}\n"
                    conn.send(content: Data(hello.utf8), completion: .contentProcessed { _ in })
                    self.awaitRelayClient(conn, secret: secret)
                case .failed, .cancelled:
                    if self.relayStandby === conn { self.scheduleRelayRetry(secret: secret) }
                default: break
                }
            }
        }
        conn.start(queue: .main)
    }

    /// Erste Daten auf der Standby-Leitung = ein iPhone ist da → Leitung wird zur
    /// Client-Verbindung, und eine neue Standby-Leitung geht auf.
    private func awaitRelayClient(_ conn: NWConnection, secret: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.connection?.cancel()
                    self.connection = conn
                    self.assembler = BeamFrameAssembler()
                    self.sentConfig = false
                    self.clientConnected = true
                    for frame in self.assembler.append(data) { self.handle(frame) }
                    self.sendHello()
                    await self.startCapture()
                    self.receiveLoop(conn)
                    if self.relayStandby === conn { self.relayStandby = nil }
                    self.startRelayStandby(secret: secret)
                } else if done || error != nil {
                    if self.relayStandby === conn { self.scheduleRelayRetry(secret: secret) }
                } else {
                    self.awaitRelayClient(conn, secret: secret)
                }
            }
        }
    }

    private func scheduleRelayRetry(secret: Data) {
        relayStandby = nil
        relayRetry?.invalidate()
        relayRetry = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.running else { return }
                self.startRelayStandby(secret: secret)
            }
        }
    }

    private func disconnectClient() {
        connection?.cancel(); connection = nil
        clientConnected = false
        stopCapture()
    }

    private func accept(_ conn: NWConnection) {
        // Nur ein Client gleichzeitig — der neue gewinnt.
        connection?.cancel()
        connection = conn
        assembler = BeamFrameAssembler()
        sentConfig = false
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.clientConnected = true
                    self?.sendHello()
                    await self?.startCapture()
                case .failed, .cancelled:
                    if self?.connection === conn { self?.disconnectClient() }
                default: break
                }
            }
        }
        receiveLoop(conn)
        conn.start(queue: .main)
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { return }
                if let data {
                    for frame in self.assembler.append(data) {
                        self.handle(frame)
                    }
                }
                if done || error != nil {
                    if self.connection === conn { self.disconnectClient() }
                } else {
                    self.receiveLoop(conn)
                }
            }
        }
    }

    private func handle(_ frame: Data) {
        guard let key, let (type, payload) = BeamCrypto.open(frame, key: key) else { return }
        switch type {
        case .input:
            if let input = try? JSONDecoder().decode(BeamInput.self, from: payload) {
                inject(input)
            }
        default:
            break
        }
    }

    private func send(_ type: BeamPacketType, _ payload: Data) {
        guard let key, let conn = connection,
              let packet = BeamCrypto.seal(type: type, payload: payload, key: key) else { return }
        conn.send(content: packet, completion: .contentProcessed { _ in })
    }

    private func sendHello() {
        let hello: [String: Any] = ["v": 1, "name": Host.current().localizedName ?? "Mac",
                                    "width": screenSize.width, "height": screenSize.height]
        if let data = try? JSONSerialization.data(withJSONObject: hello) {
            send(.hello, data)
        }
    }

    // MARK: - Capture (ScreenCaptureKit) + H.264 (VideoToolbox)

    private func startCapture() async {
        stopCapture()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else {
                lastError = "Kein Display gefunden."; return
            }
            screenSize = CGSize(width: display.width, height: display.height)
            sendHello()

            // Auf max. 1728 px Breite herunterskalieren — schnell und auf dem iPhone scharf genug.
            let scale = min(1.0, 1728.0 / Double(display.width))
            let w = Int(Double(display.width) * scale) & ~1
            let h = Int(Double(display.height) * scale) & ~1

            let config = SCStreamConfiguration()
            config.width = w
            config.height = h
            config.minimumFrameInterval = CMTime(value: 1, timescale: 20)
            config.queueDepth = 3
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.showsCursor = true

            makeEncoder(width: w, height: h)

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
            try await stream.startCapture()
            self.stream = stream
            lastError = nil
        } catch {
            lastError = "Bildschirmaufnahme fehlgeschlagen: \(error.localizedDescription) — Berechtigung unter Systemeinstellungen → Datenschutz → Bildschirmaufnahme erteilen."
        }
    }

    private func stopCapture() {
        if let stream {
            Task { try? await stream.stopCapture() }
        }
        stream = nil
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        encoder = nil
    }

    private func makeEncoder(width: Int, height: Int) {
        var session: VTCompressionSession?
        VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                   codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                   imageBufferAttributes: nil, compressedDataAllocator: nil,
                                   outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: 6_000_000 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: 60 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)
        encoder = session
    }

    nonisolated private func encode(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        Task { @MainActor in
            guard let encoder = self.encoder else { return }
            VTCompressionSessionEncodeFrame(encoder, imageBuffer: pixelBuffer,
                                            presentationTimeStamp: time, duration: .invalid,
                                            frameProperties: nil, infoFlagsOut: nil) { [weak self] _, _, sample in
                guard let sample else { return }
                Task { @MainActor in self?.ship(sample) }
            }
        }
    }

    private func ship(_ sample: CMSampleBuffer) {
        guard connection != nil else { return }
        // SPS/PPS einmalig (und bei jedem Keyframe zur Sicherheit) vorweg schicken.
        let keyframe = !((CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]])?
            .first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        if keyframe || !sentConfig {
            if let desc = CMSampleBufferGetFormatDescription(sample),
               let config = Self.parameterSets(from: desc) {
                send(.videoConfig, config)
                sentConfig = true
            }
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer else { return }
        var payload = Data([keyframe ? 1 : 0])
        payload.append(Data(bytes: pointer, count: length))   // AVCC: länge-präfixierte NALUs
        send(.videoFrame, payload)
    }

    private static func parameterSets(from desc: CMFormatDescription) -> Data? {
        var spsPointer: UnsafePointer<UInt8>?
        var spsLength = 0
        var ppsPointer: UnsafePointer<UInt8>?
        var ppsLength = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            desc, parameterSetIndex: 0, parameterSetPointerOut: &spsPointer,
            parameterSetSizeOut: &spsLength, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
              CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            desc, parameterSetIndex: 1, parameterSetPointerOut: &ppsPointer,
            parameterSetSizeOut: &ppsLength, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
              let spsPointer, let ppsPointer else { return nil }
        var out = Data()
        var spsLen = UInt16(spsLength).bigEndian
        withUnsafeBytes(of: &spsLen) { out.append(contentsOf: $0) }
        out.append(Data(bytes: spsPointer, count: spsLength))
        var ppsLen = UInt16(ppsLength).bigEndian
        withUnsafeBytes(of: &ppsLen) { out.append(contentsOf: $0) }
        out.append(Data(bytes: ppsPointer, count: ppsLength))
        return out
    }

    // MARK: - Eingabe-Injektion (CGEvent — braucht Bedienungshilfen-Berechtigung)

    private func inject(_ input: BeamInput) {
        let point = CGPoint(x: input.x * screenSize.width, y: input.y * screenSize.height)
        switch input.kind {
        case .move:
            post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                         mouseCursorPosition: point, mouseButton: .left))
        case .click:
            post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                         mouseCursorPosition: point, mouseButton: .left))
            post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                         mouseCursorPosition: point, mouseButton: .left))
        case .doubleClick:
            for _ in 0..<2 {
                let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                   mouseCursorPosition: point, mouseButton: .left)
                down?.setIntegerValueField(.mouseEventClickState, value: 2)
                post(down)
                let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                 mouseCursorPosition: point, mouseButton: .left)
                up?.setIntegerValueField(.mouseEventClickState, value: 2)
                post(up)
            }
        case .rightClick:
            post(CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown,
                         mouseCursorPosition: point, mouseButton: .right))
            post(CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp,
                         mouseCursorPosition: point, mouseButton: .right))
        case .dragStart:
            dragging = true
            post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                         mouseCursorPosition: point, mouseButton: .left))
        case .dragMove:
            post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                         mouseCursorPosition: point, mouseButton: .left))
        case .dragEnd:
            dragging = false
            post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                         mouseCursorPosition: point, mouseButton: .left))
        case .scroll:
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                wheel1: Int32(input.dy), wheel2: Int32(input.dx), wheel3: 0)
            post(event)
        case .text:
            guard let text = input.text else { return }
            for char in text.unicodeScalars {
                let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
                var utf16 = Array(String(char).utf16)
                down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                post(down)
                let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
                up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                post(up)
            }
        case .key:
            guard let name = input.keyName, let code = Self.keyCodes[name] else { return }
            var flags: CGEventFlags = []
            if input.command { flags.insert(.maskCommand) }
            if input.option { flags.insert(.maskAlternate) }
            if input.controlKey { flags.insert(.maskControl) }
            if input.shift { flags.insert(.maskShift) }
            let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
            down?.flags = flags
            post(down)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
            up?.flags = flags
            post(up)
        }
    }

    private func post(_ event: CGEvent?) {
        event?.post(tap: .cghidEventTap)
    }

    private static let keyCodes: [String: CGKeyCode] = [
        "return": 36, "backspace": 51, "esc": 53, "tab": 48, "space": 49,
        "up": 126, "down": 125, "left": 123, "right": 124,
        "a": 0, "c": 8, "v": 9, "x": 7, "z": 6, "q": 12, "w": 13, "t": 17, "f": 3, "s": 1, "r": 15,
    ]
}

// MARK: - SCStreamOutput

extension MacBeamServer: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        encode(pixelBuffer, time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}
