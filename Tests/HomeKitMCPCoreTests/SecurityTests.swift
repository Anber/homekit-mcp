import XCTest
@testable import HomeKitMCPCore

@MainActor private final class FakeBackend: HomeKitBackend {
    let home = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let room = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let next = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    let accessory = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    let other = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    var state: Inventory!
    var writes = 0
    var skipChange = false
    var beforeWrite: (() -> Void)?
    var inventoryDelays: [UInt64] = []
    init() {
        state = Inventory(home_uuid: home, rooms: [RoomRecord(uuid: room, name: "Office"), RoomRecord(uuid: next, name: "Bedroom")],
            accessories: [AccessoryRecord(uuid: accessory, name: "Lamp", room_uuid: room, category: "light"),
                          AccessoryRecord(uuid: other, name: "Lamp duplicate", room_uuid: room, category: "garage")])
    }
    func homes() async throws -> [HomeSummary] { [HomeSummary(uuid: home, name: "Test home")] }
    func inventory(home: UUID) async throws -> Inventory {
        if !inventoryDelays.isEmpty {
            let delay = inventoryDelays.removeFirst()
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        }
        return state
    }
    func moveAccessory(home: UUID, accessory: UUID, room: UUID) async throws {
        writes += 1; beforeWrite?()
        try await Task.sleep(nanoseconds: 30_000_000)
        if !skipChange { state.accessories[0].room_uuid = room }
    }
    func renameAccessory(home: UUID, accessory: UUID, name: String) async throws {
        writes += 1; beforeWrite?()
        if !skipChange { state.accessories[0].name = name }
    }
    func renameRoom(home: UUID, room: UUID, name: String) async throws {
        writes += 1; beforeWrite?()
        if !skipChange { state.rooms[0].name = name }
    }
}

