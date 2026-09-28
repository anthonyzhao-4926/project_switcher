import AppKit
import SwiftUI

@MainActor
final class SwitcherPanelController: NSObject {
    private let model = SwitcherViewModel()
    private var panel: KeyablePanel?
    private var localKeyMonitor: Any?
    private var globalMouseMonitor: Any?

    func toggle() {
        if panel?.isVisible == true {
            hide()
        } else {
            show()
        }
    }

    func show() {
        model.reload()
        let panel = makePanelIfNeeded()
        layout(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
    }

    func hide() {
        removeMonitors()
        panel?.orderOut(nil)
    }

    private func makePanelIfNeeded() -> KeyablePanel {
        if let panel {
            return panel
        }

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 420),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        let rootView = SwitcherView(
            model: model,
            onChoose: { [weak self] project in
                self?.choose(project)
            },
            onClose: { [weak self] project in
                self?.close(project)
            },
            onOpenAccessibility: {
                // 只打开设置页，不主动弹出系统授权对话框
                AccessibilityAuth.openSystemSettings()
            }
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 16
        hostingView.layer?.masksToBounds = true
        panel.contentView = hostingView

        self.panel = panel
        return panel
    }

    private func layout(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return
        }
        let width: CGFloat = 680
        let height: CGFloat = 420
        let origin = NSPoint(
            x: screen.visibleFrame.midX - width / 2,
            y: screen.visibleFrame.midY - height / 2 + 60
        )
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
    }

    private func installMonitors() {
        removeMonitors()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handleGlobalMouse(event)
        }
    }

    private func removeMonitors() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        if (panel?.firstResponder as? NSTextView)?.hasMarkedText() == true {
            return event
        }

        switch event.keyCode {
        case 53:
            hide()
            return nil
        case 36, 76:
            if let project = model.selectedProject() {
                choose(project)
            } else {
                hide()
            }
            return nil
        case 125:
            model.moveSelection(1)
            return nil
        case 126:
            model.moveSelection(-1)
            return nil
        default:
            return event
        }
    }

    private func handleGlobalMouse(_ event: NSEvent) {
        guard let panel, panel.isVisible else {
            return
        }
        let screenPoint = NSEvent.mouseLocation
        if !panel.frame.contains(screenPoint) {
            hide()
        }
    }

    private func choose(_ project: OpenProject) {
        model.promote(project)
        hide()
        WindowFocuser.focusProject(project)
    }

    private func close(_ project: OpenProject) {
        model.statusMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let closed = WindowFocuser.closeProjectWindow(project)
            DispatchQueue.main.async {
                if closed {
                    self.model.refreshAfterClose(project)
                } else if !AccessibilityAuth.isTrusted(prompt: false) {
                    self.model.statusMessage = "没能关掉工作区：请重新勾选辅助功能后再试"
                    AccessibilityAuth.openSystemSettings()
                } else {
                    self.model.statusMessage = "没能关掉该项目窗口"
                }
                if let panel = self.panel, panel.isVisible {
                    panel.makeKeyAndOrderFront(nil)
                }
            }
        }
    }
}

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
