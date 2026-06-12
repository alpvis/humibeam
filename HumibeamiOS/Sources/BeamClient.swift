import Foundation
import Network
import CryptoKit
import CoreMedia
import AVFoundation

/// MacBeam-Client: verbindet sich zum Mac (TCP :8765, E2E-verschlüsselt mit dem
/// Pairing-Geheimnis), dekodiert den H.264-Stream zu CMSampleBuffern und schickt Eingaben.
@MainActor
final class BeamClient: ObservableObject {
    @Published private(set) var status = "verbinde…"
    @Published private(set) var connected = false
    @Published private(set) var macName = ""

    /// Dekodierte Frames für den AVSampleBufferDisplayLayer.
    var onSample: ((CMSampleBuffer) -> Void)?

    private var connection: NWConnection?
    private var assembler = BeamFrameAssembler()
    private var key: SymmetricKey?
    private var formatDescription: CMVideoFormatDescription?

    func connect(host: SSHHost) {
        guard let secret = SSHKeyManager.loadBeamSecret(hostID: host.id.uuidString) else {
            status = "Kein MacBeam-Geheimnis — Mac neu koppeln (QR enthält es seit diesem Update)."
            return
        }
        key = BeamCrypto.key(fromSecret: secret)
        connectDirect(host: host, secret: secret)
    }

    /// Erst direkt (Heimnetz, beste Latenz); klappt das nicht in 4 s → Beam-Tunnel (unterwegs).
    private func connectDirect(host: SSHHost, secret: Data) {
        status = "verbinde zu \(host.host)…"
        let conn = NWConnection(host: NWEndpoint.Host(host.host),
                                port: NWEndpoint.Port(rawValue: MacBeamPort)!, using: .tcp)
        connection = conn
        var fellBack = false
        let fallback = { [weak self] in
            guard let self, !fellBack else { return }
            fellBack = true
            conn.cancel()
            self.connectRelay(secret: secret)
        }
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.connected = true
                    self?.status = "verbunden (direkt)"
                case .failed, .waiting:
                    fallback()
                case .cancelled:
                    if !fellBack { self?.connected = false }
                default: break
                }
            }
        }
        receiveLoop(conn)
        conn.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.connected != true { fallback() }
        }
    }

    /// Rendezvous über den Humibeam-Server — Verkehr bleibt E2E-verschlüsselt.
    private func connectRelay(secret: Data) {
        let relay = UserDefaults.standard.string(forKey: "beam.relay") ?? BeamCrypto.defaultRelay
        let parts = relay.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]) else {
            status = "Mac nicht erreichbar."; return
        }
        status = "verbinde über Tunnel (\(parts[0]))…"
        assembler = BeamFrameAssembler()
        let conn = NWConnection(host: NWEndpoint.Host(String(parts[0])),
                                port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection = conn
        let channel = BeamCrypto.channelID(fromSecret: secret)
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    let hello = "{\"role\":\"ios\",\"channel\":\"\(channel)\"}\n"
                    conn.send(content: Data(hello.utf8), completion: .contentProcessed { _ in })
                    // Erst ein Lebenszeichen schicken, damit der Mac die Leitung übernimmt.
                    self?.connected = true
                    self?.status = "verbunden (Tunnel)"
                    self?.send(BeamInput(kind: .move, x: 0.5, y: 0.5))
                case .failed(let error):
                    self?.connected = false
                    self?.status = "Mac nicht erreichbar (\(error.localizedDescription)). Läuft MacBeam am Mac?"
                case .cancelled:
                    self?.connected = false
                default: break
                }
            }
        }
        receiveLoop(conn)
        conn.start(queue: .main)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        connected = false
    }

    func send(_ input: BeamInput) {
        guard let key, let conn = connection, connected,
              let payload = try? JSONEncoder().encode(input),
              let packet = BeamCrypto.seal(type: .input, payload: payload, key: key) else { return }
        conn.send(content: packet, completion: .contentProcessed { _ in })
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1_000_000) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { return }
                if let data {
                    for frame in self.assembler.append(data) {
                        self.handle(frame)
                    }
                }
                if done || error != nil {
                    self.connected = false
                    self.status = "Verbindung beendet."
                } else {
                    self.receiveLoop(conn)
                }
            }
        }
    }

    private func handle(_ frame: Data) {
        guard let key, let (type, payload) = BeamCrypto.open(frame, key: key) else { return }
        switch type {
        case .hello:
            if let dict = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                macName = dict["name"] as? String ?? "Mac"
            }
        case .videoConfig:
            makeFormatDescription(payload)
        case .videoFrame:
            decodeFrame(payload)
        default:
            break
        }
    }

    private func makeFormatDescription(_ data: Data) {
        guard data.count > 4 else { return }
        let spsLen = Int(data.prefix(2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).bigEndian })
        guard data.count >= 2 + spsLen + 2 else { return }
        let sps = [UInt8](data.dropFirst(2).prefix(spsLen))
        let rest = data.dropFirst(2 + spsLen)
        let ppsLen = Int(rest.prefix(2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).bigEndian })
        guard rest.count >= 2 + ppsLen else { return }
        let pps = [UInt8](rest.dropFirst(2).prefix(ppsLen))

        sps.withUnsafeBufferPointer { spsPtr in
            pps.withUnsafeBufferPointer { ppsPtr in
                let sets: [UnsafePointer<UInt8>] = [spsPtr.baseAddress!, ppsPtr.baseAddress!]
                let sizes: [Int] = [sps.count, pps.count]
                var desc: CMVideoFormatDescription?
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: sets,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
                formatDescription = desc
            }
        }
    }

    private func decodeFrame(_ payload: Data) {
        guard let formatDescription, payload.count > 1 else { return }
        let avcc = payload.dropFirst()   // AVCC: bereits länge-präfixierte NALUs

        var blockBuffer: CMBlockBuffer?
        let dataCopy = UnsafeMutablePointer<UInt8>.allocate(capacity: avcc.count)
        avcc.copyBytes(to: dataCopy, count: avcc.count)
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: dataCopy, blockLength: avcc.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0,
            blockBufferOut: &blockBuffer) == noErr, let blockBuffer else {
            dataCopy.deallocate(); return
        }

        var sample: CMSampleBuffer?
        var sampleSize = avcc.count
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: blockBuffer,
                                        formatDescription: formatDescription, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                                        sampleBufferOut: &sample) == noErr, let sample else { return }
        // Sofort anzeigen, ohne auf eine Clock zu warten.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [CFMutableDictionary],
           let first = attachments.first {
            CFDictionarySetValue(first,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        onSample?(sample)
    }
}

/// Port des MacBeam-Servers (BeamProtocol ist geteilt, der Mac-Server selbst nicht).
let MacBeamPort: UInt16 = 8765
