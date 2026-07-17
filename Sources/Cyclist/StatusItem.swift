import AppKit

final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem?

    // Creates or removes the status item to match the setting; the owner
    // calls it at launch and from its defaults observation, so hiding or
    // showing the icon applies live. Idempotent.
    func refresh() {
        if Settings.showMenuBarIcon {
            guard statusItem == nil else { return }
            statusItem = makeItem()
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func makeItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath",
            accessibilityDescription: "Cyclist"
        )

        let menu = NSMenu()
        menu.autoenablesItems = false

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
        return item
    }

    @objc private func showSettings() {
        SettingsView.showWindow()
    }

    @objc private func showAbout() {
        AboutView.showWindow()
    }
}
