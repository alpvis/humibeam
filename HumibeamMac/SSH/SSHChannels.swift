import Foundation
import NIOCore
import NIOSSH

// MARK: - PTY session (public handle for the terminal UI)

/// Handle to an interactive PTY shell channel.
/// `onOutput` / `onClosed` are invoked on the NIO event loop — the UI layer hops to the main actor.
final class PTYSession {
    private var channel: Channel?

    /// Bytes received from the remote shell (stdout+stderr merged, as a terminal expects).
    var onOutput: (([UInt8]) -> Void)?
    /// Invoked once when the channel closes.
    var onClosed: (() -> Void)?

    func attach(channel: Channel) {
        self.channel = channel
    }

    fileprivate func deliver(_ bytes: [UInt8]) { onOutput?(bytes) }
    fileprivate func didClose() { onClosed?() }

    /// Send user keystrokes / bytes to the remote shell.
    func write(_ bytes: [UInt8]) {
        guard let channel else { return }
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        channel.writeAndFlush(buffer, promise: nil)
    }

    func write(_ string: String) { write(Array(string.utf8)) }

    /// Inform the remote PTY of a new terminal size. Clamp to >= 1: while a terminal view is being
    /// re-parented (e.g. switching into split view) SwiftTerm can briefly report a zero/negative
    /// size, and NIOSSH's `UInt32(cols)` would trap on a negative value — crashing the whole app.
    func resize(cols: Int, rows: Int) {
        guard let channel else { return }
        let event = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: max(1, cols),
            terminalRowHeight: max(1, rows),
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        channel.triggerUserOutboundEvent(event, promise: nil)
    }

    func close() {
        channel?.close(promise: nil)
    }
}

/// NIO handler that requests a PTY + shell and streams data to its PTYSession.
final class PTYChannelHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let session: PTYSession
    private let term: String
    private let cols: Int
    private let rows: Int

    init(session: PTYSession, term: String, cols: Int, rows: Int) {
        self.session = session
        self.term = term
        self.cols = cols
        self.rows = rows
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in }
    }

    func channelActive(context: ChannelHandlerContext) {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: term,
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        context.triggerUserOutboundEvent(pty, promise: nil)
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = channelData.data else { return }
        session.deliver(Array(buffer.readableBytesView))
    }

    func channelInactive(context: ChannelHandlerContext) {
        session.didClose()
        context.fireChannelInactive()
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }
}

// MARK: - Exec channel (uploads + one-shot commands)

/// Runs a single command, optionally piping `stdin`, and collects stdout/stderr + exit status.
final class ExecChannelHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let stdin: Data?
    private let done: EventLoopPromise<(Int32, Data, Data)>
    private var stdout = Data()
    private var stderr = Data()
    private var exitStatus: Int32 = -1
    private var finished = false

    init(command: String, stdin: Data?, done: EventLoopPromise<(Int32, Data, Data)>) {
        self.command = command
        self.stdin = stdin
        self.done = done
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in }
    }

    func channelActive(context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true),
            promise: nil
        )
        if let stdin {
            var buffer = context.channel.allocator.buffer(capacity: stdin.count)
            buffer.writeBytes(stdin)
            context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: nil)
        }
        // EOF on stdin so the remote command terminates.
        context.channel.close(mode: .output, promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = channelData.data else { return }
        let bytes = buffer.readableBytesView
        switch channelData.type {
        case .channel: stdout.append(contentsOf: bytes)
        case .stdErr: stderr.append(contentsOf: bytes)
        default: break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            exitStatus = Int32(status.exitStatus)
        }
        // With remote half-closure allowed, the server signals EOF via `inputClosed` instead of a
        // full channel close. Close our side so the channel goes inactive and the command completes.
        if let ev = event as? ChannelEvent, ev == .inputClosed {
            context.close(promise: nil)
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
        done.succeed((exitStatus, stdout, stderr))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }
}

// MARK: - Streaming exec channel (transfers with byte-level progress)

/// Like ExecChannelHandler but reports progress: for downloads, cumulative stdout bytes received;
/// for uploads, cumulative stdin bytes flushed (stdin sent in chunks, each acknowledged before the
/// next — natural backpressure). Collects stdout/stderr and the exit status like the one-shot exec.
final class StreamingExecChannelHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let uploadData: Data?
    private let onProgress: ((Int) -> Void)?
    private let done: EventLoopPromise<(Int32, Data, Data)>
    private var stdout = Data()
    private var stderr = Data()
    private var received = 0
    private var exitStatus: Int32 = -1
    private var finished = false
    private let chunkSize = 64 * 1024

    init(command: String, uploadData: Data?, onProgress: ((Int) -> Void)?,
         done: EventLoopPromise<(Int32, Data, Data)>) {
        self.command = command
        self.uploadData = uploadData
        self.onProgress = onProgress
        self.done = done
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in }
    }

    func channelActive(context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), promise: nil)
        if let uploadData {
            sendChunks(channel: context.channel, data: uploadData, offset: 0)
        } else {
            context.channel.close(mode: .output, promise: nil) // download: EOF stdin so `cat` runs
        }
        context.fireChannelActive()
    }

    private func sendChunks(channel: Channel, data: Data, offset: Int) {
        guard offset < data.count else {
            channel.close(mode: .output, promise: nil) // EOF → remote `cat > file` finishes
            return
        }
        let end = Swift.min(offset + chunkSize, data.count)
        var buffer = channel.allocator.buffer(capacity: end - offset)
        buffer.writeBytes(data[offset..<end])
        let promise = channel.eventLoop.makePromise(of: Void.self)
        channel.writeAndFlush(buffer, promise: promise)
        promise.futureResult.whenComplete { [weak self] result in
            guard let self else { return }
            if case .success = result {
                self.onProgress?(end)
                self.sendChunks(channel: channel, data: data, offset: end)
            } else {
                channel.close(promise: nil)
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = channelData.data else { return }
        let bytes = buffer.readableBytesView
        switch channelData.type {
        case .channel:
            stdout.append(contentsOf: bytes)
            received += bytes.count
            onProgress?(received)
        case .stdErr:
            stderr.append(contentsOf: bytes)
        default: break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            exitStatus = Int32(status.exitStatus)
        }
        if let ev = event as? ChannelEvent, ev == .inputClosed {
            context.close(promise: nil) // remote EOF (half-closure) → finish the transfer
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !finished { finished = true; done.succeed((exitStatus, stdout, stderr)) }
        context.fireChannelInactive()
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }
}
