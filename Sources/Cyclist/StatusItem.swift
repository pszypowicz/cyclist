import AppKit

final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem?

    // Flipping Enabled must install or tear down the event taps.
    var onEnabledToggled: ((Bool) -> Void)?

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

        let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.state = Settings.enabled ? .on : .off
        menu.addItem(enabledItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)

        let aboutItem = NSMenuItem(title: "About Cyclist", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        aboutItem.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        menu.addItem(aboutItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Cyclist", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        let enabled = !Settings.enabled
        UserDefaults.standard.set(enabled, forKey: Settings.enabledKey)
        sender.state = enabled ? .on : .off
        statusItem?.button?.appearsDisabled = !enabled
        onEnabledToggled?(enabled)
    }

    @objc private func showSettings() {
        SettingsView.showWindow()
    }

    @objc private func showAbout() {
        AboutView.showWindow()
    }
}
