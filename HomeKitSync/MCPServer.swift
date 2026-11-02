import Foundation
import CoreFoundation

// This file is compiled by both the real application and SwiftPM tests.
public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String)
    case number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try value.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var object: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public static func encoded<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}

public struct HomeSummary: Codable, Equatable, Sendable {
    public let uuid: UUID
    public let name: String
    public init(uuid: UUID, name: String) { self.uuid = uuid; self.name = name }
}
public struct RoomRecord: Codable, Equatable, Sendable {
    public let uuid: UUID
    public var name: String
    public init(uuid: UUID, name: String) { self.uuid = uuid; self.name = name }
}
public struct AccessoryRecord: Codable, Equatable, Sendable {
    public let uuid: UUID
    public var name: String
    public var room_uuid: UUID
    public let category: String
    public let serial_number: String?
    public init(uuid: UUID, name: String, room_uuid: UUID, category: String, serial_number: String? = nil) {
        self.uuid = uuid; self.name = name; self.room_uuid = room_uuid
        self.category = category; self.serial_number = serial_number
    }
}
public struct Inventory: Codable, Equatable, Sendable {
    public let home_uuid: UUID
    public var rooms: [RoomRecord]
    public var accessories: [AccessoryRecord]
    public init(home_uuid: UUID, rooms: [RoomRecord], accessories: [AccessoryRecord]) {
        self.home_uuid = home_uuid; self.rooms = rooms; self.accessories = accessories
    }
}
public struct AccessPolicy: Codable, Equatable, Sendable {
    public var home_uuid: UUID?
    public var accessory_uuids: [UUID]
    public var editable_room_uuids: [UUID]
    public var allow_metadata_writes: Bool
    public init(home_uuid: UUID? = nil, accessory_uuids: [UUID] = [],
                editable_room_uuids: [UUID] = [], allow_metadata_writes: Bool = false) {
        self.home_uuid = home_uuid; self.accessory_uuids = accessory_uuids
        self.editable_room_uuids = editable_room_uuids; self.allow_metadata_writes = allow_metadata_writes
    }
    public func validate() throws {
        guard Set(accessory_uuids).count == accessory_uuids.count,
              Set(editable_room_uuids).count == editable_room_uuids.count,
              accessory_uuids.count <= 500,
              home_uuid != nil || (accessory_uuids.isEmpty && editable_room_uuids.isEmpty && !allow_metadata_writes)
        else { throw BridgeError("Invalid access policy") }
    }
}
public struct BridgeError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

@MainActor public protocol HomeKitBackend: AnyObject {
    func homes() async throws -> [HomeSummary]
    func inventory(home: UUID) async throws -> Inventory
    func moveAccessory(home: UUID, accessory: UUID, room: UUID) async throws
    func renameAccessory(home: UUID, accessory: UUID, name: String) async throws
    func renameRoom(home: UUID, room: UUID, name: String) async throws
}
public struct OperationRecord: Codable, Sendable {
    public let operation_uuid: UUID
    public let request_uuid: UUID
    public let home_uuid: UUID
    public let request_fingerprint: String
    public let tool: String
    public var status: String
    public var message: String
}

