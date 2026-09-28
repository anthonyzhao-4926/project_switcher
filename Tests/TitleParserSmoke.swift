import Foundation

@main
enum TitleParserSmoke {
    static func main() {
        func expect(_ actual: String, _ expected: String, file: String = #file, line: Int = #line) {
            if actual != expected {
                fputs("FAIL \(file):\(line): got \(actual.debugDescription), expected \(expected.debugDescription)\n", stderr)
                exit(1)
            }
        }

        expect(
            TitleParser.projectName(from: "global-open-windows.md — project_manager — Cursor"),
            "project_manager"
        )
        expect(TitleParser.projectName(from: "project_switcher — Cursor"), "project_switcher")
        expect(
            TitleParser.projectName(from: "foo.ts — asa_keyword_bid_hive (工作区) — Cursor"),
            "asa_keyword_bid_hive"
        )
        expect(
            TitleParser.projectName(from: "asa 关键词批量改价 (Workspace) — Cursor"),
            "asa 关键词批量改价"
        )
        expect(
            TitleParser.projectName(from: "● bar.go — demo (工作区) — Cursor"),
            "demo"
        )
        if !TitleParser.isWorkspaceWindowTitle("foo.ts — demo (工作区) — Cursor") {
            fputs("FAIL: workspace title should be detected\n", stderr)
            exit(1)
        }
        if TitleParser.isWorkspaceWindowTitle("foo.ts — demo — Cursor") {
            fputs("FAIL: folder title should not be workspace\n", stderr)
            exit(1)
        }
        if !TitleParser.belongs(windowTitle: "a — demo (工作区) — Cursor", projectName: "demo") {
            fputs("FAIL: workspace window should belong to demo\n", stderr)
            exit(1)
        }
        if !TitleParser.belongs(
            windowTitle: "~/Library/Application Support/Cursor/User/globalStorage/local.cursor-workspace/workspaces/asa 关键词批量改价 (工作区) — Cursor",
            projectName: "asa 关键词批量改价"
        ) {
            fputs("FAIL: path-style workspace title should belong\n", stderr)
            exit(1)
        }

        if !TitleParser.shouldIgnore(title: "Cursor DevTools") {
            fputs("FAIL: DevTools should be ignored\n", stderr)
            exit(1)
        }
        if TitleParser.shouldIgnore(title: "project_switcher — Cursor") {
            fputs("FAIL: project window should not be ignored\n", stderr)
            exit(1)
        }
        if !TitleParser.belongs(windowTitle: "a — foo — Cursor", projectName: "foo") {
            fputs("FAIL: window should belong to foo\n", stderr)
            exit(1)
        }
        if TitleParser.belongs(windowTitle: "a — third_party_ads — Cursor", projectName: "ads") {
            fputs("FAIL: ads should not match third_party_ads\n", stderr)
            exit(1)
        }
        if !TitleParser.matches(windowTitle: "a — foo — Cursor", projectName: "foo", query: "FO") {
            fputs("FAIL: query should match project name\n", stderr)
            exit(1)
        }
        print("TitleParser smoke tests passed")
    }
}
