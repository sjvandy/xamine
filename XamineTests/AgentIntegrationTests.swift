import Foundation
import Testing
@testable import Xamine

@Suite struct AgentIntegrationTests {
    @Test func skillHasFrontmatter() {
        let lines = AgentIntegration.skill.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == "---")
        #expect(lines[1] == "name: xamine")
        #expect(lines[2].hasPrefix("description: "))
        #expect(lines[3] == "---")
    }

    /// Runs the real `claude mcp add` against a throwaway CLAUDE_CONFIG_DIR, so the user's configuration isn't touched.
    @Test(.enabled(if: AgentIntegration.findClaude() != nil))
    func setsUpATarget() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "xamine-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = AgentIntegration.Target(name: "Test", configDirectory: directory)

        #expect(!AgentIntegration.isConfigured(target))
        let outcome = await AgentIntegration.setUp(target, claude: AgentIntegration.findClaude())
        #expect(outcome.error == nil, "\(outcome.error ?? "")")
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "skills/xamine/SKILL.md").path))
        #expect(AgentIntegration.isConfigured(target))

        // Running it again replaces the server instead of failing because it exists.
        let again = await AgentIntegration.setUp(target, claude: AgentIntegration.findClaude())
        #expect(again.error == nil, "\(again.error ?? "")")
    }
}