final class SecurityTests: XCTestCase {
    @MainActor private func setup(writes: Bool = false, journal: @escaping (OperationRecord, Inventory) throws -> Void = { _, _ in }) throws -> (FakeBackend, MCPDispatcher) {
        let backend = FakeBackend()
        let policy = AccessPolicy(home_uuid: backend.home, accessory_uuids: [backend.accessory],
                                  editable_room_uuids: [backend.room], allow_metadata_writes: writes)
        return (backend, try MCPDispatcher(backend: backend, policy: policy, journal: journal))
    }
    @MainActor private func rpc(_ dispatcher: MCPDispatcher, method: String = "tools/call",
                               params: [String: JSONValue], id: JSONValue = .string("test")) async throws -> JSONValue {
        let request = JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "method": .string(method), "params": .object(params)])
        let data = try JSONEncoder().encode(request)
        return try JSONDecoder().decode(JSONValue.self, from: await dispatcher.handle(data)!)
    }
    @MainActor private func call(_ dispatcher: MCPDispatcher, _ tool: String, _ args: [String: JSONValue] = [:]) async throws -> JSONValue {
        try await rpc(dispatcher, params: ["name": .string(tool), "arguments": .object(args)]).object!["result"]!
    }
    @MainActor private func assertCall(_ dispatcher: MCPDispatcher, _ tool: String,
                                      _ args: [String: JSONValue] = [:], isError: Bool) async throws {
        let result = try await call(dispatcher, tool, args)
        XCTAssertEqual(result.object?["isError"], .bool(isError))
    }
    @MainActor private func move(_ b: FakeBackend, request: UUID = UUID()) -> [String: JSONValue] {
        ["home_uuid": .string(b.home.uuidString), "request_uuid": .string(request.uuidString),
         "accessory_uuid": .string(b.accessory.uuidString), "room_uuid": .string(b.next.uuidString),
         "expected_name": .string("Lamp"), "expected_room_uuid": .string(b.room.uuidString)]
    }
    @MainActor private func completed(_ dispatcher: MCPDispatcher, operation: JSONValue) async throws -> JSONValue {
        let id = operation.object!["structuredContent"]!.object!["operation_uuid"]!
        for _ in 0..<100 {
            let result = try await call(dispatcher, "get_operation", ["operation_uuid": id])
            if result.object?["structuredContent"]?.object?["status"] != .string("pending") { return result }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Fixture operation failed to finish"); return .null
    }
    @MainActor func testReadOnlyIsEnforcedOnDirectWriteCall() async throws {
        let (b, d) = try setup()
        let result = try await call(d, "set_accessory_room", move(b))
        XCTAssertEqual(result.object?["isError"], .bool(true)); XCTAssertEqual(b.writes, 0)
        let tools = try await rpc(d, method: "tools/list", params: [:])
        XCTAssertFalse(String(data: try JSONEncoder().encode(tools), encoding: .utf8)!.contains("rename_accessory"))
    }
    @MainActor func testInventoryFiltersAccessoryAllowlist() async throws {
        let (_, d) = try setup()
        let result = try await call(d, "get_all_accessories")
        let content = result.object!["structuredContent"]!.object!["accessories"]!
        guard case .array(let records) = content else { return XCTFail() }
        XCTAssertEqual(records.count, 1)
    }
    @MainActor func testBootstrapHasNoInventoryOrWrites() async throws {
        let b = FakeBackend(), d = try MCPDispatcher(backend: FakeBackend(), policy: AccessPolicy(), journal: { _, _ in })
        try await assertCall(d, "list_homes", isError: false)
        try await assertCall(d, "get_all_accessories", isError: true)
        try await assertCall(d, "set_accessory_room", move(b), isError: true)
    }
    @MainActor func testWrongHomeAccessoryAndRoomAreDenied() async throws {
        let (b, d) = try setup(writes: true)
        for field in ["home_uuid", "accessory_uuid", "room_uuid"] {
            var args = move(b); args[field] = .string(b.other.uuidString)
            try await assertCall(d, "set_accessory_room", args, isError: true)
        }
        XCTAssertEqual(b.writes, 0)
    }
    @MainActor func testStalePlanIsDenied() async throws {
        let (b, d) = try setup(writes: true)
        var args = move(b); args["expected_name"] = .string("Lam")
        try await assertCall(d, "set_accessory_room", args, isError: true)
        args = move(b); args["expected_room_uuid"] = .string(b.next.uuidString)
        try await assertCall(d, "set_accessory_room", args, isError: true)
        XCTAssertEqual(b.writes, 0)
    }
    @MainActor func testLegacyNameMatchingAndAllActuatorsAreAbsent() async throws {
        let (b, d) = try setup(writes: true)
        for tool in ["accessory_on", "accessory_off", "accessory_toggle", "set_accessory_room_by_name"] {
            try await assertCall(d, tool, ["accessory_name": .string("Lamp")], isError: true)
        }
        var args = move(b); args["accessory_name"] = .string("Lamp")
        try await assertCall(d, "set_accessory_room", args, isError: true)
        XCTAssertEqual(b.writes, 0)
    }
    @MainActor func testJournalFailurePreventsMutation() async throws {
        let (b, d) = try setup(writes: true, journal: { _, _ in throw BridgeError("Disk failure") })
        try await assertCall(d, "set_accessory_room", move(b), isError: true)
        XCTAssertEqual(b.writes, 0)
    }
    @MainActor func testPendingOperationDoesNotBlockReadsAndDuplicateRequestIsIdempotent() async throws {
        var snapshots: [Inventory] = []
        let (b, d) = try setup(writes: true, journal: { _, inventory in snapshots.append(inventory) })
        b.beforeWrite = { XCTAssertEqual(snapshots.first?.accessories.first?.room_uuid, b.room) }
        let args = move(b)
        let accepted = try await call(d, "set_accessory_room", args)
        XCTAssertEqual(accepted.object?["structuredContent"]?.object?["status"], .string("pending"))
        let duplicate = try await call(d, "set_accessory_room", args)
        XCTAssertEqual(accepted.object?["structuredContent"]?.object?["operation_uuid"],
                       duplicate.object?["structuredContent"]?.object?["operation_uuid"])
        try await assertCall(d, "get_all_rooms", isError: false)
        let done = try await completed(d, operation: accepted)
        XCTAssertEqual(done.object?["structuredContent"]?.object?["status"], .string("succeeded"))
        XCTAssertEqual(b.writes, 1)
    }
    @MainActor func testRequestIDCannotBeReusedForDifferentArguments() async throws {
        let (b, d) = try setup(writes: true)
        var args = move(b)
        _ = try await call(d, "set_accessory_room", args)
        args["room_uuid"] = .string(b.room.uuidString)
        try await assertCall(d, "set_accessory_room", args, isError: true)
    }
    @MainActor func testUnconfirmedOutcomeBlocksFurtherWrites() async throws {
        let (b, d) = try setup(writes: true); b.skipChange = true
        let accepted = try await call(d, "set_accessory_room", move(b))
        let done = try await completed(d, operation: accepted)
        XCTAssertEqual(done.object?["structuredContent"]?.object?["status"], .string("unconfirmed"))
        try await assertCall(d, "set_accessory_room", move(b), isError: true)
        XCTAssertEqual(b.writes, 1)
    }
    @MainActor func testRenameRequiresFullIdentityAndRoomPermission() async throws {
        let (b, d) = try setup(writes: true)
        let bad: [String: JSONValue] = ["home_uuid": .string(b.home.uuidString),
            "request_uuid": .string(UUID().uuidString), "room_uuid": .string(b.next.uuidString),
            "expected_name": .string("Bedroom"), "new_name": .string("Other")]
        try await assertCall(d, "rename_room", bad, isError: true)
        let args: [String: JSONValue] = ["home_uuid": .string(b.home.uuidString),
            "request_uuid": .string(UUID().uuidString), "accessory_uuid": .string(b.accessory.uuidString),
            "expected_name": .string("Lamp"), "expected_room_uuid": .string(b.room.uuidString), "new_name": .string("Desk")]
        let accepted = try await call(d, "rename_accessory", args)
        let done = try await completed(d, operation: accepted)
        XCTAssertEqual(done.object?["structuredContent"]?.object?["status"], .string("succeeded"))
    }
    @MainActor func testNotificationCannotInvokeWriteAndStringIDsWork() async throws {
        let (b, d) = try setup(writes: true)
        let notification = JSONValue.object(["jsonrpc": .string("2.0"), "method": .string("tools/call"),
            "params": .object(["name": .string("set_accessory_room"), "arguments": .object(move(b))])])
        let response = await d.handle(try JSONEncoder().encode(notification))
        XCTAssertNil(response); XCTAssertEqual(b.writes, 0)
        let result = try await rpc(d, method: "ping", params: [:], id: .string("abc"))
        XCTAssertEqual(result.object?["id"], .string("abc"))
    }
    @MainActor func testInvalidRequestAndIDFailClosed() async throws {
        let (_, d) = try setup()
        let bad = await d.handle(Data("not json".utf8))!
        XCTAssertNotNil(try JSONDecoder().decode(JSONValue.self, from: bad).object?["error"])
        let invalidID = try await rpc(d, method: "ping", params: [:], id: .bool(true))
        XCTAssertNotNil(invalidID.object?["error"])
    }
    @MainActor func testStopDeniesWriteThatWasStillAwaitingInventory() async throws {
        let (b, d) = try setup(writes: true)
        b.inventoryDelays = [50_000_000]
        let args = move(b)
        let pending = Task { try await self.call(d, "set_accessory_room", args) }
        try await Task.sleep(nanoseconds: 5_000_000)
        d.stopAccepting()
        let result = try await pending.value
        XCTAssertEqual(result.object?["isError"], .bool(true))
        XCTAssertEqual(b.writes, 0)
    }
    @MainActor func testPostAwaitDedupAfterFirstRequestAlreadyCompleted() async throws {
        let (b, d) = try setup(writes: true)
        b.inventoryDelays = [5_000_000, 100_000_000]
        let args = move(b)
        let first = Task { try await self.call(d, "set_accessory_room", args) }
        await Task.yield()
        let second = Task { try await self.call(d, "set_accessory_room", args) }
        let one = try await first.value
        let two = try await second.value
        XCTAssertEqual(one.object?["structuredContent"]?.object?["operation_uuid"],
                       two.object?["structuredContent"]?.object?["operation_uuid"])
        XCTAssertEqual(b.writes, 1)
    }
    @MainActor func testCompletedRequestSurvivesDispatcherRestart() async throws {
        var records: [OperationRecord] = []
        let (b, d) = try setup(writes: true, journal: { record, _ in records.append(record) })
        let args = move(b)
        let accepted = try await call(d, "set_accessory_room", args)
        _ = try await completed(d, operation: accepted)
        d.stopAccepting()
        let restored = try MCPDispatcher(backend: b, policy: d.policy, journal: { _, _ in },
                                         recoveredOperations: [records.last!])
        let replay = try await call(restored, "set_accessory_room", args)
        XCTAssertEqual(replay.object?["structuredContent"]?.object?["operation_uuid"],
                       accepted.object?["structuredContent"]?.object?["operation_uuid"])
        XCTAssertEqual(b.writes, 1)
    }
    @MainActor func testUnresolvedJournalPreventsWritesAfterRestart() async throws {
        var records: [OperationRecord] = []
        let (b, d) = try setup(writes: true, journal: { record, _ in records.append(record) })
        _ = try await call(d, "set_accessory_room", move(b))
        let pending = records.first!
        XCTAssertThrowsError(try MCPDispatcher(backend: b, policy: d.policy, journal: { _, _ in }, recoveredOperations: [pending]))
        var readOnly = d.policy; readOnly.allow_metadata_writes = false
        XCTAssertNoThrow(try MCPDispatcher(backend: b, policy: readOnly, journal: { _, _ in }, recoveredOperations: [pending]))
    }
    func testPolicyRejectsImplicitOrDuplicateScope() throws {
        XCTAssertThrowsError(try AccessPolicy(accessory_uuids: [UUID()]).validate())
        let id = UUID()
        XCTAssertThrowsError(try AccessPolicy(home_uuid: UUID(), accessory_uuids: [id, id]).validate())
        XCTAssertThrowsError(try AccessPolicy(allow_metadata_writes: true).validate())
    }
    func testStoragePermissionsAndSymlinkRejection() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try PrivateStorage.prepareDirectory(root)
        try PrivateStorage.write(AccessPolicy(), to: root.appendingPathComponent("policy.json"))
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("policy.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as! NSNumber).intValue, 0o600)
        XCTAssertEqual(try PrivateStorage.readPolicy(root), AccessPolicy())
        try FileManager.default.removeItem(at: root.appendingPathComponent("policy.json"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("policy.json"),
                                                   withDestinationURL: root.appendingPathComponent("elsewhere"))
        XCTAssertThrowsError(try PrivateStorage.readPolicy(root))
    }
    func testMalformedJournalFailsClosed() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try PrivateStorage.write(["operation": "invalid"], to: root.appendingPathComponent("journal/bad.json"))
        XCTAssertThrowsError(try PrivateStorage.loadOperations(in: root))
    }
}
