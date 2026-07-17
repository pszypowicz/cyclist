import AppKit
import ServiceManagement

final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem?

    // Flipping Enabled must install or tear down the event taps.
    var onEnabledToggled: ((Bool) -> Void)?
    // Side effects for toggles that need more than the UserDefaults write,
    // keyed by the defaults key each menu item carries.
    private var changeHandlers: [String: (Bool) -> Void] = [:]

    func setUp() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath",
            accessibilityDescription: "Cyclist"
        )
        // The dimmed template rendering is the disabled-state visual.
        item.button?.appearsDisabled = !Settings.enabled

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(makeToggle(title: "Enabled", key: Settings.enabledKey,
                                onChange: { [weak self] enabled in
                                    self?.statusItem?.button?.appearsDisabled = !enabled
                                    self?.onEnabledToggled?(enabled)
                                }))
        menu.addItem(.separator())
        menu.addItem(makeToggle(title: "Include hidden apps", key: Settings.includeHiddenKey))
        menu.addItem(makeToggle(title: "Include minimized apps", key: Settings.includeMinimizedKey))
        menu.addItem(makeToggle(title: "Include apps in other Spaces", key: Settings.includeOtherSpacesKey))
        menu.addItem(makeToggle(title: "Include apps with no windows", key: Settings.includeNoWindowsKey))
        menu.addItem(makeToggle(title: "Trackpad swipe navigation", key: Settings.trackpadSwipeKey))
        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())

        let aboutItem = NSMenuItem(title: "About Cyclist", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        aboutItem.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "Quit Cyclist", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    private func makeToggle(title: String, key: String, onChange: ((Bool) -> Void)? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(toggle(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = key
        item.state = UserDefaults.standard.bool(forKey: key) ? .on : .off
        if let onChange {
            changeHandlers[key] = onChange
        }
        return item
    }

    @objc private func showAbout() {
        AboutView.showWindow()
    }

    @objc private func toggle(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let newValue = !UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(newValue, forKey: key)
        sender.state = newValue ? .on : .off
        changeHandlers[key]?(newValue)
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
