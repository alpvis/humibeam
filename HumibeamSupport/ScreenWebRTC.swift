import Foundation
import ScreenCaptureKit
import CoreMedia
import WebRTC

/// WebRTC-Peer der Kunden-App (Answerer): nimmt den Bildschirm per ScreenCaptureKit auf, speist
/// die Frames in einen WebRTC-Video-Track und nimmt Steuer-Eingaben über den Daten-Kanal entgegen.
/// Der Supporter-Browser ist der Offerer; SDP/ICE laufen über den Signaling-Server.
@MainActor
final class ScreenWebRTC: NSObject {
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    private var pc: RTCPeerConnection?
    private var videoSource: RTCVideoSource?
    private var capturer: RTCVideoCapturer?
    private var stream: SCStream?
    private let injector: RemoteInputInjector

    /// Lokales Signaling rausgeben (SDP-Answer / ICE) — vom SupportSession an den Server gereicht.
    var onLocalSignal: (([String: Any]) -> Void)?
    var onClosed: (() -> Void)?

    init(injector: RemoteInputInjector) { self.injector = injector }

    // MARK: - Verbindung aufbauen (Answerer)

    func start(iceServers: [[String: Any]]) {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = iceServers.compactMap { dict in
            guard let urls = dict["urls"] else { return nil }
            let urlList: [String] = (urls as? [String]) ?? [(urls as? String) ?? ""]
            if let user = dict["username"] as? String, let cred = dict["credential"] as? String {
                return RTCIceServer(urlStrings: urlList, username: user, credential: cred)
            }
            return RTCIceServer(urlStrings: urlList)
        }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        pc = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self)

        let source = Self.factory.videoSource()
        videoSource = source
        capturer = RTCVideoCapturer(delegate: source)
        let track = Self.factory.videoTrack(with: source, trackId: "screen0")
        pc?.add(track, streamIds: ["humibeam-screen"])

        Task { await startCapture() }
    }

    func handleRemoteSignal(_ data: [String: Any]) {
        if let sdp = data["sdp"] as? [String: Any],
           let type = sdp["type"] as? String, let sdpStr = sdp["sdp"] as? String {
            let rtcType: RTCSdpType = type == "offer" ? .offer : (type == "answer" ? .answer : .prAnswer)
            let desc = RTCSessionDescription(type: rtcType, sdp: sdpStr)
            pc?.setRemoteDescription(desc) { [weak self] err in
                guard err == nil, rtcType == .offer else { return }
                Task { @MainActor in self?.makeAnswer() }
            }
        } else if let c = data["candidate"] as? [String: Any], let cand = c["candidate"] as? String {
            let ice = RTCIceCandidate(sdp: cand,
                                      sdpMLineIndex: Int32((c["sdpMLineIndex"] as? Int) ?? 0),
                                      sdpMid: c["sdpMid"] as? String)
            pc?.add(ice) { _ in }
        }
    }

    private func makeAnswer() {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        pc?.answer(for: constraints) { [weak self] sdp, _ in
            guard let self, let sdp else { return }
            self.pc?.setLocalDescription(sdp) { _ in }
            self.onLocalSignal?(["sdp": ["type": "answer", "sdp": sdp.sdp]])
        }
    }

    func stop() {
        Task { if let stream { try? await stream.stopCapture() } }
        stream = nil
        pc?.close(); pc = nil
        videoSource = nil; capturer = nil
    }

    // MARK: - Bildschirm-Capture → WebRTC-Frames

    private func startCapture() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else { return }
            injector.screenSize = CGSize(width: display.width, height: display.height)

            let scale = min(1.0, 1920.0 / Double(display.width))
            let cfg = SCStreamConfiguration()
            cfg.width = Int(Double(display.width) * scale) & ~1
            cfg.height = Int(Double(display.height) * scale) & ~1
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            cfg.queueDepth = 4
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.showsCursor = true

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
            try await stream.startCapture()
            self.stream = stream
        } catch {
            NSLog("Capture-Fehler: \(error.localizedDescription)")
        }
    }
}

// MARK: - RTCPeerConnectionDelegate

extension ScreenWebRTC: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let data: [String: Any] = ["candidate": ["candidate": candidate.sdp,
                                                  "sdpMLineIndex": Int(candidate.sdpMLineIndex),
                                                  "sdpMid": candidate.sdpMid as Any]]
        Task { @MainActor in self.onLocalSignal?(data) }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        Task { @MainActor in dataChannel.delegate = self }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .failed || newState == .closed || newState == .disconnected {
            Task { @MainActor in self.onClosed?() }
        }
    }

    nonisolated func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
}

// MARK: - RTCDataChannelDelegate (Eingaben vom Supporter)

extension ScreenWebRTC: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}
    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let input = try? JSONDecoder().decode(RemoteInput.self, from: buffer.data) else { return }
        Task { @MainActor in self.injector.handle(input) }
    }
}

// MARK: - SCStreamOutput (Frames → WebRTC)

extension ScreenWebRTC: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ts = Int64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1_000_000_000)
        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let frame = RTCVideoFrame(buffer: rtcBuffer, rotation: ._0, timeStampNs: ts)
        Task { @MainActor in
            if let source = self.videoSource, let capturer = self.capturer {
                source.capturer(capturer, didCapture: frame)
            }
        }
    }
}
