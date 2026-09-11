import AppKit
import ServiceManagement

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let panelController: SwitcherPanelController
    private let loginItemMenuItem: NSMenuItem
    private let scanRootsSettings = ScanRootsSettingsController()

    init(panelController: SwitcherPanelController) {
        self.panelController = panelController
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        loginItemMenuItem = NSMenuItem(
            title: "登录时启动",
            action: #selector(toggleLoginItem(_:)),
            keyEquivalent: ""
        )
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "Project Switcher")
        }

        let menu = NSMenu()
        let showItem = NSMenuItem(
            title: "显示切换器  \(DefaultHotKey.display)",
            action: #selector(showSwitcher),
            keyEquivalent: ""
        )
        showItem.target = self
        menu.addItem(showItem)
        menu.addItem(.separator())

        let axItem = NSMenuItem(
            title: "打开辅助功能设置…",
            action: #selector(openAccessibility),
            keyEquivalent: ""
        )
        axItem.target = self
        menu.addItem(axItem)

        loginItemMenuItem.target = self
        loginItemMenuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItemMenuItem)

        let scanItem = NSMenuItem(
            title: "配置扫描路径…",
            action: #selector(openScanRoots),
            keyEquivalent: ""
        )
        scanItem.target = self
        menu.addItem(scanItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出 Project Switcher",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func showSwitcher() {
        panelController.show()
    }

    @objc private func openAccessibility() {
        _ = AccessibilityAuth.isTrusted(prompt: true)
        AccessibilityAuth.openSystemSettings()
    }

    @objc private func openScanRoots() {
        scanRootsSettings.show()
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                sender.state = .off
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
            }
        } catch let loginItemError {
            NSLog("登录项设置失败: \(loginItemError)")
            let alert = NSAlert()
            alert.messageText = "无法设置登录时启动"
            alert.informativeText = "请先把 App 装到 /Applications，再重试。\n\(loginItemError.localizedDescription)"
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
