import Foundation
import NIO
import NIOHTTP1
import NIOWebSocket

enum ServerError: Error {
    case noOpenControllerPorts
}

class Controller: ObservableObject, Identifiable {
    var channel: Channel
    
    init(channel: Channel) {
        self.channel = channel
    }
}

public class Server: ObservableObject {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    private var upgrader: NIOWebSocketServerUpgrader? = nil
    
    private var host: String
    private var port: Int
    
    @Published var controllers: [Int: Controller?] = [:]
    var controllerCount = 4
    
    var nextControllerIndex: Int? {
        for i in 0...controllerCount {
            if controllers[i] == nil {
                return i
            }
        }
        return nil
    }
    
    init(host: String, port: Int) {
        self.host = host
        self.port = port
        
        self.upgrader = NIOWebSocketServerUpgrader(
            shouldUpgrade: { (channel: Channel, head: HTTPRequestHead) in
                channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: self.upgradePipelineHandler
        )
    }
    
    func upgradePipelineHandler(channel: Channel, _: HTTPRequestHead) -> EventLoopFuture<Void> {
        guard let index = self.nextControllerIndex else {
            channel.pipeline.fireErrorCaught(ServerError.noOpenControllerPorts)
            return channel.pipeline.close()
        }
        
        DispatchQueue.main.async {
            print("controller \(index) connect", channel.isActive)
            self.controllers[index] = Controller(channel: channel)
        }
        do {
            let websocketHandler = try WebSocketHandler(index: index, onClose: { [weak self] in
                guard let self = self else {
                    return
                }
                DispatchQueue.main.async {
                    print("controller \(index) disconnect")
                    self.controllers[index] = nil
                }
            })
            return channel.pipeline.addHandler(websocketHandler)
        } catch {
            fatalError(error.localizedDescription)
        }
    }
    
    func run() throws {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let channel = try self.serverBootstrap.bind(host: self.host, port: self.port).wait()
                print("\(channel.localAddress!) is now open")
                try channel.closeFuture.wait()
            } catch {
                print("Error: ", error)
            }
        }
    }
    
    func shutdown() throws {
        try group.syncShutdownGracefully()
        print("Server closed")
    }
    
    private var serverBootstrap: ServerBootstrap {
        ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let httpHandler = WebsocketUpgradeHandler(isFull: self.controllers.count >= 4)
                let config: NIOHTTPServerUpgradeConfiguration = (
                    upgraders: [self.upgrader!],
                    completionHandler: { _ in
                        channel.pipeline.removeHandler(httpHandler, promise: nil)
                    }
                )
                return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: config).flatMap {
                    channel.pipeline.addHandler(httpHandler)
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())
    }
}

public class WebsocketUpgradeHandler: ChannelInboundHandler, RemovableChannelHandler {
    public typealias InboundIn = HTTPServerRequestPart
    public typealias OutboundOut = HTTPServerResponsePart
    
    private var isFull: Bool
    
    init(isFull: Bool) {
        self.isFull = isFull
    }
    
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let reqPart = self.unwrapInboundIn(data)
        
        // We're not interested in request bodies here: we're just serving up GET responses
        // to get the client to initiate a websocket request.
        guard case .head(let head) = reqPart else {
            return
        }
        
        guard case .GET = head.method else {
            self.respond405(context: context)
            return
        }
        
        if self.isFull {
            self.respond409(context: context)
            return
        }
        
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/html")
        headers.add(name: "Content-Length", value: "0")
        headers.add(name: "Connection", value: "close")
        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(self.wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
        context.flush()
    }
    
    private func respond405(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "Connection", value: "close")
        headers.add(name: "Content-Length", value: "0")
        let head = HTTPResponseHead(
            version: .http1_1,
            status: .methodNotAllowed,
            headers: headers
        )
        context.write(self.wrapOutboundOut(.head(head)), promise: nil)
        context.write(self.wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
        context.flush()
    }
    
    private func respond409(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "Connection", value: "close")
        headers.add(name: "Content-Length", value: "0")
        let head = HTTPResponseHead(
            version: .http1_1,
            status: .conflict,
            headers: headers
        )
        context.write(self.wrapOutboundOut(.head(head)), promise: nil)
        context.write(self.wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
        context.flush()
    }
    
    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("error: ", error)
        context.close(promise: nil)
    }
}