@MainActor public final class MCPDispatcher {
    public let policy: AccessPolicy
    private let backend: HomeKitBackend
    private let journal: (OperationRecord, Inventory) throws -> Void
    private var operations: [UUID: OperationRecord] = [:]
    private var fingerprints: [UUID: Data] = [:]
    private var activeOperation: UUID?
    private var accepting = true
    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e
    }()
    private let readTools = ["get_all_accessories", "get_all_rooms", "get_operation"]
    private let writeTools = ["set_accessory_room", "rename_accessory", "rename_room"]

    public init(backend: HomeKitBackend, policy: AccessPolicy,
                journal: @escaping (OperationRecord, Inventory) throws -> Void,
                recoveredOperations: [OperationRecord] = []) throws {
        try policy.validate()
        if policy.allow_metadata_writes, recoveredOperations.contains(where: { $0.status != "succeeded" }) {
            throw BridgeError("Unresolved operation journal; inspect in read-only mode before enabling writes")
        }
        self.backend = backend; self.policy = policy; self.journal = journal
        for record in recoveredOperations where record.home_uuid == policy.home_uuid {
            guard let fingerprint = Data(base64Encoded: record.request_fingerprint),
                  let request = try JSONDecoder().decode(JSONValue.self, from: fingerprint).object,
                  let arguments = request["arguments"]?.object
            else { throw BridgeError("Invalid operation fingerprint in journal") }
            let key = record.tool == "rename_room" ? "room_uuid" : "accessory_uuid"
            guard let raw = arguments[key]?.string, let id = UUID(uuidString: raw) else {
                throw BridgeError("Invalid operation target in journal")
            }
            let allowed = record.tool == "rename_room" ? policy.editable_room_uuids.contains(id) : policy.accessory_uuids.contains(id)
            if allowed {
                guard fingerprints[record.request_uuid] == nil else { throw BridgeError("Duplicate request UUID in journal") }
                fingerprints[record.request_uuid] = fingerprint
                operations[record.operation_uuid] = record
            }
        }
    }
    public func stopAccepting() { accepting = false }
    private func rpc(_ id: JSONValue, result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }
    private func rpcError(_ id: JSONValue, code: Int, message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id,
                 "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }
    public func handle(_ data: Data) async -> Data? {
        guard accepting else { return try? encoder.encode(rpcError(.null, code: -32000, message: "Bridge stopped")) }
        let response: JSONValue?
        do {
            guard let request = try JSONDecoder().decode(JSONValue.self, from: data).object,
                  request["jsonrpc"] == .string("2.0"), let method = request["method"]?.string
            else { return try encoder.encode(rpcError(.null, code: -32600, message: "Invalid request")) }
            if let id = request["id"] {
                switch id {
                case .string, .null: break
                case .number(let number) where number.isFinite && number.rounded() == number: break
                default: return try encoder.encode(rpcError(.null, code: -32600, message: "Invalid request ID"))
                }
            } else {
                // Notifications never generate responses, and never dispatch tools.
                return nil
            }
            let id = request["id"] ?? .null
            let params = request["params"]?.object ?? [:]
            switch method {
            case "initialize":
                let requested = params["protocolVersion"]?.string ?? ""
                let supported = ["2025-06-18", "2025-03-26", "2024-11-05"]
                response = rpc(id, result: .object([
                    "protocolVersion": .string(supported.contains(requested) ? requested : supported[0]),
                    "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                    "serverInfo": .object(["name": .string("homekit-local"), "version": .string("0.2.0")])
                ]))
            case "ping": response = rpc(id, result: .object([:]))
            case "tools/list": response = rpc(id, result: .object(["tools": .array(toolSchemas())]))
            case "tools/call":
                guard let name = params["name"]?.string, let arguments = params["arguments"]?.object
                else { return try encoder.encode(rpcError(id, code: -32602, message: "Tool and arguments required")) }
                do {
                    let value = try await call(name, arguments: arguments)
                    response = rpc(id, result: .object([
                        "content": .array([.object(["type": .string("text"),
                            "text": .string(String(data: try encoder.encode(value), encoding: .utf8)!)])]),
                        "structuredContent": value, "isError": .bool(false)
                    ]))
                } catch {
                    response = rpc(id, result: .object(["isError": .bool(true),
                        "content": .array([.object(["type": .string("text"),
                                                  "text": .string(error.localizedDescription)])])]))
                }
            default: response = rpcError(id, code: -32601, message: "Method not found")
            }
        } catch {
            response = rpcError(.null, code: -32700, message: "Parse error")
        }
        return response.flatMap { try? encoder.encode($0) }
    }
    private func schema(_ name: String, properties: [String: JSONValue], required: [String], readOnly: Bool) -> JSONValue {
        .object(["name": .string(name), "description": .string(name.replacingOccurrences(of: "_", with: " ")),
                 "inputSchema": .object(["type": .string("object"), "properties": .object(properties),
                     "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)]),
                 "annotations": .object(["readOnlyHint": .bool(readOnly), "openWorldHint": .bool(false),
                     "destructiveHint": .bool(!readOnly), "idempotentHint": .bool(true)])])
    }
    private func toolSchemas() -> [JSONValue] {
        let uuid = JSONValue.object(["type": .string("string"), "format": .string("uuid")])
        let text = JSONValue.object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(64)])
        if policy.home_uuid == nil { return [schema("list_homes", properties: [:], required: [], readOnly: true)] }
        var tools = [schema("get_all_accessories", properties: [:], required: [], readOnly: true),
                     schema("get_all_rooms", properties: [:], required: [], readOnly: true),
                     schema("get_operation", properties: ["operation_uuid": uuid], required: ["operation_uuid"], readOnly: true)]
        if policy.allow_metadata_writes {
            let base = ["home_uuid": uuid, "request_uuid": uuid]
            tools.append(schema("set_accessory_room", properties: base.merging([
                "accessory_uuid": uuid, "room_uuid": uuid, "expected_room_uuid": uuid, "expected_name": text
            ]) { _, new in new }, required: ["home_uuid", "request_uuid", "accessory_uuid", "room_uuid",
                                             "expected_room_uuid", "expected_name"], readOnly: false))
            tools.append(schema("rename_accessory", properties: base.merging([
                "accessory_uuid": uuid, "new_name": text, "expected_name": text, "expected_room_uuid": uuid
            ]) { _, new in new }, required: ["home_uuid", "request_uuid", "accessory_uuid", "new_name",
                                             "expected_name", "expected_room_uuid"], readOnly: false))
            tools.append(schema("rename_room", properties: base.merging([
                "room_uuid": uuid, "new_name": text, "expected_name": text
            ]) { _, new in new }, required: ["home_uuid", "request_uuid", "room_uuid", "new_name",
                                             "expected_name"], readOnly: false))
        }
        return tools
    }
    private func uuid(_ args: [String: JSONValue], _ key: String) throws -> UUID {
        guard let value = args[key]?.string, let id = UUID(uuidString: value)
        else { throw BridgeError("Valid \(key) required") }; return id
    }
    private func name(_ args: [String: JSONValue], _ key: String) throws -> String {
        guard let value = args[key]?.string, value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value.utf8.count <= 64, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw BridgeError("Nonempty, bounded \(key) required") }; return value
    }
    private func scopedInventory() async throws -> Inventory {
        guard let home = policy.home_uuid else { throw BridgeError("Select a home UUID in policy first") }
        var inventory = try await backend.inventory(home: home)
        guard inventory.home_uuid == home else { throw BridgeError("Backend returned wrong home") }
        inventory.accessories = inventory.accessories.filter { policy.accessory_uuids.contains($0.uuid) }
        return inventory
    }
    private func call(_ tool: String, arguments args: [String: JSONValue]) async throws -> JSONValue {
        guard accepting else { throw BridgeError("Bridge stopped") }
        if tool == "list_homes" {
            guard policy.home_uuid == nil, args.isEmpty else { throw BridgeError("Home discovery is disabled after selecting a home") }
            return .object(["homes": try .encoded(await backend.homes())])
        }
        guard policy.home_uuid != nil else { throw BridgeError("Select a home UUID in policy first") }
        if tool == "get_operation" {
            guard Set(args.keys) == ["operation_uuid"] else { throw BridgeError("Unexpected arguments") }
            let operationID = try uuid(args, "operation_uuid")
            guard let record = operations[operationID] else { throw BridgeError("Unknown operation; inspect fresh inventory before any retry") }
            return try .encoded(record)
        }
        if readTools.contains(tool) {
            guard args.isEmpty else { throw BridgeError("Unexpected arguments") }
            let inventory = try await scopedInventory()
            return .object(["home_uuid": .string(inventory.home_uuid.uuidString),
                tool == "get_all_rooms" ? "rooms" : "accessories":
                    tool == "get_all_rooms" ? try .encoded(inventory.rooms) : try .encoded(inventory.accessories)])
        }
        guard writeTools.contains(tool), policy.allow_metadata_writes else { throw BridgeError("Tool disabled by server policy") }
        let expectedKeys: Set<String>
        switch tool {
        case "set_accessory_room": expectedKeys = ["home_uuid", "request_uuid", "accessory_uuid", "room_uuid", "expected_room_uuid", "expected_name"]
        case "rename_accessory": expectedKeys = ["home_uuid", "request_uuid", "accessory_uuid", "new_name", "expected_name", "expected_room_uuid"]
        default: expectedKeys = ["home_uuid", "request_uuid", "room_uuid", "new_name", "expected_name"]
        }
        guard Set(args.keys) == expectedKeys else { throw BridgeError("Exact arguments required") }
        let home = try uuid(args, "home_uuid"), requestID = try uuid(args, "request_uuid")
        guard home == policy.home_uuid else { throw BridgeError("Home is outside policy") }
        let fingerprint = try encoder.encode(JSONValue.object(["tool": .string(tool), "arguments": .object(args)]))
        if let record = try cachedOperation(requestID, fingerprint: fingerprint) { return try .encoded(record) }
        guard activeOperation == nil else { throw BridgeError("A previous mutation is still pending; query its operation instead of retrying") }
        guard operations.count < 1000 else { throw BridgeError("Operation limit reached; stop and inspect the journal") }
        let inventory = try await scopedInventory()
        // Another request could have begun while the inventory awaited HomeKit.
        guard accepting else { throw BridgeError("Bridge stopped before accepting the mutation") }
        if let record = try cachedOperation(requestID, fingerprint: fingerprint) { return try .encoded(record) }
        guard activeOperation == nil else { throw BridgeError("A previous mutation is still pending") }
        guard operations.count < 1000 else { throw BridgeError("Operation limit reached") }
        let targetID: UUID, targetRoom: UUID?, newName: String?
        let expectedName = try name(args, "expected_name")
        if tool == "rename_room" {
            targetID = try uuid(args, "room_uuid"); targetRoom = nil
            newName = try name(args, "new_name")
            guard policy.editable_room_uuids.contains(targetID),
                  inventory.rooms.first(where: { $0.uuid == targetID })?.name == expectedName
            else { throw BridgeError("Room is outside policy or its name has changed") }
        } else {
            targetID = try uuid(args, "accessory_uuid")
            let oldRoom = try uuid(args, "expected_room_uuid")
            guard policy.accessory_uuids.contains(targetID),
                  let accessory = inventory.accessories.first(where: { $0.uuid == targetID }),
                  accessory.name == expectedName, accessory.room_uuid == oldRoom
            else { throw BridgeError("Accessory is outside policy or its name/room has changed") }
            if tool == "set_accessory_room" {
                let room = try uuid(args, "room_uuid")
                guard inventory.rooms.contains(where: { $0.uuid == room }) else { throw BridgeError("Target room is not in this home") }
                targetRoom = room; newName = nil
            } else { targetRoom = nil; newName = try name(args, "new_name") }
        }
        let operationID = UUID()
        let record = OperationRecord(operation_uuid: operationID, request_uuid: requestID, home_uuid: home,
                                     request_fingerprint: fingerprint.base64EncodedString(), tool: tool,
                                     status: "pending", message: "Accepted; query get_operation. Do not repeat with a new request_uuid.")
        // Fail closed if the private pre-change journal cannot be saved.
        try journal(record, inventory)
        operations[operationID] = record; fingerprints[requestID] = fingerprint; activeOperation = operationID
        Task { @MainActor in
            var finished = record
            do {
                if let room = targetRoom { try await backend.moveAccessory(home: home, accessory: targetID, room: room) }
                else if tool == "rename_room" { try await backend.renameRoom(home: home, room: targetID, name: newName!) }
                else { try await backend.renameAccessory(home: home, accessory: targetID, name: newName!) }
                let after = try await scopedInventory()
                let confirmed: Bool
                if let room = targetRoom { confirmed = after.accessories.first(where: { $0.uuid == targetID })?.room_uuid == room }
                else if tool == "rename_room" { confirmed = after.rooms.first(where: { $0.uuid == targetID })?.name == newName }
                else { confirmed = after.accessories.first(where: { $0.uuid == targetID })?.name == newName }
                finished.status = confirmed ? "succeeded" : "unconfirmed"
                finished.message = confirmed ? "Read-back verified." : "Callback completed, but read-back differs. Inspect inventory; do not retry blindly."
            } catch {
                finished.status = "unconfirmed"
                finished.message = "Operation outcome requires inspection: \(error.localizedDescription)"
            }
            operations[operationID] = finished
            // An unconfirmed write blocks subsequent mutations until the operator
            // inspects inventory and restarts, rather than racing a late callback.
            if finished.status == "succeeded" { activeOperation = nil }
            do { try journal(finished, inventory) }
            catch { activeOperation = operationID; operations[operationID]?.message += " Journal update failed; inspect before restarting." }
        }
        return try .encoded(record)
    }
    private func cachedOperation(_ request: UUID, fingerprint: Data) throws -> OperationRecord? {
        guard let old = fingerprints[request] else { return nil }
        guard old == fingerprint, let record = operations.values.first(where: { $0.request_uuid == request })
        else { throw BridgeError("request_uuid was already used for different arguments") }
        return record
    }
}
