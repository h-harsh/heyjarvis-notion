import Foundation

/// Length-prefixed framing for the daemon↔proxy socket: a `uint32` big-endian byte
/// count followed by that many UTF-8 JSON bytes. A stream socket does NOT preserve
/// message boundaries (a `read` can split one frame across two syscalls or coalesce
/// two frames into one), so both sides frame explicitly.
///
/// Pure + deterministic — the socket I/O is the only live part (scrollbackd). The
/// receive path enforces a hard size cap BEFORE buffering the body, so a hostile
/// length prefix (e.g. `0xFFFFFFFF`) can never make the daemon allocate gigabytes.
public enum MCPFraming {
    /// Bounds a single frame. 1 MiB dwarfs any real recall response (a handful of
    /// chunk-sized snippets) yet caps a malicious client's per-frame allocation.
    public static let maxFrameSize = 1 << 20 // 1 MiB

    public enum FramingError: Error, Equatable {
        /// A declared length exceeded the cap. The stream is unrecoverable after this
        /// (we can't trust subsequent boundaries) — the caller MUST close the socket.
        case frameTooLarge(Int)
    }

    /// Frame a payload: 4-byte big-endian length + payload. Our own payloads are
    /// bounded by the recall `limit`, so this never approaches `maxFrameSize`.
    public static func encode(_ payload: Data) -> Data {
        let n = UInt32(truncatingIfNeeded: payload.count)
        var out = Data(capacity: 4 + payload.count)
        out.append(UInt8(truncatingIfNeeded: n >> 24))
        out.append(UInt8(truncatingIfNeeded: n >> 16))
        out.append(UInt8(truncatingIfNeeded: n >> 8))
        out.append(UInt8(truncatingIfNeeded: n))
        out.append(payload)
        return out
    }
}

/// Accumulates a byte stream and yields complete frames as they arrive. Feed it
/// whatever `read` returns; pull frames until it reports it needs more bytes. Not
/// thread-safe (own one per connection, on that connection's read thread).
public struct MCPFrameAccumulator {
    private var buffer = Data()
    public let maxFrameSize: Int

    public init(maxFrameSize: Int = MCPFraming.maxFrameSize) {
        self.maxFrameSize = maxFrameSize
    }

    public mutating func append(_ bytes: Data) { buffer.append(bytes) }

    /// The next complete frame, or `nil` if more bytes are needed. Throws
    /// `frameTooLarge` if a length prefix exceeds the cap — checked BEFORE waiting
    /// for (or allocating) the body, so an oversized declaration is rejected on the
    /// header alone.
    public mutating func nextFrame() throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        // Read the 4-byte big-endian length from the front, index-safe regardless of
        // any slice offset the buffer may carry.
        let base = buffer.startIndex
        let length = (Int(buffer[base]) << 24)
            | (Int(buffer[base + 1]) << 16)
            | (Int(buffer[base + 2]) << 8)
            | Int(buffer[base + 3])
        guard length <= maxFrameSize else { throw MCPFraming.FramingError.frameTooLarge(length) }
        let total = 4 + length
        guard buffer.count >= total else { return nil }
        let frame = buffer.subdata(in: base.advanced(by: 4) ..< base.advanced(by: total))
        buffer.removeSubrange(base ..< base.advanced(by: total))
        return frame
    }
}
