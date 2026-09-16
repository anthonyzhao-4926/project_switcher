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
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "扫描路径和工作区"
        panel.isReleasedWhenClosed = false
        panel.contentView = hostingView
        panel.center()
        self.window = panel
        return panel
    }
}

@MainActor
private final class ScanRootsSettingsModel: ObservableObject {
    @Published var projectRoots: [String] = ScanRoots.orderedPaths()
    @Published var workspaceRoots: [String] = WorkspaceRoots.orderedPaths()

    func addProjectPaths(_ paths: [String]) {
        for path in paths {
            ScanRoots.add(path)
        }
        projectRoots = ScanRoots.orderedPaths()
    }

    func removeProject(_ path: String) {
        ScanRoots.remove(path)
        projectRoots = ScanRoots.orderedPaths()
    }

    func addWorkspacePaths(_ paths: [String]) {
        for path in paths {
            WorkspaceRoots.add(path)
        }
        workspaceRoots = WorkspaceRoots.orderedPaths()
    }

    func removeWorkspace(_ path: String) {
        WorkspaceRoots.remove(path)
        workspaceRoots = WorkspaceRoots.orderedPaths()
    }
}

private struct ScanRootsSettingsView: View {
    @StateObject private var model = ScanRootsSettingsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            RootPathSection(
                title: "项目目录",
                description: "只扫描这些目录下的一层子文件夹。它们不会出现在默认列表里，只有搜索时才会展示，点击即可打开。",
                emptyText: "还没有配置项目目录",
                placeholder: "例如 /Users/Shared/golang_project 或 ~/code",
                pickMessage: "选择要扫描的项目目录（只会扫描其中一层子文件夹）",
                icon: "folder",
                roots: model.projectRoots,
                onAdd: { model.addProjectPaths($0) },
                onRemove: { model.removeProject($0) }
            )
            Divider()
            RootPathSection(
                title: "工作区目录",
                description: "只扫描这些目录下的一层 `.code-workspace` 文件，不会把子文件夹当成项目。搜索时出现，点击后按当前窗口布局打开。",
                emptyText: "还没有配置工作区目录",
                placeholder: "例如 /Users/Shared/cursor_wordspace",
                pickMessage: "选择存放 .code-workspace 的目录（只会扫描其中一层工作区文件）",
                icon: "square.stack",
                roots: model.workspaceRoots,
                onAdd: { model.addWorkspacePaths($0) },
                onRemove: { model.removeWorkspace($0) }
            )
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 560)
    }
}

private struct RootPathSection: View {
    let title: String
    let description: String
    let emptyText: String
    let placeholder: String
    let pickMessage: String
    let icon: String
    let roots: [String]
    var onAdd: ([String]) -> Void
    var onRemove: (String) -> Void

    @State private var typedPath = ""
    @State private var inputHint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    PastablePathField(
                        text: $typedPath,
                        placeholder: placeholder,
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

            if roots.isEmpty {
                Text(emptyText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 88, maxHeight: .infinity, alignment: .center)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    )
            } else {
                List {
                    ForEach(roots, id: \.self) { path in
                        HStack(alignment: .center, spacing: 10) {
                            Image(systemName: icon)
                                .foregroundStyle(.secondary)
                            Text(path)
                                .font(.system(size: 13))
                                .lineLimit(2)
                                .textSelection(.enabled)
                            Spacer(minLength: 8)
                            Button("移除") {
                                onRemove(path)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 88, maxHeight: .infinity)
            }
        }
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
        onAdd(added)
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
        if roots.contains(where: { LocalRecentProjects.normalize($0) == path }) {
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
        openPanel.message = pickMessage
        guard openPanel.runModal() == .OK else { return }
        onAdd(openPanel.urls.map(\.path))
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
