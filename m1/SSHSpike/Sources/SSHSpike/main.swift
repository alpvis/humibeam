// humibeam M1 — SSH-Spike
//
// Beweist die drei M1-Ziele gegen einen echten SSH-Server:
//   1. Verbinden + Public-Key-Auth (swift-nio-ssh)
//   2. Interaktive PTY-Shell: Bytes hin (Befehl) und zurück (Ausgabe)
//   3. Datei-Upload über Exec-Channel (`cat > datei`) — Fallback #5 aus M0,
//      braucht KEIN SFTP-Subsystem, läuft auf Stock-Ubuntu. Danach Verify per Hash.
//
// Zwei Subcommands:
//   SSHSpike genkey  <rawKeyOut>                 -> erzeugt ed25519-Key, druckt authorized_keys-Zeile
//   SSHSpike connect <host> <port> <user> <rawKey> <localFile> <remotePath>

import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Crypto

// MARK: - OpenSSH-Helfer

func sshString(_ data: Data) -> Data {
    var out = Data()
    var len = UInt32(data.count).bigEndian
    withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
    out.append(data)
    return out
}

/// Baut eine `ssh-ed25519 <base64> <comment>`-Zeile für ~/.ssh/authorized_keys.
func authorizedKeysLine(_ pub: Curve25519.Signing.PublicKey, comment: String) -> String {
    var blob = Data()
    blob.append(sshString(Data("ssh-ed25519".utf8)))
    blob.append(sshString(pub.rawRepresentation))
    return "ssh-ed25519 \(blob.base64EncodedString()) \(comment)"
}

// MARK: - Auth-Delegates

/// Spike: akzeptiert jeden Host-Key. (In humibeam: known_hosts-Prüfung.)
final class AcceptAllHostKeys: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

final class PublicKeyAuth: NIOSSHClientUserAuthenticationDelegate {
    let username: String
    let privateKey: NIOSSHPrivateKey
    private var offered = false

    init(username: String, privateKey: NIOSSHPrivateKey) {
        self.username = username
        self.privateKey = privateKey
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.contains(.publicKey), !offered else {
            nextChallengePromise.succeed(nil)
            return
        }
        offered = true
        let offer = NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "",
            offer: .privateKey(.init(privateKey: privateKey))
        )
        nextChallengePromise.succeed(offer)
    }
}

final class ErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        FileHandle.standardError.write(Data("pipeline error: \(error)\n".utf8))
        context.close(promise: nil)
    }
}

// MARK: - Channel-Handler (Shell oder Exec, sammelt Ausgabe, sendet stdin)

final class SessionHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    enum Kind {
        case shellPTY(commands: String)   // PTY anfordern, Shell starten, Befehle senden
        case exec(command: String, stdin: Data?)  // Befehl ausführen, optional stdin pipen
    }

    let kind: Kind
    let done: EventLoopPromise<(Int32, Data)>
    private var collected = Data()
    private var exitStatus: Int32 = -1
    private var finished = false

    init(kind: Kind, done: EventLoopPromise<(Int32, Data)>) {
        self.kind = kind
        self.done = done
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .whenFailure { _ in }
    }

    func channelActive(context: ChannelHandlerContext) {
        switch kind {
        case .shellPTY(let commands):
            let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: "xterm-256color",
                terminalCharacterWidth: 120, terminalRowHeight: 40,
                terminalPixelWidth: 0, terminalPixelHeight: 0,
                terminalModes: SSHTerminalModes([:])
            )
            context.triggerUserOutboundEvent(pty, promise: nil)
            context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true), promise: nil)
            send(context: context, string: commands)

        case .exec(let command, let stdin):
            context.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true),
                promise: nil
            )
            if let stdin {
                var buf = context.channel.allocator.buffer(capacity: stdin.count)
                buf.writeBytes(stdin)
                context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buf))), promise: nil)
            }
            // EOF auf stdin senden -> der Remote-Befehl (z.B. cat) terminiert
            context.channel.close(mode: .output, promise: nil)
        }
        context.fireChannelActive()
    }

    private func send(context: ChannelHandlerContext, string: String) {
        var buf = context.channel.allocator.buffer(capacity: string.utf8.count)
        buf.writeString(string)
        context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buf))), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = channelData.data else { return }
        collected.append(contentsOf: buffer.readableBytesView)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            exitStatus = Int32(status.exitStatus)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish()
        context.fireChannelInactive()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        done.succeed((exitStatus, collected))
    }

    // ByteBuffer (outbound) -> SSHChannelData
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }
}

// MARK: - Client

struct SpikeError: Error { let message: String }

func runSession(sshHandler: NIOSSHHandler, on channel: Channel, kind: SessionHandler.Kind) throws -> (Int32, Data) {
    let done = channel.eventLoop.makePromise(of: (Int32, Data).self)
    let childPromise = channel.eventLoop.makePromise(of: Channel.self)

    channel.eventLoop.execute {
        sshHandler.createChannel(childPromise, channelType: .session) { childChannel, channelType in
            guard channelType == .session else {
                return childChannel.eventLoop.makeFailedFuture(SpikeError(message: "unexpected channel type"))
            }
            return childChannel.pipeline.addHandler(SessionHandler(kind: kind, done: done))
        }
    }
    _ = try childPromise.futureResult.wait()
    return try done.futureResult.wait()
}

