import AppKit
import SwiftUI

@MainActor
final class ScanRootsSettingsController {
    private var window: NSWindow?

    func show() {
        let panel = makeWindowIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NSApp.arrangeInFront(nil)
    }

    private func makeWindowIfNeeded() -> NSWindow {
        if let window {
            return window
        }

        let rootView = ScanRootsSettingsView()
        let hostingView = NSHostingView(rootView: rootView)
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "扫描路径"
        panel.isReleasedWhenClosed = false
        panel.contentView = hostingView
        panel.center()
        self.window = panel
        return panel
    }
}

@MainActor
private final class ScanRootsSettingsModel: ObservableObject {
    @Published var roots: [String] = ScanRoots.orderedPaths()

    func addPaths(_ paths: [String]) {
        for path in paths {
            ScanRoots.add(path)
        }
        roots = ScanRoots.orderedPaths()
    }

    func remove(_ path: String) {
        ScanRoots.remove(path)
        roots = ScanRoots.orderedPaths()
    }
}

private struct ScanRootsSettingsView: View {
    @StateObject private var model = ScanRootsSettingsModel()
    @State private var typedPath = ""
    @State private var inputHint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("扫描路径")
                    .font(.system(size: 15, weight: .semibold))
                Text("只扫描这些目录下的一层子文件夹。它们不会出现在默认项目列表里，只有搜索时才会展示，点击即可打开。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    PastablePathField(
                        text: $typedPath,
                        placeholder: "输入或粘贴路径，例如 /Users/Shared/golang_project 或 ~/code",
                        onSubmit: addTypedPath
                    )
                    .frame(minHeight: 22)
                    Button("添加") {
                        addTypedPath()
                    }
                    Button("选择…") {
                        pickFolders()
                    }
                }
                if let inputHint {
                    Text(inputHint)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
            }

            if model.roots.isEmpty {
                Text("还没有配置扫描路径")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    )
            } else {
                List {
                    ForEach(model.roots, id: \.self) { path in
                        HStack(alignment: .center, spacing: 10) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(path)
                                .font(.system(size: 13))
                                .lineLimit(2)
                                .textSelection(.enabled)
                            Spacer(minLength: 8)
                            Button("移除") {
                                model.remove(path)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
                .frame(maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 360)
    }

    private func addTypedPath() {
        let raw = typedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            inputHint = "请输入路径，或点「选择…」挑文件夹"
            return
        }

        let lines = raw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var added: [String] = []
        for line in lines {
            switch validateRoot(line) {
            case .ok(let path):
                added.append(path)
            case .alreadyAdded(let path):
                if lines.count == 1 {
                    inputHint = "该路径已添加：\(path)"
                    return
                }
            case .missing(let path):
                inputHint = "路径不存在：\(path)"
                return
            case .notDirectory(let path):
                inputHint = "这不是文件夹：\(path)"
                return
            }
        }

        guard !added.isEmpty else {
            inputHint = "没有可添加的路径"
            return
        }
        model.addPaths(added)
        typedPath = ""
        inputHint = nil
    }

    private enum RootValidation {
        case ok(String)
        case alreadyAdded(String)
        case missing(String)
        case notDirectory(String)
    }

    private func validateRoot(_ raw: String) -> RootValidation {
        let path = LocalRecentProjects.normalize(raw)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .missing(path)
        }
        guard isDirectory.boolValue else {
            return .notDirectory(path)
        }
        if model.roots.contains(where: { LocalRecentProjects.normalize($0) == path }) {
            return .alreadyAdded(path)
        }
        return .ok(path)
    }

    private func pickFolders() {
        inputHint = nil
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = true
        openPanel.canCreateDirectories = false
        openPanel.prompt = "添加"
        openPanel.message = "选择要扫描的目录（只会扫描其中一层子文件夹）"
        guard openPanel.runModal() == .OK else { return }
        model.addPaths(openPanel.urls.map(\.path))
        typedPath = ""
    }
}

/// 原生 NSTextField，支持 ⌘V 和右键粘贴。SwiftUI TextField 在菜单栏应用里经常接不住粘贴。
private struct PastablePathField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = PasteAwareTextField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 13)
        field.focusRingType = .default
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        if field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = placeholder
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        @objc func submit() {
            onSubmit()
        }
    }
}

private final class PasteAwareTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }

        switch key {
        case "v":
            if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) {
                return true
            }
            pasteFromClipboard()
            return true
        case "c":
            return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
                || super.performKeyEquivalent(with: event)
        case "x":
            return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
                || super.performKeyEquivalent(with: event)
        case "a":
            return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
                || super.performKeyEquivalent(with: event)
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    private func pasteFromClipboard() {
        guard let pasted = NSPasteboard.general.string(forType: .string) else { return }
        if let editor = currentEditor() {
            editor.insertText(pasted)
        } else {
            stringValue += pasted
            NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: self)
        }
    }
}
