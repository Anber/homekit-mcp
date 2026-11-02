import Foundation
import Darwin

public struct RuntimePreferences: Codable {
    // This is an explicit, revocable user intent, never inferred from an old policy.
    public var resume_read_only = false
    public init() {}
}

public struct BridgeStatus: Codable {
    public var phase: String
    public var read_only: Bool
    public var updated_at: Date
    public var pid: Int32
}

public struct StatusEvent: Codable {
    public let event: String
    public let at: Date
}

/// Owns the bridge independently of any configuration window. It never retries
/// writes or re-registers login items. HomeKit outages keep the endpoint alive;
/// subsequent reads use the HomeKit manager's recovered inventory.
@MainActor public final class BridgeLifecycle {
    public private(set) var state = BridgeStatus(phase: "stopped", read_only: true, updated_at: Date(), pid: ProcessInfo.processInfo.processIdentifier)
    public private(set) var preferences = RuntimePreferences()
    public private(set) var lastError: String?
    public var onChange: (() -> Void)?
    public var active: Bool { server != nil }
    public var starting: Bool { state.phase == "starting" }
    private let directory: URL
    private let factory: () -> any HomeKitBackend
    private var backend: (any HomeKitBackend)?
    private var server: LocalMCPServer?
    private var dispatcher: MCPDispatcher?
    private var homeID: UUID?
    private var generation = 0
    private var healthTask: Task<Void, Never>?
    private var events: [StatusEvent] = []
    private var instanceFD: Int32 = -1

    public init(directory: URL = PrivateStorage.defaultDirectory, factory: @escaping () -> any HomeKitBackend) throws {
        self.directory = directory; self.factory = factory
        try PrivateStorage.prepareDirectory(directory)
        let fd = open(directory.appendingPathComponent("lifecycle.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BridgeError("Cannot open lifecycle lock") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw BridgeError("Another bridge instance owns this runtime, or its lock is unsafe")
        }
        instanceFD = fd
        preferences = try PrivateStorage.read(RuntimePreferences.self, from: directory.appendingPathComponent("runtime.json")) ?? RuntimePreferences()
        events = Array((try PrivateStorage.read([StatusEvent].self, from: directory.appendingPathComponent("status-journal.json")) ?? []).suffix(127))
        try record("stopped")
    }
    deinit { if instanceFD >= 0 { close(instanceFD) } }

    public func restoreIfRequested() async {
        guard preferences.resume_read_only else { return }
        // A saved write policy can never turn an unattended launch into a writer.
        await start(readOnly: true)
    }

    public func start(readOnly: Bool) async {
        guard !active, !starting else { return }
        generation += 1
        let attempt = generation
        lastError = nil
        do {
            var policy = try PrivateStorage.readPolicy(directory)
            guard let home = policy.home_uuid else {
                try record("needs_configuration"); return
            }
            if readOnly { policy.allow_metadata_writes = false }
            let recovered = try PrivateStorage.loadOperations(in: directory)
            if policy.allow_metadata_writes, recovered.contains(where: { $0.status != "succeeded" }) {
                throw BridgeError("Unresolved operation journal; inspect in read-only mode before enabling writes")
            }
            state.read_only = !policy.allow_metadata_writes
            try record("starting")
            let candidate = factory()
            // No endpoint or Running claim until Apple Home is actually ready.
            _ = try await candidate.inventory(home: home)
            guard generation == attempt else { return }
            let dispatcher = try MCPDispatcher(backend: candidate, policy: policy,
                journal: PrivateStorage.journal(in: directory), recoveredOperations: recovered)
            let server = try LocalMCPServer(directory: directory) { data in await dispatcher.handle(data) }
            try server.start()
            self.backend = candidate; self.dispatcher = dispatcher; self.server = server; self.homeID = home
            preferences.resume_read_only = true
            try savePreferences()
            try record("running")
            healthTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                    guard let self else { return }
                    await self.checkHealth()
                }
            }
        } catch {
            guard generation == attempt else { return }
            closeEndpoint()
            lastError = error.localizedDescription
            state.phase = "failed"; state.updated_at = Date()
            try? record("failed")
            // Detailed native errors stay in the UI, never in the status journal.
            onChange?()
        }
    }

    public func checkHealth() async {
        guard let backend, let homeID, active else { return }
        let check = generation
        let phase: String
        do {
            _ = try await backend.inventory(home: homeID)
            phase = "running"
        } catch { phase = "home_unavailable" }
        guard generation == check, active else { return }
        do { try record(phase) }
        catch {
            closeEndpoint()
            state.phase = "storage_error"; state.updated_at = Date(); onChange?()
        }
    }

    /// Explicit Stop persists across login; Quit only closes this process's bridge.
    public func stop(pause: Bool = true) {
        generation += 1
        closeEndpoint()
        do {
            if pause { preferences.resume_read_only = false; try savePreferences() }
            try record("stopped")
        } catch { state.phase = "storage_error"; onChange?() }
    }

    private func closeEndpoint() {
        healthTask?.cancel(); healthTask = nil
        dispatcher?.stopAccepting(); dispatcher = nil
        server?.stop(); server = nil; backend = nil; homeID = nil
    }
    private func savePreferences() throws {
        try PrivateStorage.write(preferences, to: directory.appendingPathComponent("runtime.json"))
    }
    private func record(_ phase: String) throws {
        if events.last?.event != phase {
            events.append(StatusEvent(event: phase, at: Date()))
            events = Array(events.suffix(128))
            try PrivateStorage.write(events, to: directory.appendingPathComponent("status-journal.json"))
        }
        state.phase = phase; state.updated_at = Date()
        try PrivateStorage.write(state, to: directory.appendingPathComponent("status.json"))
        onChange?()
    }
}