func connect(host: String, port: Int, user: String, rawKeyPath: String, localFile: String, remotePath: String) throws {
    // Private Key laden (32-byte raw ed25519)
    let rawKey = try Data(contentsOf: URL(fileURLWithPath: rawKeyPath))
    let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawKey)
    let privateKey = NIOSSHPrivateKey(ed25519Key: signingKey)

    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { try? group.syncShutdownGracefully() }

    let clientConfig = SSHClientConfiguration(
        userAuthDelegate: PublicKeyAuth(username: user, privateKey: privateKey),
        serverAuthDelegate: AcceptAllHostKeys()
    )

    let bootstrap = ClientBootstrap(group: group)
        .channelInitializer { channel in
            channel.pipeline.addHandlers([
                NIOSSHHandler(role: .client(clientConfig), allocator: channel.allocator, inboundChildChannelInitializer: nil),
                ErrorHandler()
            ])
        }
        .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

    print("→ verbinde zu \(user)@\(host):\(port) …")
    let channel = try bootstrap.connect(host: host, port: port).wait()
    let sshHandler = try channel.pipeline.handler(type: NIOSSHHandler.self).wait()
    print("✅ verbunden + authentifiziert (public key)")

    var allPassed = true

    // --- Test 1: PTY-Shell, Bytes hin/zurück ---
    let marker = "HUMIBEAM_PTY_MARKER_OK"
    let shellCommands = "echo \(marker); uname -srm; exit\n"
    let (shellStatus, shellOut) = try runSession(sshHandler: sshHandler, on: channel, kind: .shellPTY(commands: shellCommands))
    let shellText = String(decoding: shellOut, as: UTF8.self)
    let ptyOK = shellText.contains(marker)
    print("\n── Test 1: PTY-Shell (exit \(shellStatus))")
    print("   gesendet:  echo \(marker); uname -srm; exit")
    print("   empfangen: \(shellText.split(separator: "\n").map(String.init).filter { !$0.isEmpty }.joined(separator: " | "))")
    print(ptyOK ? "   => PASS (Bytes hin und zurück)" : "   => FAIL")
    allPassed = allPassed && ptyOK

    // --- Test 2: Upload via Exec-Channel (Fallback #5) ---
    let payload = try Data(contentsOf: URL(fileURLWithPath: localFile))
    let localHash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    // remotePath sicher quoten
    let quotedRemote = "'" + remotePath.replacingOccurrences(of: "'", with: "'\\''") + "'"
    let mkdirCmd = "mkdir -p \"$(dirname \(quotedRemote))\" && cat > \(quotedRemote)"
    let (uploadStatus, _) = try runSession(
        sshHandler: sshHandler, on: channel,
        kind: .exec(command: mkdirCmd, stdin: payload)
    )
    print("\n── Test 2: Datei-Upload via Exec-Channel (\(payload.count) bytes, exit \(uploadStatus))")
    print("   nach: \(remotePath)")

    // --- Test 3: Verify per Remote-Hash ---
    let (verifyStatus, verifyOut) = try runSession(
        sshHandler: sshHandler, on: channel,
        kind: .exec(command: "shasum -a 256 \(quotedRemote) 2>/dev/null || sha256sum \(quotedRemote)", stdin: nil)
    )
    let remoteHash = String(decoding: verifyOut, as: UTF8.self)
        .split(separator: " ").first.map(String.init) ?? ""
    let uploadOK = uploadStatus == 0 && verifyStatus == 0 && remoteHash == localHash
    print("── Test 3: Integritäts-Check")
    print("   lokal : \(localHash)")
    print("   remote: \(remoteHash)")
    print(uploadOK ? "   => PASS (Upload bit-identisch)" : "   => FAIL")
    allPassed = allPassed && uploadOK

    try channel.close().wait()

    print("\n════════════════════════════════════════════")
    print(allPassed ? "M1-SPIKE: ALLE TESTS BESTANDEN ✅" : "M1-SPIKE: FEHLGESCHLAGEN ❌")
    print("════════════════════════════════════════════")
    if !allPassed { exit(1) }
}

// MARK: - CLI

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: SSHSpike genkey <rawKeyOut> | connect <host> <port> <user> <rawKey> <localFile> <remotePath>")
    exit(2)
}

switch args[1] {
case "genkey":
    guard args.count == 3 else { print("usage: SSHSpike genkey <rawKeyOut>"); exit(2) }
    let key = Curve25519.Signing.PrivateKey()
    try key.rawRepresentation.write(to: URL(fileURLWithPath: args[2]))
    // Die authorized_keys-Zeile geht nach stdout (das Run-Skript hängt sie an).
    print(authorizedKeysLine(key.publicKey, comment: "humibeam-m1-swift-DELETE-ME"))

case "connect":
    guard args.count == 8 else {
        print("usage: SSHSpike connect <host> <port> <user> <rawKey> <localFile> <remotePath>")
        exit(2)
    }
    try connect(
        host: args[2], port: Int(args[3]) ?? 22, user: args[4],
        rawKeyPath: args[5], localFile: args[6], remotePath: args[7]
    )

default:
    print("unbekanntes Kommando: \(args[1])")
    exit(2)
}
