import XCTest
import Darwin
@testable import HomeKitMCPCore

@MainActor private final class LifecycleBackend: HomeKitBackend {
    let home = UUID()
    let room = UUID()
    let accessory = UUID()
    var unavailable = false
    var hold = false
    var gate: CheckedContinuation<Void, Never>?
    func homes() async throws -> [HomeSummary] { [] }
    func inventory(home: UUID) async throws -> Inventory {
        if hold { await withCheckedContinuation { gate = $0 } }
        if unavailable { throw BridgeError("SECRET HOUSEHOLD NAME AND IDENTIFIER") }
        return Inventory(home_uuid: home, rooms: [RoomRecord(uuid: room, name: "Private room")],
            accessories: [AccessoryRecord(uuid: accessory, name: "Private lamp", room_uuid: room, category: "light")])
    }
    func moveAccessory(home: UUID, accessory: UUID, room: UUID) async throws { XCTFail("No test should mutate HomeKit") }
    func renameAccessory(home: UUID, accessory: UUID, name: String) async throws { XCTFail("No test should mutate HomeKit") }
    func renameRoom(home: UUID, room: UUID, name: String) async throws { XCTFail("No test should mutate HomeKit") }
}

final class LifecycleTests: XCTestCase {
    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/hkl-\(UUID().uuidString)")
        try PrivateStorage.prepareDirectory(url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    @MainActor private func savePolicy(_ b: LifecycleBackend, _ directory: URL, writes: Bool = false) throws {
        try PrivateStorage.write(AccessPolicy(home_uuid: b.home, accessory_uuids: [b.accessory],
            editable_room_uuids: [b.room], allow_metadata_writes: writes), to: directory.appendingPathComponent("policy.json"))
    }
    private func tools(_ directory: URL) async throws -> String {
        let path = directory.appendingPathComponent("server.sock").path
        return try await Task.detached {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw BridgeError("fixture socket") }
            defer { close(fd) }
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8) + [0]
            withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
            let connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard connected == 0 else { throw BridgeError("fixture connect") }
            let request = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}\n".utf8)
            _ = request.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            var bytesRead = [UInt8](repeating: 0, count: 65536)
            let count = recv(fd, &bytesRead, bytesRead.count, 0)
            guard count > 0 else { throw BridgeError("fixture response") }
            return String(decoding: bytesRead.prefix(count), as: UTF8.self)
        }.value
    }
    @MainActor func testInitialLaunchAndMissingScopeNeverInstantiateHomeKit() async throws {
        let directory = try directory(); var factories = 0
        let lifecycle = try BridgeLifecycle(directory: directory) { factories += 1; return LifecycleBackend() }
        await lifecycle.restoreIfRequested()
        XCTAssertEqual(factories, 0)
        await lifecycle.start(readOnly: true)
        XCTAssertEqual(factories, 0); XCTAssertEqual(lifecycle.state.phase, "needs_configuration")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("server.sock").path))
    }
    @MainActor func testResumeIgnoresSavedWritePermissionAndKeepsPolicyUnchanged() async throws {
        let directory = try directory(); let b = LifecycleBackend()
        try savePolicy(b, directory, writes: true)
        var preferences = RuntimePreferences(); preferences.resume_read_only = true
        try PrivateStorage.write(preferences, to: directory.appendingPathComponent("runtime.json"))
        let lifecycle = try BridgeLifecycle(directory: directory) { b }
        await lifecycle.restoreIfRequested()
        defer { lifecycle.stop() }
        XCTAssertTrue(lifecycle.active); XCTAssertTrue(lifecycle.state.read_only)
        let response = try await tools(directory)
        XCTAssertTrue(response.contains("get_all_accessories")); XCTAssertFalse(response.contains("rename_accessory"))
        XCTAssertTrue(try PrivateStorage.readPolicy(directory).allow_metadata_writes)
    }
    @MainActor func testExplicitStopDuringStartupCannotResurrectEndpoint() async throws {
        let directory = try directory(); let b = LifecycleBackend(); b.hold = true
        try savePolicy(b, directory)
        let lifecycle = try BridgeLifecycle(directory: directory) { b }
        let pending = Task { await lifecycle.start(readOnly: true) }
        while b.gate == nil { await Task.yield() }
        lifecycle.stop()
        b.gate?.resume(); b.gate = nil
        await pending.value
        XCTAssertFalse(lifecycle.active); XCTAssertFalse(lifecycle.preferences.resume_read_only)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("server.sock").path))
    }
    @MainActor func testHomeOutageRecoversOnExistingEndpointAndLogsNoHouseholdData() async throws {
        let directory = try directory(); let b = LifecycleBackend()
        try savePolicy(b, directory)
        let lifecycle = try BridgeLifecycle(directory: directory) { b }
        await lifecycle.start(readOnly: true)
        defer { lifecycle.stop() }
        b.unavailable = true; await lifecycle.checkHealth()
        XCTAssertTrue(lifecycle.active); XCTAssertEqual(lifecycle.state.phase, "home_unavailable")
        b.unavailable = false; await lifecycle.checkHealth()
        XCTAssertEqual(lifecycle.state.phase, "running")
        _ = try await tools(directory)
        for filename in ["status.json", "status-journal.json"] {
            let data = try String(contentsOf: directory.appendingPathComponent(filename))
            for secret in ["SECRET", "Private room", "Private lamp", b.home.uuidString] { XCTAssertFalse(data.contains(secret)) }
            let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(filename).path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o600)
        }
    }
    @MainActor func testPausePersistsAndDoesNotRestoreOnNextLaunch() async throws {
        let directory = try directory(); let b = LifecycleBackend()
        try savePolicy(b, directory)
        var first: BridgeLifecycle? = try BridgeLifecycle(directory: directory) { b }
        await first?.start(readOnly: true)
        first?.stop(); first = nil
        var factories = 0
        let next = try BridgeLifecycle(directory: directory) { factories += 1; return b }
        await next.restoreIfRequested()
        XCTAssertFalse(next.active); XCTAssertEqual(factories, 0)
    }
    @MainActor func testQuitPreservesResumeIntentButNextLaunchIsReadOnly() async throws {
        let directory = try directory(); let b = LifecycleBackend()
        try savePolicy(b, directory, writes: true)
        var first: BridgeLifecycle? = try BridgeLifecycle(directory: directory) { b }
        await first?.start(readOnly: false)
        XCTAssertEqual(first?.state.read_only, false)
        first?.stop(pause: false); first = nil
        let next = try BridgeLifecycle(directory: directory) { b }
        await next.restoreIfRequested()
        defer { next.stop() }
        XCTAssertTrue(next.active); XCTAssertTrue(next.state.read_only)
        let response = try await tools(directory)
        XCTAssertFalse(response.contains("rename_room"))
    }
    @MainActor func testSecondInstanceCannotOverwriteStatusOrInstantiateBackend() async throws {
        let directory = try directory(); let b = LifecycleBackend()
        try savePolicy(b, directory)
        let first = try BridgeLifecycle(directory: directory) { b }
        await first.start(readOnly: true)
        defer { first.stop() }
        let before = try Data(contentsOf: directory.appendingPathComponent("status.json"))
        XCTAssertThrowsError(try BridgeLifecycle(directory: directory) { XCTFail("Second factory"); return b })
        XCTAssertEqual(before, try Data(contentsOf: directory.appendingPathComponent("status.json")))
    }
}
