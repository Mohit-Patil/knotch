import Foundation

@main
struct SSHConnectionTests {
    @MainActor static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("knotch-ssh-tests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func run(_ command: String) throws -> (Int32, String) {
            let task = Process(), pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", command]
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return (task.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        let sentinel = folder.appendingPathComponent("injected").path
        let payloads = ["plain", "a'b", "日本語 space", "$(touch \(sentinel))", "`touch \(sentinel)`", "; touch \(sentinel)", "", "line\nnext"]
        for payload in payloads {
            let result = try run("printf %s " + SSHConnection.quote(payload))
            precondition(result.0 == 0 && result.1 == payload, "Shell quote round-trip")
        }
        precondition(!FileManager.default.fileExists(atPath: sentinel))
        for host in ["-oProxyCommand=evil", "server;touch", "$(whoami)", "server name", "", "a\n"] {
            do { _ = try SSHConnection(name: "Test", host: host).validated(); preconditionFailure("Unsafe host accepted") }
            catch {}
        }
        for port in [0, -1, 65536] {
            do { _ = try SSHConnection(name: "Test", host: "server", port: port).validated(); preconditionFailure("Invalid port accepted") }
            catch {}
        }
        let recorder = folder.appendingPathComponent("record args")
        try "#!/bin/sh\nprintf '%s\\n' \"$TERM\" \"$@\"\n".write(to: recorder, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recorder.path)
        let profile = SSHConnection(name: "Dev", host: "::1", user: "deploy", port: 2222, shell: .bash,
                                    remoteDirectory: "/missing/'$(touch \(sentinel));日本語")
        let launch = try profile.launchCommand()
        let recording = launch.replacingOccurrences(of: SSHConnection.quote("/usr/bin/ssh"), with: SSHConnection.quote(recorder.path))
        let output = try run(recording).1.components(separatedBy: "\n")
        precondition(Array(output.prefix(7)) == ["xterm-256color", "-t", "-l", "deploy", "-p", "2222", "::1"])
        let remote = output[7]
        let remoteResult = try run(remote)
        precondition(remoteResult.0 != 0, "Missing remote directory must stop shell launch")
        precondition(!FileManager.default.fileExists(atPath: sentinel), "Remote command injection")
        let simple = try SSHConnection(name: "Alias", host: "production").launchCommand()
        precondition(!simple.contains("exec \"${SHELL"), "Default preserves server shell and configured RemoteCommand")
        let suite = "dev.personal.Knotch.ssh-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SSHConnectionStore(defaults: defaults)
        try store.save([profile])
        let restored = try store.load()
        precondition(restored == [profile])
        try store.save([])
        let empty = try store.load()
        precondition(empty.isEmpty)
        defaults.set(Data("bad JSON".utf8), forKey: "ssh.connections.v1")
        do { _ = try store.load(); preconditionFailure("Corrupt profiles silently discarded") } catch {}
        print("SSH validation, local/remote quoting, argument boundaries, TERM, and persistence tests passed")
    }
}
