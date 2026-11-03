import AppKit

@MainActor @objc(HomeKitMenu) final class HomeKitMenu: NSObject, HomeKitMenuInterface {
    private var item: NSStatusItem?
    private var callback: ((String) -> Void)?
    private let statusItem = NSMenuItem(title: "Stopped", action: nil, keyEquivalent: "")
    private let startItem = NSMenuItem(title: "Start read-only bridge", action: #selector(command(_:)), keyEquivalent: "")
    private let stopItem = NSMenuItem(title: "Stop bridge", action: #selector(command(_:)), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at login", action: #selector(command(_:)), keyEquivalent: "")
    required override init() { super.init() }
    func install(callback: @escaping (String) -> Void) {
        guard item == nil else { return }
        self.callback = callback
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "house", accessibilityDescription: "HomeKit Local")
        let menu = NSMenu()
        menu.autoenablesItems = false
        statusItem.isEnabled = false; menu.addItem(statusItem)
        menu.addItem(.separator())
        add("Settings…", command: "settings", to: menu)
        startItem.representedObject = "start"; startItem.target = self; menu.addItem(startItem)
        stopItem.representedObject = "stop"; stopItem.target = self; menu.addItem(stopItem)
        menu.addItem(.separator())
        loginItem.representedObject = "login"; loginItem.target = self; menu.addItem(loginItem)
        add("Login settings…", command: "login-settings", to: menu)
        add("Show status files", command: "status", to: menu)
        menu.addItem(.separator())
        add("Quit HomeKit Local", command: "quit", to: menu)
        item.menu = menu; self.item = item
    }
    private func add(_ title: String, command: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: #selector(self.command(_:)), keyEquivalent: "")
        item.representedObject = command; item.target = self; menu.addItem(item)
    }
    @objc private func command(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String else { return }
        callback?(command)
    }
    func update(status: String, running: Bool, busy: Bool, loginStatus: String) {
        statusItem.title = status
        startItem.isEnabled = !running && !busy; stopItem.isEnabled = running || busy
        loginItem.state = loginStatus == "enabled" ? .on : (loginStatus == "requires_approval" ? .mixed : .off)
        item?.button?.image = NSImage(systemSymbolName: running ? "house.fill" : "house", accessibilityDescription: "HomeKit Local: \(status)")
        item?.button?.toolTip = "HomeKit Local: \(status)"
    }
    func launchedAtLogin() -> Bool {
        // Public Apple-event flag ('lgit'); do not guess from process parents.
        NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: 0x6c676974)?.booleanValue ?? false
    }
    func showSettings() -> Bool {
        NSApp.unhide(nil)
        let windows = NSApp.windows.filter { $0.styleMask.contains(.titled) && $0.canBecomeKey }
        windows.forEach { $0.makeKeyAndOrderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)
        return !windows.isEmpty
    }
    func hideSettings() { NSApp.hide(nil) }
    func revealStatus() {
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/HomeKitMCP")
        NSWorkspace.shared.activateFileViewerSelecting([directory.appendingPathComponent("status.json")])
    }
    func terminate() { NSApp.terminate(nil) }
}
