import Foundation
import HomeKit

@MainActor final class NativeHomeKitBackend: NSObject, HomeKitBackend, HMHomeManagerDelegate {
    private let manager = HMHomeManager()
    private var ready = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    override init() { super.init(); manager.delegate = self }
    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor [weak self] in self?.markReady() }
    }
    private func markReady() {
        ready = true
        let pending = waiters; waiters.removeAll()
        pending.values.forEach { $0.resume() }
    }
    private func waitUntilReady() async throws {
        if ready { return }
        let id = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiters[id] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                self?.waiters.removeValue(forKey: id)?.resume(throwing: BridgeError("HomeKit is not ready; check local permission"))
            }
        }
    }
    func homes() async throws -> [HomeSummary] {
        try await waitUntilReady()
        return manager.homes.map { HomeSummary(uuid: $0.uniqueIdentifier, name: $0.name) }
    }
    private func home(_ id: UUID) async throws -> HMHome {
        try await waitUntilReady()
        guard let home = manager.homes.first(where: { $0.uniqueIdentifier == id })
        else { throw BridgeError("Selected home is unavailable or access was denied") }
        return home
    }
    func inventory(home id: UUID) async throws -> Inventory {
        let selected = try await home(id)
        var rooms = selected.rooms
        let defaultRoom = selected.roomForEntireHome()
        if !rooms.contains(where: { $0.uniqueIdentifier == defaultRoom.uniqueIdentifier }) { rooms.append(defaultRoom) }
        return Inventory(home_uuid: id,
            rooms: rooms.map { RoomRecord(uuid: $0.uniqueIdentifier, name: $0.name) },
            accessories: selected.accessories.map { accessory in
                return AccessoryRecord(uuid: accessory.uniqueIdentifier, name: accessory.name,
                    room_uuid: accessory.room?.uniqueIdentifier ?? defaultRoom.uniqueIdentifier,
                    category: accessory.category.categoryType)
            })
    }
    func moveAccessory(home id: UUID, accessory accessoryID: UUID, room roomID: UUID) async throws {
        let selected = try await home(id)
        guard let accessory = selected.accessories.first(where: { $0.uniqueIdentifier == accessoryID }),
              let room = (selected.rooms + [selected.roomForEntireHome()]).first(where: { $0.uniqueIdentifier == roomID })
        else { throw BridgeError("Accessory and room must belong to the selected home") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            selected.assignAccessory(accessory, to: room) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
    func renameAccessory(home id: UUID, accessory accessoryID: UUID, name: String) async throws {
        let selected = try await home(id)
        guard let accessory = selected.accessories.first(where: { $0.uniqueIdentifier == accessoryID })
        else { throw BridgeError("Accessory is not in the selected home") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            accessory.updateName(name) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
    func renameRoom(home id: UUID, room roomID: UUID, name: String) async throws {
        let selected = try await home(id)
        guard let room = selected.rooms.first(where: { $0.uniqueIdentifier == roomID })
        else { throw BridgeError("Room is not editable in the selected home") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            room.updateName(name) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}
