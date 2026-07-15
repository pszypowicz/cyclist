import AppKit
import ServiceManagement

final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem?

    // Flipping the AeroSpace toggle must start or stop the socket client,
    // not just rewrite the default, so it routes through the owner.
    var onAerospaceToggled: ((Bool) -> Void)?

    func setUp() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath",
            accessibilityDescription: "Cyclist"
        )

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(makeToggle(title: "Include hidden apps", key: Settings.includeHiddenKey))
        menu.addItem(makeToggle(title: "Include minimized apps", key: Settings.includeMinimizedKey))
        menu.addItem(makeToggle(title: "Include apps in other Spaces", key: Settings.includeOtherSpacesKey))
        menu.addItem(makeToggle(title: "Include apps with no windows", key: Settings.includeNoWindowsKey))
        let aerospaceItem = NSMenuItem(title: "AeroSpace integration", action: #selector(toggleAerospace(_:)), keyEquivalent: "")
        aerospaceItem.target = self
        aerospaceItem.state = Settings.aerospaceIntegration ? .on : .off
        menu.addItem(aerospaceItem)
        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let versionItem = NSMenuItem(title: "Cyclist \(version) (beta)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        let quitItem = NSMenuItem(title: "Quit Cyclist", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    private func makeToggle(title: String, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(toggle(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = key
        item.state = UserDefaults.standard.bool(forKey: key) ? .on : .off
        return item
    }

    @objc private func toggle(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let newValue = !UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(newValue, forKey: key)
        sender.state = newValue ? .on : .off
    }

    @objc private func toggleAerospace(_ sender: NSMenuItem) {
        let newValue = !Settings.aerospaceIntegration
        UserDefaults.standard.set(newValue, forKey: Settings.aerospaceIntegrationKey)
        sender.state = newValue ? .on : .off
        onAerospaceToggled?(newValue)
    }

    // Native login item via SMAppService: the app appears in System
    // Settings > General > Login Items and macOS owns the launch.
    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.write("launch at login toggle failed: \(error)")
        }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}
