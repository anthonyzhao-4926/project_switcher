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
