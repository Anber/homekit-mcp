import SwiftUI

@main struct HomeKitMCPApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            ContentView(model: model).frame(minWidth: 620, minHeight: 520)
                .onDisappear { model.stop() }
        }
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published var status = "Stopped"
    @Published var running = false
    @Published var loading = false
    @Published var homes: [HomeSummary] = []
    @Published var inventory: Inventory?
    @Published var selectedHome = ""
    @Published var accessoryIDs: Set<UUID> = []
    @Published var editableRoomIDs: Set<UUID> = []
    @Published var allowWrites = false
    private var backend: NativeHomeKitBackend?
    private var localServer: LocalMCPServer?
    private var dispatcher: MCPDispatcher?
    private let directory = PrivateStorage.defaultDirectory
    private var savedPolicy = AccessPolicy()

    init() {
        do {
            savedPolicy = try PrivateStorage.readPolicy(directory)
            selectedHome = savedPolicy.home_uuid?.uuidString ?? ""
            accessoryIDs = Set(savedPolicy.accessory_uuids)
            editableRoomIDs = Set(savedPolicy.editable_room_uuids)
            allowWrites = savedPolicy.allow_metadata_writes
        } catch { status = error.localizedDescription }
    }

    func loadHomes() {
        guard !running else { return }
        loading = true
        // HomeKit is not instantiated until the user explicitly requests access.
        if backend == nil { backend = NativeHomeKitBackend() }
        Task {
            defer { loading = false }
            do {
                homes = try await backend!.homes()
                status = homes.isEmpty ? "No accessible homes" : "Select a home and its allowed accessories"
                if let id = UUID(uuidString: selectedHome), homes.contains(where: { $0.uuid == id }) {
                    inventory = try await backend!.inventory(home: id)
                }
            }
            catch { status = error.localizedDescription }
        }
    }
    func selectHome() {
        guard !running, let id = UUID(uuidString: selectedHome), let backend else { return }
        if id == savedPolicy.home_uuid {
            accessoryIDs = Set(savedPolicy.accessory_uuids); editableRoomIDs = Set(savedPolicy.editable_room_uuids)
        } else { accessoryIDs.removeAll(); editableRoomIDs.removeAll() }
        inventory = nil; loading = true
        Task {
            defer { loading = false }
            do {
                let loaded = try await backend.inventory(home: id)
                guard selectedHome == id.uuidString else { return }
                inventory = loaded
            } catch { status = error.localizedDescription }
        }
    }
    func save() {
        guard !running, let id = UUID(uuidString: selectedHome), inventory?.home_uuid == id else {
            status = "Load and select a home first"; return
        }
        do {
            let policy = AccessPolicy(home_uuid: id, accessory_uuids: accessoryIDs.sorted { $0.uuidString < $1.uuidString },
                editable_room_uuids: editableRoomIDs.sorted { $0.uuidString < $1.uuidString }, allow_metadata_writes: allowWrites)
            try policy.validate()
            try PrivateStorage.write(policy, to: directory.appendingPathComponent("policy.json"))
            savedPolicy = policy
            status = "Saved \(accessoryIDs.count) accessories. \(allowWrites ? "Metadata writes enabled." : "Read-only.")"
        } catch { status = error.localizedDescription }
    }
    func start() {
        guard !running else { return }
        do {
            let policy = try PrivateStorage.readPolicy(directory)
            let recovered = try PrivateStorage.loadOperations(in: directory)
            if policy.allow_metadata_writes, recovered.contains(where: { $0.status != "succeeded" }) {
                throw BridgeError("Unresolved operation journal. Inspect inventory in read-only mode and archive reviewed records before enabling writes.")
            }
            if backend == nil { backend = NativeHomeKitBackend() }
            let dispatcher = try MCPDispatcher(backend: backend!, policy: policy,
                journal: PrivateStorage.journal(in: directory), recoveredOperations: recovered)
            let server = try LocalMCPServer(directory: directory) { data in await dispatcher.handle(data) }
            try server.start()
            self.dispatcher = dispatcher; localServer = server; running = true
            status = policy.allow_metadata_writes ? "Running: scoped metadata writes" : "Running: scoped read-only"
        } catch { status = error.localizedDescription }
    }
    func stop() {
        dispatcher?.stopAccepting(); dispatcher = nil
        localServer?.stop(); localServer = nil; running = false
        status = "Stopped. Previously accepted metadata operations may still finish; inspect the journal."
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("HomeKit Local").font(.largeTitle).bold()
            Text("Inventory, names and rooms. No light, lock, garage or other actuator commands.")
                .foregroundColor(.secondary)
            Text(model.status).accessibilityIdentifier("server-status")
            HStack {
                Button("Load homes") { model.loadHomes() }.disabled(model.running || model.loading)
                Picker("Home", selection: $model.selectedHome) {
                    Text("Choose a home").tag("")
                    ForEach(model.homes, id: \.uuid) { Text($0.name).tag($0.uuid.uuidString) }
                }.disabled(model.running || model.loading)
                    .onChange(of: model.selectedHome) { _ in model.selectHome() }
            }
            if let inventory = model.inventory {
                Text("Allowed accessories (\(model.accessoryIDs.count) selected)").font(.headline)
                List(inventory.accessories, id: \.uuid) { accessory in
                    Toggle(isOn: Binding(
                        get: { model.accessoryIDs.contains(accessory.uuid) },
                        set: { selected in if selected { model.accessoryIDs.insert(accessory.uuid) }
                               else { model.accessoryIDs.remove(accessory.uuid) } })) {
                        VStack(alignment: .leading) {
                            Text(accessory.name)
                            Text(accessory.uuid.uuidString).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }.disabled(model.running)
                let missing = model.accessoryIDs.subtracting(Set(inventory.accessories.map(\.uuid)))
                if !missing.isEmpty {
                    Text("\(missing.count) saved accessory UUIDs are no longer present. They remain excluded from inventory.")
                        .font(.caption).foregroundColor(.secondary)
                    Button("Remove missing UUIDs from selection") { model.accessoryIDs.subtract(missing) }
                        .disabled(model.running)
                }
                Toggle("Allow changes to names and room assignments", isOn: $model.allowWrites)
                    .disabled(model.running)
                if model.allowWrites {
                    Text("Rooms whose names may be changed").font(.headline)
                    ScrollView {
                        ForEach(inventory.rooms, id: \.uuid) { room in
                            Toggle(room.name, isOn: Binding(
                                get: { model.editableRoomIDs.contains(room.uuid) },
                                set: { selected in if selected { model.editableRoomIDs.insert(room.uuid) }
                                       else { model.editableRoomIDs.remove(room.uuid) } }))
                        }
                    }.frame(maxHeight: 80).disabled(model.running)
                }
                Button("Save selection") { model.save() }.disabled(model.running)
            }
            HStack {
                Button(model.running ? "Stop bridge" : "Start bridge") {
                    if model.running { model.stop() } else { model.start() }
                }.buttonStyle(.borderedProminent)
                if model.loading { ProgressView() }
            }
            Text("Local Unix socket only. Policy and pre-change journals are private files in ~/Library/Application Support/HomeKitMCP.")
                .font(.caption).foregroundColor(.secondary)
        }.padding()
    }
}
