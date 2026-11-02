// Historical filename retained for the Xcode project. There is NO HTTP/TCP server.
import Foundation
import Darwin

public enum PrivateStorage {
    public static var defaultDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/HomeKitMCP")
    }
    public static func prepareDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0
        else { throw BridgeError("Runtime directory must be an owned, private directory, not a symlink") }
    }
    public static func readPolicy(_ directory: URL) throws -> AccessPolicy {
        try prepareDirectory(directory)
        let file = directory.appendingPathComponent("policy.json")
        var info = stat()
        if lstat(file.path, &info) != 0 {
            guard errno == ENOENT else { throw BridgeError("Cannot inspect policy") }
            return AccessPolicy()
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0, info.st_size <= 131072
        else { throw BridgeError("Policy must be an owned private regular file") }
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw BridgeError("Cannot open policy") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let policy = try JSONDecoder().decode(AccessPolicy.self, from: handle.readToEnd() ?? Data())
        try policy.validate()
        return policy
    }
    public static func write<T: Encodable>(_ value: T, to file: URL) throws {
        try prepareDirectory(file.deletingLastPathComponent())
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw BridgeError("Cannot create private journal") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        defer { close(fd); unlink(temporary.path) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try handle.write(contentsOf: encoder.encode(value))
        guard fsync(fd) == 0, fcntl(fd, F_FULLFSYNC, 0) == 0, rename(temporary.path, file.path) == 0
        else { throw BridgeError("Cannot persist private journal") }
        let parentFD = open(file.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parentFD >= 0 else { throw BridgeError("Cannot open journal directory") }
        defer { close(parentFD) }
        guard fsync(parentFD) == 0, fcntl(fd, F_FULLFSYNC, 0) == 0
        else { throw BridgeError("Cannot durably persist journal directory") }
    }
    public static func journal(in directory: URL) -> (OperationRecord, Inventory) throws -> Void {
        struct Entry: Encodable { let operation: OperationRecord; let before: Inventory }
        return { record, inventory in
            try write(Entry(operation: record, before: inventory),
                      to: directory.appendingPathComponent("journal/operation-\(record.operation_uuid.uuidString).json"))
        }
    }
    public static func loadOperations(in directory: URL) throws -> [OperationRecord] {
        struct Entry: Decodable { let operation: OperationRecord; let before: Inventory }
        let journal = directory.appendingPathComponent("journal")
        try prepareDirectory(journal)
        let files = try FileManager.default.contentsOfDirectory(at: journal, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        guard files.count <= 1000 else { throw BridgeError("Journal limit reached; archive reviewed records") }
        return try files.map { file in
            var info = stat()
            guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == geteuid(), info.st_mode & 0o077 == 0, info.st_size <= 2_097_152
            else { throw BridgeError("Journal must contain private owned regular files") }
            let fd = open(file.path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { throw BridgeError("Cannot open journal") }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            let entry = try JSONDecoder().decode(Entry.self, from: handle.readToEnd() ?? Data())
            let record = entry.operation
            guard file.lastPathComponent == "operation-\(record.operation_uuid.uuidString).json",
                  entry.before.home_uuid == record.home_uuid,
                  ["pending", "succeeded", "unconfirmed"].contains(record.status),
                  ["set_accessory_room", "rename_accessory", "rename_room"].contains(record.tool)
            else { throw BridgeError("Invalid operation journal") }
            return record
        }
    }
}

public final class LocalMCPServer: @unchecked Sendable {
    public static let maximumFrameBytes = 1_048_576
    private let queue = DispatchQueue(label: "homekit.local.listener")
    private let lock = NSLock()
    private var listener: DispatchSourceRead?
    private var listenerFD: Int32 = -1
    private var sessions: [UUID: SocketSession] = [:]
    private var boundIdentity: (dev_t, ino_t)?
    private let socketPath: String
    private let handler: @Sendable (Data) async -> Data?

    public init(directory: URL, handler: @escaping @Sendable (Data) async -> Data?) throws {
        try PrivateStorage.prepareDirectory(directory)
        socketPath = directory.appendingPathComponent("server.sock").path
        guard socketPath.utf8.count < 104 else { throw BridgeError("Unix socket path is too long") }
        self.handler = handler
    }
    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard listenerFD < 0 else { return }
        var old = stat()
        if lstat(socketPath, &old) == 0 {
            guard old.st_mode & S_IFMT == S_IFSOCK, old.st_uid == geteuid()
            else { throw BridgeError("Refusing to replace a non-owned socket path") }
            // Never remove another running server's endpoint.
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            guard probe >= 0 else { throw BridgeError("Cannot probe socket") }
            let connected = withAddress { Darwin.connect(probe, $0, $1) }
            let savedError = errno; close(probe)
            guard connected != 0 && savedError == ECONNREFUSED else { throw BridgeError("Socket is already in use") }
            guard unlink(socketPath) == 0 else { throw BridgeError("Cannot remove stale socket") }
        } else if errno != ENOENT { throw BridgeError("Cannot inspect socket path") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeError("Cannot create Unix socket") }
        guard withAddress({ Darwin.bind(fd, $0, $1) }) == 0 else { close(fd); throw BridgeError("Cannot bind Unix socket") }
        guard chmod(socketPath, 0o600) == 0, listen(fd, 4) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            close(fd); unlink(socketPath); throw BridgeError("Cannot secure/listen on Unix socket")
        }
        var bound = stat()
        guard lstat(socketPath, &bound) == 0 else { close(fd); throw BridgeError("Cannot inspect bound socket") }
        boundIdentity = (bound.st_dev, bound.st_ino); listenerFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClients(fd) }
        source.setCancelHandler { close(fd) }
        listener = source; source.resume()
    }
    private func withAddress<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8) + [0]
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
    private func acceptClients(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { return }
            // Darwin accepts can inherit O_NONBLOCK from the listening socket.
            // Worker sessions use bounded blocking reads instead.
            let flags = fcntl(client, F_GETFL, 0)
            guard flags >= 0, fcntl(client, F_SETFL, flags & ~O_NONBLOCK) == 0 else { close(client); continue }
            var uid = uid_t(), gid = gid_t()
            guard getpeereid(client, &uid, &gid) == 0, uid == geteuid() else { close(client); continue }
            lock.lock()
            guard listenerFD == fd, sessions.count < 4 else { lock.unlock(); close(client); continue }
            let id = UUID()
            let session = SocketSession(fd: client, handler: handler) { [weak self] in
                guard let self else { return }
                self.lock.lock(); self.sessions.removeValue(forKey: id); self.lock.unlock()
            }
            sessions[id] = session; lock.unlock()
            session.start()
        }
    }
    public func stop() {
        lock.lock()
        listenerFD = -1
        listener?.cancel(); listener = nil
        let clients = Array(sessions.values); sessions.removeAll()
        if let identity = boundIdentity {
            var current = stat()
            if lstat(socketPath, &current) == 0, current.st_dev == identity.0, current.st_ino == identity.1 {
                unlink(socketPath)
            }
        }
        boundIdentity = nil; lock.unlock()
        clients.forEach { $0.shutdown() }
    }
    deinit { stop() }
}

