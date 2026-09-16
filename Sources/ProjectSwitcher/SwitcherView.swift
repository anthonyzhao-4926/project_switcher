import AppKit
import SwiftUI

@MainActor
final class SwitcherViewModel: ObservableObject {
    @Published var query = ""
    @Published var projects: [OpenProject] = []
    @Published var scannedProjects: [OpenProject] = []
    @Published var selectedIndex = 0
    @Published var axTrusted = true
    @Published var statusMessage: String? = nil

    var filtered: [OpenProject] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return projects
        }
        let needle = trimmed.lowercased()
        let openMatches = projects.filter { matches($0, needle: needle) }
        let openKeys = Set(projects.map { LocalRecentProjects.normalize($0.path) })
        let scannedMatches = scannedProjects.filter { project in
            !openKeys.contains(LocalRecentProjects.normalize(project.path))
                && matches(project, needle: needle)
        }
        return openMatches + scannedMatches
    }

    func reload() {
        axTrusted = AccessibilityAuth.isTrusted(prompt: false)
        projects = CursorOpenProjects.list()
        scannedProjects = mergedScannedProjects()
        query = ""
        selectedIndex = 0
        statusMessage = nil
    }

    private func mergedScannedProjects() -> [OpenProject] {
        var seen = Set<String>()
        var result: [OpenProject] = []
        let scanned = ProjectFolderScanner.list(roots: ScanRoots.orderedPaths())
            + WorkspaceFileScanner.list(roots: WorkspaceRoots.orderedPaths())
        for project in scanned {
            let key = LocalRecentProjects.normalize(project.path)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(project)
        }
        return result
    }

    private func matches(_ project: OpenProject, needle: String) -> Bool {
        project.searchText.lowercased().contains(needle)
    }

    /// 选中后立刻置顶并持久化，下次打开也保持
    func promote(_ project: OpenProject) {
        LocalRecentProjects.touch(project.path)
        projects = CursorOpenProjects.list()
        selectedIndex = 0
        statusMessage = nil
    }

    func removeFromList(_ project: OpenProject) {
        LocalRecentProjects.remove(project.path)
        projects.removeAll { $0.path == project.path }
        if selectedIndex >= filtered.count {
            selectedIndex = max(filtered.count - 1, 0)
        }
    }

    /// 关闭成功后按真实打开窗口重刷，避免 storage.json 滞后把已关项目加回来
    func refreshAfterClose(_ project: OpenProject) {
        LocalRecentProjects.remove(project.path)
        let keepQuery = query
        projects = CursorOpenProjects.list().filter { live in
            LocalRecentProjects.normalize(live.path) != LocalRecentProjects.normalize(project.path)
                && live.name.caseInsensitiveCompare(project.name) != .orderedSame
        }
        query = keepQuery
        if selectedIndex >= filtered.count {
            selectedIndex = max(filtered.count - 1, 0)
        }
        statusMessage = nil
    }

    func moveSelection(_ delta: Int) {
        let items = filtered
        guard !items.isEmpty else {
            selectedIndex = 0
            return
        }
        let next = selectedIndex + delta
        selectedIndex = (next % items.count + items.count) % items.count
    }

    func selectedProject() -> OpenProject? {
        let items = filtered
        guard items.indices.contains(selectedIndex) else {
            return items.first
        }
        return items[selectedIndex]
    }
}

struct SwitcherView: View {
    @ObservedObject var model: SwitcherViewModel
    var onChoose: (OpenProject) -> Void
    var onClose: (OpenProject) -> Void
    var onOpenAccessibility: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if let statusMessage = model.statusMessage {
                HStack(spacing: 8) {
                    Text(statusMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Button("去设置") {
                        onOpenAccessibility()
                    }
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.05))
            }
            Divider().opacity(0.35)
            content
        }
        .frame(width: 680, height: 420)
        .background(VisualEffectBackground())
        .onChange(of: model.query) { _ in
            model.selectedIndex = 0
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("搜索已打开或扫描路径中的项目", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .regular))
                .focused($searchFocused)
                .onAppear { searchFocused = true }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var content: some View {
        if model.filtered.isEmpty {
            emptyState
        } else {
            resultList
        }
    }

    private var emptyState: some View {
        Text(emptyStateText)
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var emptyStateText: String {
        model.query.isEmpty ? "没有已打开的 Cursor 项目" : "没有匹配的项目"
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.filtered.enumerated()), id: \.element.id) { index, project in
                        ProjectRow(
                            project: project,
                            isSelected: index == model.selectedIndex,
                            onChoose: { onChoose(project) },
                            onClose: project.isOpen ? { onClose(project) } : nil
                        )
                        .id(project.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: .infinity)
            .onChange(of: model.selectedIndex) { index in
                if model.filtered.indices.contains(index) {
                    proxy.scrollTo(model.filtered[index].id, anchor: .center)
                }
            }
        }
    }
}

private struct ProjectRow: View {
    let project: OpenProject
    let isSelected: Bool
    var onChoose: () -> Void
    var onClose: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: rowIcon)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 28)
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(project.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .lineLimit(1)
                        if project.isWorkspace {
                            badge("工作区")
                        }
                        if !project.isOpen {
                            badge("未打开")
                        }
                    }
                    Text(project.path)
                        .font(.system(size: 12))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onChoose)

            if let onClose {
                CloseIconButton(isSelected: isSelected, action: onClose)
                    .frame(width: 28, height: 28)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
    }

    private var rowIcon: String {
        if project.isWorkspace {
            return project.isOpen ? "square.stack" : "plus.square.on.square"
        }
        return project.isOpen ? "folder" : "folder.badge.plus"
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule()
                    .fill(isSelected ? Color.white.opacity(0.18) : Color.primary.opacity(0.08))
            )
    }
}

/// 用 AppKit 按钮接点击，避免 SwiftUI 手势把关闭当成选中
private struct CloseIconButton: NSViewRepresentable {
    let isSelected: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = context.coordinator
        button.action = #selector(Coordinator.click)
        button.toolTip = "关闭项目"
        context.coordinator.action = action
        applyAppearance(button)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        applyAppearance(button)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    private func applyAppearance(_ button: NSButton) {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        button.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭")?
            .withSymbolConfiguration(config)
        button.contentTintColor = isSelected
            ? NSColor.white.withAlphaComponent(0.95)
            : NSColor.secondaryLabelColor
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func click() {
            action()
        }
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
