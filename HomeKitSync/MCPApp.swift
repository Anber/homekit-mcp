import SwiftUI
import ServiceManagement

@MainActor final class ApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AppModel.shared.applicationReady()
        return true
    }
    func applicationWillTerminate(_ application: UIApplication) { AppModel.shared.quitBridge() }
}

@main struct HomeKitMCPApp: App {
    @UIApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    var body: some Scene {
        WindowGroup {
            ContentView(model: model).frame(minWidth: 620, minHeight: 520)
                .onAppear { model.windowAppeared() }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in model.refresh() }
        }
    }
}

@MainActor final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var status = "Stopped"
    @Published var running = false
    @Published var loading = false
    @Published var homes: [HomeSummary] = []
    @Published var inventory: Inventory?
    @Published var selectedHome = ""
    @Published var accessoryIDs: Set<UUID> = []
    @Published var editableRoomIDs: Set<UUID> = []
    @Published var allowWrites = false
    @Published var starting = false
    @Published var loginStatus = "not_registered"
    @Published var menuAvailable = false
    private var backend: NativeHomeKitBackend?
    private var lifecycle: BridgeLifecycle?
    private var menu: (any HomeKitMenuInterface)?
    private var applicationStarted = false
    private var hideInitialWindow = false
    private let directory = PrivateStorage.defaultDirectory
    private var savedPolicy = AccessPolicy()

    init() {
        do {
            savedPolicy = try PrivateStorage.readPolicy(directory)
            selectedHome = savedPolicy.home_uuid?.uuidString ?? ""
            accessoryIDs = Set(savedPolicy.accessory_uuids)
            editableRoomIDs = Set(savedPolicy.editable_room_uuids)
            allowWrites = savedPolicy.allow_metadata_writes
            lifecycle = try BridgeLifecycle { NativeHomeKitBackend() }
            lifecycle?.onChange = { [weak self] in self?.refresh() }
        } catch { status = error.localizedDescription }
    }

    func applicationReady() {
        guard !applicationStarted else { return }
        applicationStarted = true
        do {
            guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("HomeKitMenu.bundle"),
                  let bundle = Bundle(url: url) else { throw BridgeError("Menu bundle is missing") }
            try bundle.loadAndReturnError()
            guard let type = bundle.principalClass as? (any HomeKitMenuInterface.Type) else {
                throw BridgeError("Menu bundle interface is invalid")
            }
            let menu = type.init(); self.menu = menu
            hideInitialWindow = menu.launchedAtLogin() && (lifecycle?.preferences.resume_read_only ?? false)
            menu.install { [weak self] command in
                Task { @MainActor in self?.menuCommand(command) }
            }
            menuAvailable = true
            refresh()
            Task { await lifecycle?.restoreIfRequested() }
        } catch {
            // A missing status menu must not leave an invisible unattended bridge.
            status = "Menu unavailable: \(error.localizedDescription). Bridge was not started."
        }
    }
    func windowAppeared() {
        if hideInitialWindow { hideInitialWindow = false; menu?.hideSettings() }
    }
    private func menuCommand(_ command: String) {
        switch command {
        case "settings":
            if menu?.showSettings() != true {
                UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil)
            }
        case "start": start(readOnly: true)
        case "stop": stop()
        case "login": setLoginEnabled(loginStatus != "enabled" && loginStatus != "requires_approval")
        case "login-settings": SMAppService.openSystemSettingsLoginItems()
        case "status": menu?.revealStatus()
        case "quit": quitBridge(); menu?.terminate()
        default: break
        }
    }
    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled: loginStatus = "enabled"
        case .requiresApproval: loginStatus = "requires_approval"
        case .notFound: loginStatus = "not_found"
        default: loginStatus = "not_registered"
        }
        if let lifecycle {
            running = lifecycle.active; starting = lifecycle.starting
            switch lifecycle.state.phase {
            case "running": status = lifecycle.state.read_only ? "Running: scoped read-only" : "Running: scoped metadata writes"
            case "starting": status = "Waiting for Apple Home…"
            case "home_unavailable": status = "Apple Home unavailable. Waiting for its connection to recover."
            case "needs_configuration": status = "Load homes and save a selection first."
            case "failed": status = "Could not start: \(lifecycle.lastError ?? "check HomeKit access and private runtime files")"
            case "storage_error": status = "Bridge stopped, but the pause could not be saved. Check private runtime files."
            default: status = "Stopped. Previously accepted metadata operations may still finish; inspect the journal."
            }
        }
        menu?.update(status: status, running: running, busy: starting || loading, loginStatus: loginStatus)
    }
    func setLoginEnabled(_ enabled: Bool) {
        do {
            if enabled {
                guard menuAvailable, savedPolicy.home_uuid != nil else {
                    status = "Save a home selection before enabling login startup"; return
                }
                try SMAppService.mainApp.register()
            } else { try SMAppService.mainApp.unregister() }
            refresh()
        } catch { status = "Login startup: \(error.localizedDescription)" }
    }
    func loginSettings() { SMAppService.openSystemSettingsLoginItems() }
    func hideWindow() { if menuAvailable { menu?.hideSettings() } }
    func quitBridge() { lifecycle?.stop(pause: false) }

    func loadHomes() {
        guard !running, !starting else { return }
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
        guard !running, !starting, let id = UUID(uuidString: selectedHome), let backend else { return }
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
        guard !running, !starting, let id = UUID(uuidString: selectedHome), inventory?.home_uuid == id else {
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
    func start(readOnly: Bool = false) {
        guard !running, !starting, !loading, menuAvailable else { return }
        Task { await lifecycle?.start(readOnly: readOnly) }
    }
    func stop() { lifecycle?.stop() }
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
                Button("Load homes") { model.loadHomes() }.disabled(model.running || model.starting || model.loading)
                Picker("Home", selection: $model.selectedHome) {
                    Text("Choose a home").tag("")
                    ForEach(model.homes, id: \.uuid) { Text($0.name).tag($0.uuid.uuidString) }
                }.pickerStyle(.segmented).disabled(model.running || model.starting || model.loading)
                    .onChange(of: model.selectedHome) { _ in model.selectHome() }
            }
            if let inventory = model.inventory {
                Text("Allowed accessories (\(model.accessoryIDs.count) selected)").font(.headline)
                HStack {
                    Button("Select all current accessories") {
                        model.accessoryIDs = Set(inventory.accessories.map(\.uuid))
                    }
                    Button("Clear selection") { model.accessoryIDs.removeAll() }
                }.disabled(model.running || model.starting)
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
                }.disabled(model.running || model.starting)
                let missing = model.accessoryIDs.subtracting(Set(inventory.accessories.map(\.uuid)))
                if !missing.isEmpty {
                    Text("\(missing.count) saved accessory UUIDs are no longer present. They remain excluded from inventory.")
                        .font(.caption).foregroundColor(.secondary)
                    Button("Remove missing UUIDs from selection") { model.accessoryIDs.subtract(missing) }
                        .disabled(model.running || model.starting)
                }
                Toggle("Allow changes to names and room assignments", isOn: $model.allowWrites)
                    .disabled(model.running || model.starting)
                if model.allowWrites {
                    Text("Rooms whose names may be changed").font(.headline)
                    ScrollView {
                        ForEach(inventory.rooms, id: \.uuid) { room in
                            Toggle(room.name, isOn: Binding(
                                get: { model.editableRoomIDs.contains(room.uuid) },
                                set: { selected in if selected { model.editableRoomIDs.insert(room.uuid) }
                                       else { model.editableRoomIDs.remove(room.uuid) } }))
                        }
                    }.frame(maxHeight: 80).disabled(model.running || model.starting)
                }
                Button("Save selection") { model.save() }.disabled(model.running || model.starting)
            }
            HStack {
                Button(model.running || model.starting ? "Stop bridge" : "Start bridge") {
                    if model.running || model.starting { model.stop() } else { model.start() }
                }.buttonStyle(.borderedProminent).disabled(model.loading || !model.menuAvailable)
                Button("Keep running in background") { model.hideWindow() }.disabled(!model.menuAvailable)
                if model.loading || model.starting { ProgressView() }
            }
            HStack {
                Toggle("Open at login", isOn: Binding(get: { model.loginStatus == "enabled" }, set: { model.setLoginEnabled($0) }))
                Button("Login settings…") { model.loginSettings() }
            }
            if model.loginStatus == "requires_approval" { Text("Allow HomeKit Local in macOS Login Items to finish enabling startup.").font(.caption) }
            Text("Closing this window keeps the bridge running. Stop pauses it across logins. Login startup resumes only read-only access; macOS login-item settings remain authoritative.")
                .font(.caption).foregroundColor(.secondary)
            Text("Local Unix socket only. Policy and pre-change journals are private files in ~/Library/Application Support/HomeKitMCP.")
                .font(.caption).foregroundColor(.secondary)
        }.padding()
    }
}
