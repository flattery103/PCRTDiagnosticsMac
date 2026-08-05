#if os(macOS)
import Foundation
import Darwin

public enum UnixSocketError: LocalizedError {
    case systemCall(String, Int32)
    case pathTooLong
    case disconnected
    case invalidPeer(expected: uid_t, actual: uid_t)

    public var errorDescription: String? {
        switch self {
        case .systemCall(let name, let code): return "\(name) failed: \(String(cString: strerror(code))) (\(code))"
        case .pathTooLong: return "The Unix socket path is too long."
        case .disconnected: return "The helper connection closed."
        case .invalidPeer(let expected, let actual): return "Unexpected socket peer UID \(actual); expected \(expected)."
        }
    }
}

public final class UnixSocketConnection {
    public typealias MessageHandler = (IPCMessage) -> Void
    public typealias DisconnectHandler = (Error?) -> Void

    private let descriptor: Int32
    private let readQueue = DispatchQueue(label: "com.pcrepairtools.pcrt.socket.read")
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var closed = false
    private var readBuffer = Data()
    private var onMessage: MessageHandler?
    private var onDisconnect: DisconnectHandler?

    public init(descriptor: Int32) {
        self.descriptor = descriptor
        var enabled: Int32 = 1
        _ = withUnsafePointer(to: &enabled) { pointer in
            Darwin.setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, pointer, socklen_t(MemoryLayout<Int32>.size))
        }
    }

    deinit { close() }

    public func peerCredentials() throws -> (uid: uid_t, gid: gid_t) {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(descriptor, &uid, &gid) == 0 else {
            throw UnixSocketError.systemCall("getpeereid", errno)
        }
        return (uid, gid)
    }

    public func requirePeer(uid expectedUID: uid_t) throws {
        let actual = try peerCredentials().uid
        guard actual == expectedUID else { throw UnixSocketError.invalidPeer(expected: expectedUID, actual: actual) }
    }

    public func startReading(onMessage: @escaping MessageHandler, onDisconnect: @escaping DisconnectHandler) {
        self.onMessage = onMessage
        self.onDisconnect = onDisconnect
        readQueue.async { [weak self] in self?.readLoop() }
    }

    public func send(_ message: IPCMessage) throws {
        let data = try LineDelimitedJSON.encode(message)
        try writeAll(data)
    }

    public func close() {
        stateLock.lock()
        if closed {
            stateLock.unlock()
            return
        }
        closed = true
        stateLock.unlock()
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    private func writeAll(_ data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        var sent = 0
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            while sent < data.count {
                let result = Darwin.write(descriptor, base.advanced(by: sent), data.count - sent)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw UnixSocketError.systemCall("write", errno)
                }
                if result == 0 { throw UnixSocketError.disconnected }
                sent += result
            }
        }
    }

    private func readLoop() {
        var temporary = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = temporary.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress, buffer.count)
            }
            if count > 0 {
                readBuffer.append(contentsOf: temporary.prefix(count))
                do {
                    let messages = try LineDelimitedJSON.decodeMessages(buffer: &readBuffer)
                    for message in messages { onMessage?(message) }
                } catch {
                    onDisconnect?(error)
                    close()
                    return
                }
            } else if count == 0 {
                onDisconnect?(nil)
                close()
                return
            } else if errno != EINTR {
                let error = UnixSocketError.systemCall("read", errno)
                onDisconnect?(error)
                close()
                return
            }
        }
    }
}

public final class UnixSocketListener {
    private let path: String
    private let acceptQueue = DispatchQueue(label: "com.pcrepairtools.pcrt.socket.accept")
    private var descriptor: Int32 = -1
    private var connection: UnixSocketConnection?

    public init(path: String) {
        self.path = path
    }

    deinit { stop() }

    public func start(onAccept: @escaping (Result<UnixSocketConnection, Error>) -> Void) throws {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.systemCall("socket", errno) }
        do {
            try withUnixAddress(path: path) { address, length in
                guard Darwin.bind(fd, address, length) == 0 else { throw UnixSocketError.systemCall("bind", errno) }
            }
            guard chmod(path, S_IRUSR | S_IWUSR) == 0 else { throw UnixSocketError.systemCall("chmod", errno) }
            guard Darwin.listen(fd, 1) == 0 else { throw UnixSocketError.systemCall("listen", errno) }
            descriptor = fd
        } catch {
            Darwin.close(fd)
            unlink(path)
            throw error
        }

        acceptQueue.async { [weak self] in
            guard let self = self else { return }
            let clientFD = Darwin.accept(fd, nil, nil)
            if clientFD < 0 {
                onAccept(.failure(UnixSocketError.systemCall("accept", errno)))
                return
            }
            let connection = UnixSocketConnection(descriptor: clientFD)
            self.connection = connection
            onAccept(.success(connection))
        }
    }

    public func stop() {
        connection?.close()
        connection = nil
        if descriptor >= 0 {
            Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
            descriptor = -1
        }
        unlink(path)
    }
}

public enum UnixSocketClient {
    public static func connect(path: String) throws -> UnixSocketConnection {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.systemCall("socket", errno) }
        do {
            try withUnixAddress(path: path) { address, length in
                guard Darwin.connect(fd, address, length) == 0 else { throw UnixSocketError.systemCall("connect", errno) }
            }
            return UnixSocketConnection(descriptor: fd)
        } catch {
            Darwin.close(fd)
            throw error
        }
    }
}

private func withUnixAddress<T>(path: String, body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
    let utf8 = Array(path.utf8CString)
    var address = sockaddr_un()
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard utf8.count <= capacity else { throw UnixSocketError.pathTooLong }
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        let destination = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self)
        for index in 0..<utf8.count { destination[index] = utf8[index] }
    }
    let length = socklen_t(MemoryLayout<UInt8>.size + MemoryLayout<sa_family_t>.size + utf8.count)
    address.sun_len = UInt8(min(Int(length), Int(UInt8.max)))
    return try withUnsafePointer(to: &address) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            try body(sockaddrPointer, length)
        }
    }
}
#endif
