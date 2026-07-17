import AppKit

final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem?
    private var enabledItem: NSMenuItem?

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

        let enabled = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.target = self
        enabled.state = Settings.enabled ? .on : .off
        enabledItem = enabled
        menu.addItem(enabled)
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

    // The toggle only writes the setting; the owner's defaults observation
    // applies it (taps up or down) and calls refreshEnabled, the same path
    // an external `defaults write` takes.
    @objc private func toggleEnabled() {
        UserDefaults.standard.set(!Settings.enabled, forKey: Settings.enabledKey)
    }

    func refreshEnabled() {
        let enabled = Settings.enabled
        enabledItem?.state = enabled ? .on : .off
        statusItem?.button?.appearsDisabled = !enabled
    }

    @objc private func showSettings() {
        SettingsView.showWindow()
    }

    @objc private func showAbout() {
        AboutView.showWindow()
    }
}
