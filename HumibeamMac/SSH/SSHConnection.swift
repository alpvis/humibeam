import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Crypto

// MARK: - Public configuration

struct SSHCredentials {
    var host: String
    var port: Int
    var username: String
    var auth: SSHAuthMethod
}

enum SSHAuthMethod {
    case password(String)
    /// Raw 32-byte ed25519 private key (e.g. a humibeam-managed key).
    case ed25519Raw(Data)
    /// An already-constructed NIOSSHPrivateKey (e.g. imported OpenSSH key).
    case privateKey(NIOSSHPrivateKey)
}

enum SSHError: Error, LocalizedError {
    case notConnected
    case channelTypeMismatch
    case uploadFailed(Int32)
    case commandFailed(Int32, String)
    case hostKeyRejected

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Nicht verbunden."
        case .channelTypeMismatch: return "Unerwarteter SSH-Channel-Typ."
        case .uploadFailed(let s): return "Upload fehlgeschlagen (exit \(s))."
        case .commandFailed(let s, let m): return "Befehl fehlgeschlagen (exit \(s)): \(m)"
        case .hostKeyRejected: return "Host-Key abgelehnt."
        }
    }
}

// MARK: - Host key verification

protocol SSHHostKeyVerifier: AnyObject {
    /// Called on the event loop. Succeed the promise to accept, fail to reject.
    func verify(host: String, port: Int, hostKey: NIOSSHPublicKey, promise: EventLoopPromise<Void>)
}

// MARK: - Connection

/// One SSH connection. Owns the NIO channel; supports a PTY shell plus
/// concurrent exec channels (uploads, commands) multiplexed over the same socket.
final class SSHConnection {
    private let credentials: SSHCredentials
    private weak var hostKeyVerifier: SSHHostKeyVerifier?
    private let group: EventLoopGroup
    private let ownsGroup: Bool
    private var channel: Channel?

    init(credentials: SSHCredentials,
         hostKeyVerifier: SSHHostKeyVerifier? = nil,
         group: EventLoopGroup? = nil) {
        self.credentials = credentials
        self.hostKeyVerifier = hostKeyVerifier
        if let group {
            self.group = group
            self.ownsGroup = false
        } else {
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.ownsGroup = true
        }
    }

    var isConnected: Bool { channel?.isActive ?? false }