private final class WebSocketHandler: NSObject, ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let id = UUID()
    private let index: Int
    private var outputStream: OutputStream
    private var onClose: () -> Void

    private var awaitingClose: Bool = false
    private var writeQueue: DispatchQueue
    
    init(index: Int, onClose: @escaping () -> Void) throws {
        self.index = index
        self.onClose = onClose
        self.outputStream = try createPipe(index: index)
        self.writeQueue = DispatchQueue(
            label: "ctrl queue \(index)",
            qos: .userInteractive
        )
    }
    
    deinit {
        self.outputStream.close()
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        self.sendPing(context: context)
        DispatchQueue.global().async {
            self.outputStream.open()
        }
    }
    
    public func handlerRemoved(context: ChannelHandlerContext) {
        onClose()
    }
    
    private static var newline: UInt8 = 0x0A

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)

        switch frame.opcode {
        case .connectionClose:
            self.receivedClose(context: context, frame: frame)
        case .ping:
            let buffer = context.channel.allocator.buffer(string: "\(self.index)")
            let frame = WebSocketFrame(fin: true, opcode: .pong, data: buffer)
            context.writeAndFlush(self.wrapOutboundOut(frame), promise: nil)
            break
        case .pong:
            break
        case .text:
            do {
                try self.streamText(buffer: frame.unmaskedData)
            } catch {
                print("Error", error)
            }
        case .binary, .continuation, .ping:
            // We ignore these frames.
            break
        default:
            // Unknown frames are errors.
            self.closeOnError(context: context)
        }
    }

    public func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    private func receivedClose(context: ChannelHandlerContext, frame: WebSocketFrame) {
        // Handle a received close frame. In websockets, we're just going to send the close
        // frame and then close, unless we already sent our own close frame.
        if awaitingClose {
            // Cool, we started the close and were waiting for the user. We're done.
            context.close(promise: nil)
        } else {
            // This is an unsolicited close. We're going to send a response frame and
            // then, when we've sent it, close up shop. We should send back the close code the remote
            // peer sent us, unless they didn't send one at all.
            var data = frame.unmaskedData
            let closeDataCode = data.readSlice(length: 2) ?? ByteBuffer()
            let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: closeDataCode)
            _ = context.write(self.wrapOutboundOut(closeFrame)).map { () in
                context.close(promise: nil)
            }
        }
    }
    
    private func sendPing(context: ChannelHandlerContext) {
        let buffer = context.channel.allocator.buffer(string: "\(self.index)")
        let frame = WebSocketFrame(fin: true, opcode: .ping, data: buffer)
        print("ping", context.channel.isActive, context.channel.isWritable)
        context.writeAndFlush(self.wrapOutboundOut(frame), promise: nil)
    }
    
    private func streamText(buffer: ByteBuffer) throws {
        var data = buffer
        if !self.outputStream.hasSpaceAvailable {
            return
        }
        var written = data.readableBytes
        while written > 0 {
            do {
                written -= try data.readWithUnsafeReadableBytes({ pointer in
                    guard let address = pointer.baseAddress else {
                        return 0
                    }
                    let bytesWritten = self.outputStream.write(address.assumingMemoryBound(to: UInt8.self), maxLength: written)
                    if bytesWritten < 0 {
                        guard let error = self.outputStream.streamError else {
                            fatalError("expected a stream error")
                        }
                        throw error
                    }
                    return bytesWritten
                })
                self.outputStream.write(&WebSocketHandler.newline, maxLength: 1)
            } catch {
                if (error as NSError).domain == NSPOSIXErrorDomain
                    && (error as NSError).code == EPIPE {
                    print("pipe closed, reopening")
                    // Broken pipe error
                    self.outputStream = try createPipe(index: index)
                    DispatchQueue.global().async {
                        self.outputStream.open()
                    }
                }
                return
            }
        }
    }

    private func closeOnError(context: ChannelHandlerContext) {
        // We have hit an error, we want to close. We do that by sending a close frame and then
        // shutting down the write side of the connection.
        var data = context.channel.allocator.buffer(capacity: 2)
        data.write(webSocketErrorCode: .protocolError)
        let frame = WebSocketFrame(fin: true, opcode: .connectionClose, data: data)
        context.write(self.wrapOutboundOut(frame)).whenComplete { (_: Result<Void, Error>) in
            context.close(mode: .output, promise: nil)
        }
        awaitingClose = true
    }
}

enum PipeError: Error {
    case openFailed
}

func createPipe(index: Int) throws -> OutputStream {
    let applicationSupport = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    )
    
    let pipesFolder = applicationSupport
        .appendingPathComponent("Dolphin")
        .appendingPathComponent("Pipes")
    if !FileManager.default.fileExists(atPath: pipesFolder.path) {
        try FileManager.default.createDirectory(
            at: pipesFolder,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }
    let pipeUrl = pipesFolder.appendingPathComponent("ctrl\(index+1)")
    mkfifo(pipeUrl.path, 0o644)
    guard let outputStream = OutputStream(url: pipeUrl, append: true) else {
        throw PipeError.openFailed
    }
    
    return outputStream
}
