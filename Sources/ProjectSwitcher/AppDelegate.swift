import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: SwitcherPanelController?
    private var statusItemController: StatusItemController?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--dump-windows") {
            WindowFocuser.dumpWindows(to: "/tmp/project-switcher-dump.txt")
            NSApp.terminate(nil)
            return
        }

        if hasOtherRunningInstance() {
            NSApp.terminate(nil)
            return
        }

        AppMainMenu.install()

        let panelController = SwitcherPanelController()
        self.panelController = panelController
        statusItemController = StatusItemController(panelController: panelController)

        HotKeyManager.shared.onPressed = {
            Task { @MainActor in
                panelController.toggle()
            }
        }
        HotKeyManager.shared.register()
        DispatchQueue.global(qos: .utility).async {
            CursorCloseBridge.ensureExtensionInstalled()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyManager.shared.unregister()
    }

    private func hasOtherRunningInstance() -> Bool {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let bundleId = Bundle.main.bundleIdentifier ?? "com.zhaoxin.ProjectSwitcher"
        return NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier == bundleId && app.processIdentifier != myPID
        }
    }
}

/// 菜单栏应用默认没有「编辑」菜单，⌘V / 右键粘贴不会进输入框。
enum AppMainMenu {
    static func install() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "隐藏 Project Switcher", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Project Switcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }
}
