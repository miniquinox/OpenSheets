import Darwin
import Foundation
import SheetModel
import Synchronization

/// Where protocol frames are written, and the reason nothing else can write there.
///
/// # The failure this exists to make impossible
///
/// MCP over stdio is newline-delimited JSON on file descriptor 1. One stray `print` anywhere
/// in the process — in our code, in a dependency, in a `#if DEBUG` someone left in — puts a
/// non-JSON line into the stream. The client's parser then fails on a frame that has nothing
/// to do with the tool that was called, and the resulting bug report says *"Claude Code says
/// the server crashed"* while the server is fine.
///
/// A lint test that greps for `print` catches our own code once. This catches everything,
/// forever, including code we did not write: ``claimStdout()`` **duplicates fd 1 to a private
/// descriptor and then points fd 1 at fd 2**. After it returns, `print`, `FileHandle
/// .standardOutput`, `fputs(stdout)` and anything else aiming at "standard output" reaches
/// *stderr*, where it is harmless and still visible in the client's server log. The only way
/// to the real stream is this object.
public final class ProtocolStream: Sendable {
    private struct State {
        var descriptor: Int32
        var isOpen: Bool
    }

    private let state: Mutex<State>

    /// Wraps an already-open descriptor. Tests pass a pipe.
    public init(descriptor: Int32) {
        state = Mutex(State(descriptor: descriptor, isOpen: true))
    }

    /// Takes ownership of standard output and redirects fd 1 to fd 2.
    ///
    /// Call **once**, before anything else runs. Returns a stream over the real standard
    /// output; every other writer in the process now lands on stderr.
    public static func claimStdout() -> ProtocolStream {
        let saved = dup(STDOUT_FILENO)
        // `dup` failing means the process has no stdout to protect — writing frames into a
        // descriptor that is not there would be worse than writing them to the one we have.
        guard saved >= 0 else { return ProtocolStream(descriptor: STDOUT_FILENO) }
        _ = fcntl(saved, F_SETFD, FD_CLOEXEC)
        // From here on, "standard output" is standard error.
        _ = dup2(STDERR_FILENO, STDOUT_FILENO)
        setvbuf(Darwin.stdout, nil, _IOLBF, 0)
        return ProtocolStream(descriptor: saved)
    }

    /// Writes one frame, followed by the newline that delimits it.
    ///
    /// The whole frame is written under one lock and with `write(2)` retried to completion, so
    /// two concurrent tool results can never interleave halfway through a line.
    public func send(_ value: JSONValue) {
        var line = value.rendered
        // A rendered frame cannot contain a raw newline — `JSONValue` escapes every control
        // character — but asserting it here costs nothing and documents the invariant the
        // delimiter depends on.
        line = line.replacingOccurrences(of: "\n", with: "")
        line += "\n"
        write(Array(line.utf8))
    }

    private func write(_ bytes: [UInt8]) {
        state.withLock { state in
            guard state.isOpen else { return }
            var offset = 0
            bytes.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                while offset < buffer.count {
                    let written = Darwin.write(state.descriptor, base.advanced(by: offset), buffer.count - offset)
                    if written > 0 {
                        offset += written
                    } else if written < 0, errno == EINTR {
                        continue
                    } else {
                        // The peer closed the pipe. Nothing to report to — reporting would
                        // itself be a write — so stop trying rather than spinning.
                        state.isOpen = false
                        return
                    }
                }
            }
        }
    }

    /// Stops accepting frames. The descriptor is left open; the process owns it.
    public func close() {
        state.withLock { $0.isOpen = false }
    }
}

/// Diagnostics, which never go anywhere near the protocol stream.
///
/// Off by default: an MCP server that chatters on stderr fills the client's log with noise
/// nobody reads. `OPENSHEETS_MCP_LOG=1` turns it on, `OPENSHEETS_MCP_LOG=<path>` sends it to a
/// file instead.
public struct MCPLog: Sendable {
    /// Where a line goes.
    public enum Destination: Sendable, Hashable {
        case none
        case standardError
        case file(String)
    }

    public var destination: Destination

    public init(destination: Destination) {
        self.destination = destination
    }

    /// Reads `OPENSHEETS_MCP_LOG`.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment)
        -> MCPLog {
        guard let setting = environment["OPENSHEETS_MCP_LOG"], !setting.isEmpty else {
            return MCPLog(destination: .none)
        }
        switch setting {
        case "0", "off", "false": return MCPLog(destination: .none)
        case "1", "on", "true", "stderr": return MCPLog(destination: .standardError)
        default: return MCPLog(destination: .file(setting))
        }
    }

    /// Writes one line. Never throws: a logger that can fail a tool call is worse than no log.
    public func write(_ message: @autoclosure () -> String) {
        switch destination {
        case .none:
            return
        case .standardError:
            let line = "[opensheets-mcp] \(message())\n"
            FileHandle.standardError.write(Data(line.utf8))
        case let .file(path):
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(message())\n"
            guard let handle = FileHandle(forWritingAtPath: path) else {
                try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
                return
            }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            handle.write(Data(line.utf8))
        }
    }
}

/// Reads newline-delimited frames from a descriptor.
///
/// A hand-rolled reader rather than `FileHandle.bytes`: the stream must survive a frame larger
/// than one `read(2)`, a partial line at EOF, and a CRLF-terminated client, and it must stop
/// growing its buffer when a peer sends a line that never ends. ``Limits/maxFileBytes`` is not
/// the right ceiling for a protocol frame, so this carries its own.
public struct FrameReader: Sendable {
    /// The largest single frame accepted. A `write_range` of a 100 × 100 block is roughly
    /// 200 KB; 32 MB is far past any legitimate call and far short of a memory problem.
    public static let maximumFrameBytes = 32 * 1024 * 1024

    private let descriptor: Int32

    public init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// One frame's bytes, or `nil` at end of stream.
    ///
    /// Blocking, on purpose. The server is a request/response loop with one peer; an async
    /// reader would buy concurrency there is nothing to overlap with, and would make "the
    /// client closed stdin, exit cleanly" a race instead of a return value.
    public func nextFrame(buffer: inout [UInt8]) throws(SheetError) -> [UInt8]? {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let index = buffer.firstIndex(of: 0x0A) {
                let line = Array(buffer[buffer.startIndex ..< index])
                buffer.removeFirst(index - buffer.startIndex + 1)
                if line.isEmpty || line == [0x0D] { continue }
                return line.last == 0x0D ? Array(line.dropLast()) : line
            }
            guard buffer.count <= FrameReader.maximumFrameBytes else {
                throw SheetError.resultTooLarge(bytes: buffer.count, limit: FrameReader.maximumFrameBytes)
            }
            let read = chunk.withUnsafeMutableBytes { pointer -> Int in
                guard let base = pointer.baseAddress else { return 0 }
                return Darwin.read(descriptor, base, pointer.count)
            }
            if read > 0 {
                buffer.append(contentsOf: chunk[0 ..< read])
            } else if read == 0 {
                guard !buffer.isEmpty else { return nil }
                let line = buffer
                buffer.removeAll()
                return line
            } else if errno != EINTR {
                return nil
            }
        }
    }
}
