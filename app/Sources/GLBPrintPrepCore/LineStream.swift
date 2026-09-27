import Foundation

/// Delivers the lines of a pipe as soon as they arrive (readabilityHandler), without waiting for a
/// buffer to fill up. `FileHandle.bytes.lines` buffers, so progress events used to arrive all at
/// once at the end. Thread-safe: the pending buffer is protected by a lock.
public final class LineStream: @unchecked Sendable {
    public let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var buffer = Data()

    public init(_ handle: FileHandle) {
        (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
        handle.readabilityHandler = { [self] h in
            let chunk = h.availableData
            if chunk.isEmpty {  // EOF: the process has exited
                h.readabilityHandler = nil
                flush()
                continuation.finish()
            } else {
                append(chunk)
            }
        }
    }

    private func append(_ chunk: Data) {
        var lines: [String] = []
        lock.lock()
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()
        for line in lines { continuation.yield(line) }
    }

    private func flush() {
        lock.lock()
        let rest = buffer
        buffer.removeAll()
        lock.unlock()
        if !rest.isEmpty { continuation.yield(String(decoding: rest, as: UTF8.self)) }
    }
}
