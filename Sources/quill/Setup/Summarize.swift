import ArgumentParser
import Foundation

struct Summarize: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Generate or retry local meeting notes for one saved transcript.")
    @Argument(help: "Session directory containing transcript.json.")
    var session: String
    @Flag(name: .long, help: "Regenerate an existing summary.md.")
    var overwrite = false

    func run() async throws {
        guard let settings = try Config.summarySettings() else {
            throw ValidationError("Enable summaries and choose an installed Ollama model in Quill config, or run quill import-muesli.")
        }
        let directory = URL(fileURLWithPath: (session as NSString).expandingTildeInPath)
        let coordinator = SummaryCoordinator(settings: settings)
        try await coordinator.summarize(directory, overwrite: overwrite)
        print(directory.appendingPathComponent("summary.md").path)
    }
}
