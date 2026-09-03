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