    func connect() async throws {
        let authDelegate = UserAuthDelegate(username: credentials.username, method: credentials.auth)
        let serverDelegate = HostKeyDelegate(host: credentials.host, port: credentials.port, verifier: hostKeyVerifier)
        let config = SSHClientConfiguration(userAuthDelegate: authDelegate, serverAuthDelegate: serverDelegate)

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandlers([
                    NIOSSHHandler(role: .client(config), allocator: channel.allocator, inboundChildChannelInitializer: nil),
                    ErrorLogger()
                ])
            }
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)

        let ch = try await bootstrap.connect(host: credentials.host, port: credentials.port).get()
        self.channel = ch
    }

    func close() async {
        try? await channel?.close().get()
        channel = nil
        if ownsGroup { try? await group.shutdownGracefully() }
    }

    private func sshHandler() async throws -> NIOSSHHandler {
        guard let channel else { throw SSHError.notConnected }
        return try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
    }

    // MARK: PTY shell

    /// Opens an interactive PTY shell. Output and close are delivered via the session's callbacks.
    func openShell(term: String = "xterm-256color", cols: Int = 120, rows: Int = 40) async throws -> PTYSession {
        guard let channel else { throw SSHError.notConnected }
        let handler = try await sshHandler()
        let session = PTYSession()
        let ptyHandler = PTYChannelHandler(session: session, term: term, cols: cols, rows: rows)

        let childPromise = channel.eventLoop.makePromise(of: Channel.self)
        channel.eventLoop.execute {
            handler.createChannel(childPromise, channelType: .session) { child, type in
                guard type == .session else { return child.eventLoop.makeFailedFuture(SSHError.channelTypeMismatch) }
                return child.pipeline.addHandler(ptyHandler)
            }
        }
        let child = try await Self.withChannelOpenTimeout { try await childPromise.futureResult.get() }
        session.attach(channel: child)
        return session
    }

    // MARK: Exec (upload + commands)

    /// Uploads `data` to `remotePath` over an exec channel (`cat > path`). No SFTP required.
    func upload(_ data: Data, to remotePath: String) async throws {
        let quoted = Self.shellQuote(remotePath)
        let cmd = "mkdir -p \"$(dirname \(quoted))\" && cat > \(quoted)"
        let (status, _, _) = try await exec(cmd, stdin: data)
        guard status == 0 else { throw SSHError.uploadFailed(status) }
    }

    /// Runs a command, returns (exitStatus, stdout, stderr).
    @discardableResult
    func exec(_ command: String, stdin: Data? = nil) async throws -> (Int32, Data, Data) {
        guard let channel else { throw SSHError.notConnected }
        let handler = try await sshHandler()
        let done = channel.eventLoop.makePromise(of: (Int32, Data, Data).self)
        let execHandler = ExecChannelHandler(command: command, stdin: stdin, done: done)

        let childPromise = channel.eventLoop.makePromise(of: Channel.self)
        channel.eventLoop.execute {
            handler.createChannel(childPromise, channelType: .session) { child, type in
                guard type == .session else { return child.eventLoop.makeFailedFuture(SSHError.channelTypeMismatch) }
                return child.pipeline.addHandler(execHandler)
            }
        }
        // Time out the channel open (covers a stalled/failed authentication) so the UI never hangs.
        _ = try await Self.withChannelOpenTimeout { try await childPromise.futureResult.get() }
        return try await done.futureResult.get()
    }

    /// Fails with a timeout error if a channel-open future doesn't resolve quickly — a failed or
    /// stalled SSH authentication otherwise leaves channel creation pending forever.
    static func withChannelOpenTimeout<T>(seconds: Double = 20,
                                          _ operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SSHError.commandFailed(-1, "Zeitüberschreitung beim Verbinden (Anmeldung fehlgeschlagen?).")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Uploads with byte-level progress (chunked stdin). `onProgress` reports cumulative bytes sent.
    func upload(_ data: Data, to remotePath: String, onProgress: ((Int) -> Void)?) async throws {
        let quoted = Self.shellQuote(remotePath)
        let cmd = "mkdir -p \"$(dirname \(quoted))\" && cat > \(quoted)"
        let (status, _, _) = try await execStreaming(cmd, uploadData: data, onProgress: onProgress)
        guard status == 0 else { throw SSHError.uploadFailed(status) }
    }

    /// Downloads with byte-level progress (streamed stdout). `onProgress` reports cumulative bytes received.
    func download(_ remotePath: String, onProgress: ((Int) -> Void)?) async throws -> Data {
        let (status, out, err) = try await execStreaming("cat \(Self.shellQuote(remotePath))",
                                                         uploadData: nil, onProgress: onProgress)
        guard status == 0 else { throw SSHError.commandFailed(status, String(decoding: err, as: UTF8.self)) }
        return out
    }

    /// Downloads a folder as a streamed gzip tarball, reporting received bytes.
    func downloadFolderTarGz(_ path: String, onProgress: ((Int) -> Void)?) async throws -> Data {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let cmd = "tar -czf - -C \(Self.shellQuote(parent)) \(Self.shellQuote(name))"
        let (status, out, err) = try await execStreaming(cmd, uploadData: nil, onProgress: onProgress)
        guard status == 0 else { throw SSHError.commandFailed(status, String(decoding: err, as: UTF8.self)) }
        return out
    }

    /// Runs a command with progress callbacks, collecting stdout/stderr + exit status.
    private func execStreaming(_ command: String, uploadData: Data?,
                               onProgress: ((Int) -> Void)?) async throws -> (Int32, Data, Data) {
        guard let channel else { throw SSHError.notConnected }
        let handler = try await sshHandler()
        let done = channel.eventLoop.makePromise(of: (Int32, Data, Data).self)
        let execHandler = StreamingExecChannelHandler(command: command, uploadData: uploadData,
                                                      onProgress: onProgress, done: done)
        let childPromise = channel.eventLoop.makePromise(of: Channel.self)
        channel.eventLoop.execute {
            handler.createChannel(childPromise, channelType: .session) { child, type in
                guard type == .session else { return child.eventLoop.makeFailedFuture(SSHError.channelTypeMismatch) }
                return child.pipeline.addHandler(execHandler)
            }
        }
        _ = try await Self.withChannelOpenTimeout { try await childPromise.futureResult.get() }
        return try await done.futureResult.get()
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Local port forwarding (ssh -L)

    /// Listens on `localPort` and tunnels each connection to `targetHost:targetPort`
    /// through this SSH connection (directTCPIP channels).
    func startLocalForward(localHost: String = "127.0.0.1", localPort: Int,
                           targetHost: String, targetPort: Int) async throws -> LocalForward {
        guard let sshChannel = channel else { throw SSHError.notConnected }

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { localChannel in
                Self.tunnel(localChannel: localChannel, sshChannel: sshChannel,
                            targetHost: targetHost, targetPort: targetPort)
            }

        let server = try await bootstrap.bind(host: localHost, port: localPort).get()
        let port = server.localAddress?.port ?? localPort
        return LocalForward(serverChannel: server, localPort: port, targetHost: targetHost, targetPort: targetPort)
    }

    private static func tunnel(localChannel: Channel, sshChannel: Channel,
                               targetHost: String, targetPort: Int) -> EventLoopFuture<Void> {
        let localSide = LocalSideHandler()
        let childPromise = localChannel.eventLoop.makePromise(of: Channel.self)

        sshChannel.eventLoop.execute {
            do {
                let handler = try sshChannel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                let origin = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
                let type = SSHChannelType.directTCPIP(
                    .init(targetHost: targetHost, targetPort: targetPort, originatorAddress: origin))
                handler.createChannel(childPromise, channelType: type) { child, _ in
                    let sshSide = SSHTunnelHandler()
                    sshSide.peer = localChannel
                    return child.pipeline.addHandler(sshSide)
                }
            } catch {
                childPromise.fail(error)
            }
        }

        return childPromise.futureResult.flatMap { child -> EventLoopFuture<Void> in
            localSide.peer = child
            return localChannel.pipeline.addHandler(localSide)
        }.flatMapError { error in
            localChannel.close(promise: nil)
            return localChannel.eventLoop.makeFailedFuture(error)
        }
    }
}

// MARK: - Error logger

final class ErrorLogger: ChannelInboundHandler {
    typealias InboundIn = Any
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        NSLog("humibeam SSH pipeline error: \(error)")
        context.close(promise: nil)
    }
}