private final class SocketSession: @unchecked Sendable {
    private let fd: Int32
    private let handler: @Sendable (Data) async -> Data?
    private let finished: @Sendable () -> Void
    private let lock = NSLock()
    private var stopped = false
    init(fd: Int32, handler: @escaping @Sendable (Data) async -> Data?, finished: @escaping @Sendable () -> Void) {
        self.fd = fd; self.handler = handler; self.finished = finished
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        timeout.tv_sec = 5
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }
    func shutdown() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true; Darwin.shutdown(fd, SHUT_RDWR)
    }
    func start() { DispatchQueue.global(qos: .utility).async { self.run() } }
    private func run() {
        defer { lock.lock(); stopped = true; close(fd); lock.unlock(); finished() }
        var buffered = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = recv(fd, &bytes, bytes.count, 0)
            if count <= 0 { return }
            buffered.append(contentsOf: bytes.prefix(count))
            while let end = buffered.firstIndex(of: 10) {
                let frame = Data(buffered[..<end]); buffered.removeSubrange(...end)
                guard frame.count <= LocalMCPServer.maximumFrameBytes else { return }
                if frame.isEmpty { continue }
                let done = DispatchSemaphore(value: 0)
                Task {
                    let response = await handler(frame)
                    if let response { self.send(response + Data([10])) }
                    done.signal()
                }
                // This background worker never blocks the HomeKit/main queue.
                // On timeout the connection closes; an accepted mutation remains
                // journaled and must be queried, never automatically re-submitted.
                guard done.wait(timeout: .now() + 30) == .success else { return }
            }
            guard buffered.count <= LocalMCPServer.maximumFrameBytes else { return }
        }
    }
    private func send(_ data: Data) {
        guard data.count <= LocalMCPServer.maximumFrameBytes else { shutdown(); return }
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if count <= 0 { stopped = true; Darwin.shutdown(fd, SHUT_RDWR); return }
                offset += count
            }
        }
    }
}
