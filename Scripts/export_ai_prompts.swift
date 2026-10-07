import Foundation

/// Export the same prompts that the app copies; never maintain separate prompt text here.
/// Re-run after changing AIImportFormat.prompt(kind:maxWeeks:).
///
/// Build from the repository root:
/// DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
///   xcrun swiftc -parse-as-library Shared/Core/*.swift Scripts/export_ai_prompts.swift \
///   -o /tmp/courseflow-export-ai-prompts
/// Run: /tmp/courseflow-export-ai-prompts [output-directory]
@main
struct ExportAIImportPrompts {
    static func main() throws {
        let directory = URL(
            fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Fixtures",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files: [(ImportKind, String)] = [
            (.timetable, "AI课表识别提示词.txt"),
            (.bellSchedule, "AI作息识别提示词.txt")
        ]
        for (kind, name) in files {
            let destination = directory.appendingPathComponent(name)
            // Twenty weeks is only a validation context for the standalone samples.
            // The app supplies the selected semester's actual week count instead.
            let prompt = AIImportFormat.prompt(kind: kind, maxWeeks: 20)
            try (prompt + "\n").write(to: destination, atomically: true, encoding: .utf8)
            print(destination.path)
        }
    }
}
