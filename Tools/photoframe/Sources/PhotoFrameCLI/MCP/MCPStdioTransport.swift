import Darwin
import Dispatch
import Foundation
import Logging
import MCP
import System

/// MCP stdio 传输：每行一条 JSON-RPC 消息（与 SDK 的 `StdioTransport` 相同的分帧和日志）。
///
/// SDK 的 `StdioTransport` 把 stdin / stdout 设成 O_NONBLOCK，再每 10 ms 轮询一次：空闲时也一直唤醒、占 CPU，
/// 写大消息（内联预览）时反复等待，退出后终端的 stdin 还是非阻塞的。这里：
/// - 在专用线程上阻塞读 stdin，读到完整的一行就交出去；
/// - 在串行队列上阻塞写，写完再恢复 `send`，消息之间不会交错；
/// - 从不修改文件描述符的模式。描述符已经被别人设成非阻塞时，用 `poll` 等到可读 / 可写，而不是轮询。
actor MCPStdioTransport: Transport {
    nonisolated let logger: Logger

    private let input: FileDescriptor
    private let output: FileDescriptor
    private let writer = DispatchQueue(label: "org.anotherphotoframe.mcp.stdout")
    private var isConnected = false
    private let messages: AsyncThrowingStream<Data, any Swift.Error>
    private let continuation: AsyncThrowingStream<Data, any Swift.Error>.Continuation

    init(input: FileDescriptor = .standardInput, output: FileDescriptor = .standardOutput, logger: Logger? = nil) {
        self.input = input
        self.output = output
        self.logger = logger ?? Logger(label: "mcp.transport.stdio", factory: { _ in SwiftLogNoOpLogHandler() })
        let stream = AsyncThrowingStream<Data, any Swift.Error>.makeStream()
        messages = stream.stream
        continuation = stream.continuation
    }

    func connect() async throws {
        guard !isConnected else { return }
        isConnected = true
        logger.debug("Transport connected successfully")
        let (input, continuation, logger) = (input, continuation, logger)
        let reader = Thread { Self.readLines(from: input, into: continuation, logger: logger) }
        reader.name = "org.anotherphotoframe.mcp.stdin"
        reader.start()
    }

    func disconnect() async {
        guard isConnected else { return }
        isConnected = false
        continuation.finish()
        logger.debug("Transport disconnected")
    }

    func send(_ message: Data) async throws {
        guard isConnected else { throw MCPError.transportError(Errno(rawValue: ENOTCONN)) }
        var framed = message
        framed.append(UInt8(ascii: "\n"))
        let (line, writer, output) = (framed, writer, output)
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Swift.Error>) in
            writer.async {
                do {
                    try Self.writeAll(line, to: output)
                    done.resume()
                } catch {
                    done.resume(throwing: MCPError.transportError(error))
                }
            }
        }
    }

    func receive() -> AsyncThrowingStream<Data, any Swift.Error> {
        messages
    }

    // MARK: - 读写（在读线程 / 写队列上执行，阻塞）

    /// 读到 EOF 或出错为止，每个完整的非空行交出一次（不含换行符）；流结束（断开连接）后也停下。
    private static func readLines(
        from input: FileDescriptor, into continuation: AsyncThrowingStream<Data, any Swift.Error>.Continuation, logger: Logger
    ) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var pending = Data()
        reading: while true {
            let count: Int
            do {
                count = try buffer.withUnsafeMutableBytes { try input.read(into: $0) }
            } catch let error as Errno where error == .resourceTemporarilyUnavailable {
                waitUntilReady(input, events: Int16(POLLIN))
                continue
            } catch {
                logger.error("Read error occurred", metadata: ["error": "\(error)"])
                break
            }
            if count == 0 {
                logger.notice("EOF received")
                break
            }
            // 只在新读到的部分里找换行：长消息分多次到达时不反复扫描前面的内容。
            var searchFrom = pending.count
            pending.append(contentsOf: buffer[..<count])
            while let newline = pending[(pending.startIndex + searchFrom)...].firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[..<newline]
                if !line.isEmpty {
                    logger.trace("Message received", metadata: ["size": "\(line.count)"])
                    if case .terminated = continuation.yield(Data(line)) { break reading }
                }
                pending = Data(pending[(newline + 1)...])
                searchFrom = 0
            }
        }
        continuation.finish()
    }

    private static func writeAll(_ data: Data, to output: FileDescriptor) throws {
        var remaining = data
        while !remaining.isEmpty {
            do {
                let written = try remaining.withUnsafeBytes { try output.write($0) }
                remaining = remaining.dropFirst(written)
            } catch let error as Errno where error == .resourceTemporarilyUnavailable {
                waitUntilReady(output, events: Int16(POLLOUT))
            }
        }
    }

    /// 描述符是非阻塞的（不是这里设的）时，等到可读 / 可写再试。
    private static func waitUntilReady(_ descriptor: FileDescriptor, events: Int16) {
        var fd = pollfd(fd: descriptor.rawValue, events: events, revents: 0)
        _ = poll(&fd, 1, -1)
    }
}
