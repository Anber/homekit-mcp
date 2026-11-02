import Foundation
import HomeKitMCPCore
import Darwin

// Test-only backend. This executable does not import or link HomeKit.
@MainActor final class FixtureBackend: HomeKitBackend {
    let homeID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let roomID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let nextRoomID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    let accessoryID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    var state: Inventory
    init() {
        state = Inventory(home_uuid: homeID, rooms: [RoomRecord(uuid: roomID, name: "Office"),
            RoomRecord(uuid: nextRoomID, name: "Bedroom")],
            accessories: [AccessoryRecord(uuid: accessoryID, name: "Desk Lamp", room_uuid: roomID, category: "light"),
                          AccessoryRecord(uuid: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                            name: "Not allowed", room_uuid: roomID, category: "garage")])
    }
    func homes() async throws -> [HomeSummary] { [HomeSummary(uuid: homeID, name: "Fixture home")] }
    func inventory(home: UUID) async throws -> Inventory {
        guard home == homeID else { throw BridgeError("Unknown fixture home") }; return state
    }
    func moveAccessory(home: UUID, accessory: UUID, room: UUID) async throws {
        try await Task.sleep(nanoseconds: 50_000_000)
        guard let index = state.accessories.firstIndex(where: { $0.uuid == accessory })
        else { throw BridgeError("Missing fixture accessory") }
        state.accessories[index].room_uuid = room
    }
    func renameAccessory(home: UUID, accessory: UUID, name: String) async throws {
        guard let index = state.accessories.firstIndex(where: { $0.uuid == accessory })
        else { throw BridgeError("Missing fixture accessory") }
        state.accessories[index].name = name
    }
    func renameRoom(home: UUID, room: UUID, name: String) async throws {
        guard let index = state.rooms.firstIndex(where: { $0.uuid == room })
        else { throw BridgeError("Missing fixture room") }
        state.rooms[index].name = name
    }
}

@main struct FixtureMain {
    @MainActor static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data(("Fixture start failed: \(error.localizedDescription)\n").utf8))
            exit(1)
        }
    }
    @MainActor private static func run() async throws {
        guard CommandLine.arguments.count == 2 else { throw BridgeError("Fixture requires a runtime directory") }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let policy = try PrivateStorage.readPolicy(directory)
        let recovered = try PrivateStorage.loadOperations(in: directory)
        let dispatcher = try MCPDispatcher(backend: FixtureBackend(), policy: policy,
            journal: PrivateStorage.journal(in: directory), recoveredOperations: recovered)
        let server = try LocalMCPServer(directory: directory) { await dispatcher.handle($0) }
        try server.start()
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        termination.setEventHandler { server.stop(); exit(0) }; termination.resume()
        while true { try await Task.sleep(nanoseconds: 1_000_000_000) }
    }
}
