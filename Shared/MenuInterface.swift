import Foundation

// Compiled into both targets. The AppKit bundle is loaded only from our signed
// app's built-in PlugIns directory; no external plugin search paths exist.
@MainActor @objc(HomeKitMenuInterface) protocol HomeKitMenuInterface {
    init()
    func install(callback: @escaping (String) -> Void)
    func update(status: String, running: Bool, busy: Bool, loginStatus: String)
    func launchedAtLogin() -> Bool
    func showSettings() -> Bool
    func hideSettings()
    func revealStatus()
    func terminate()
}
