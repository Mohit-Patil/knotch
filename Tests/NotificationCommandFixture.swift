import Foundation
@main struct CommandFixture {
    @MainActor static func main() throws {
        let data = try JSONSerialization.data(withJSONObject: ["claude": AgentNotificationSettings.claudeCommand, "codex": AgentNotificationSettings.codexCommand])
        FileHandle.standardOutput.write(data)
    }
}
