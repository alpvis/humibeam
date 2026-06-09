import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// A running local port-forward (ssh -L): a local listening socket whose connections are
/// tunneled to `targetHost:targetPort` through the SSH connection (directTCPIP channels).
final class LocalForward {
    let serverChannel: Channel
    let localPort: Int
    let targetHost: String
    let targetPort: Int

    init(serverChannel: Channel, localPort: Int, targetHost: String, targetPort: Int) {
        self.serverChannel = serverChannel
        self.localPort = localPort
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    func close() { serverChannel.close(promise: nil) }
}

/// Forwards bytes from the local TCP socket into the SSH tunnel channel.
final class LocalSideHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    var peer: Channel?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        peer?.writeAndFlush(buffer, promise: nil)
    }
    func channelInactive(context: ChannelHandlerContext) {
        peer?.close(promise: nil)
        context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

/// Forwards bytes from the SSH tunnel channel back to the local TCP socket,
/// and wraps outbound ByteBuffers as SSHChannelData.
final class SSHTunnelHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData
    var peer: Channel?

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = channelData.data else { return }
        peer?.writeAndFlush(buffer, promise: nil)
    }
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }
    func channelInactive(context: ChannelHandlerContext) {
        peer?.close(promise: nil)
        context.fireChannelInactive()
    }
}
