import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum UnixSocketError: Error, CustomStringConvertible {
    case system(String, Int32)
    case closed
    case pathTooLong

    public var description: String {
        switch self {
        case let .system(op, code): return "\(op): \(String(cString: strerror(code)))"
        case .closed: return "connection closed"
        case .pathTooLong: return "socket path too long"
        }
    }
}

/// Minimal blocking Unix-domain socket helpers shared by helper, CLI and app.
public enum UnixSocket {
    public static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString) // includes trailing NUL
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw UnixSocketError.pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            bytes.withUnsafeBytes { src in dst.copyMemory(from: src) }
        }
        return addr
    }

    public static func withSockaddr<R>(_ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
        withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    public static func setTimeout(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, size)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, size)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    public static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw UnixSocketError.system("write", errno)
                }
                off += n
            }
        }
    }

    public static func readExactly(_ fd: Int32, _ count: Int) throws -> Data {
        var data = Data(count: count)
        var off = 0
        try data.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
            while off < count {
                let n = Darwin.read(fd, buf.baseAddress! + off, count - off)
                if n == 0 { throw UnixSocketError.closed }
                if n < 0 {
                    if errno == EINTR { continue }
                    throw UnixSocketError.system("read", errno)
                }
                off += n
            }
        }
        return data
    }

    /// Reads one length-prefixed frame and returns the JSON body.
    public static func readFrame(_ fd: Int32, maxSize: Int) throws -> Data {
        let n = try IPCFraming.length(fromHeader: readExactly(fd, 4))
        guard n <= maxSize else { throw IPCError.frameTooLarge(n) }
        return try readExactly(fd, n)
    }

    /// Connects to the helper, sends one request and waits for the response.
    public static func request(_ req: Request, path: String = wgbarSocketPath, timeout: Int = 3) throws -> Response {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.system("socket", errno) }
        defer { close(fd) }
        setTimeout(fd, seconds: timeout)
        var addr = try address(path)
        let rc = withSockaddr(&addr) { Darwin.connect(fd, $0, $1) }
        guard rc == 0 else { throw UnixSocketError.system("connect \(path)", errno) }
        try writeAll(fd, IPCFraming.encode(req))
        let body = try readFrame(fd, maxSize: IPCFraming.maxFrameSize)
        return try IPCFraming.decodeBody(Response.self, from: body)
    }
}
