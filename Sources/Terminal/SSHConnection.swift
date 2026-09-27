import Foundation

enum RemoteShell: String, Codable, CaseIterable {
    case accountDefault = "Account default", bash = "bash", zsh = "zsh", fish = "fish"
}

struct SSHConnection: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var host: String
    var user: String = ""
    var port: Int? = nil
    var shell: RemoteShell = .accountDefault
    var remoteDirectory: String = ""

    var identity: String { (user.isEmpty ? "" : "\(user)@") + host + (port.map { ":\($0)" } ?? "") }

    func validated() throws -> SSHConnection {
        func fail(_ message: String) throws -> Never { throw SSHProfileError.invalid(message) }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            try fail("Enter a connection name of up to 80 characters without control characters.")
        }
        let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:")
        guard !host.isEmpty, host.count <= 253, !host.hasPrefix("-"),
              host.unicodeScalars.allSatisfy({ hostCharacters.contains($0) }) else {
            try fail("Enter an SSH alias, hostname, or IPv4/IPv6 address without spaces or options.")
        }
        let userCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard user.count <= 128, !user.hasPrefix("-"), user.unicodeScalars.allSatisfy({ userCharacters.contains($0) }) else {
            try fail("Enter a username without spaces or options, or leave it blank to use SSH configuration.")
        }
        if let port, !(1...65535).contains(port) { try fail("Port must be between 1 and 65535.") }
        guard remoteDirectory.count <= 4096,
              !remoteDirectory.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            try fail("The remote directory must not contain control characters.")
        }
        guard remoteDirectory.isEmpty || remoteDirectory.hasPrefix("/") else {
            try fail("Use an absolute remote directory, or leave it blank for the account’s home directory.")
        }
        return self
    }

    /// Ghostty's embedded command is a shell string. Quote every argument at
    /// the local boundary and separately quote paths at the remote boundary.
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func launchCommand() throws -> String {
        _ = try validated()
        var args = ["/usr/bin/ssh", "-t"]
        if !user.isEmpty { args += ["-l", user] }
        if let port { args += ["-p", String(port)] }
        args += [host]
        if shell != .accountDefault || !remoteDirectory.isEmpty {
            var remote = ""
            if !remoteDirectory.isEmpty { remote = "cd " + Self.quote(remoteDirectory) + " && " }
            remote += shell == .accountDefault ? "exec \"${SHELL:-/bin/sh}\" -l" : "exec \(shell.rawValue) -l"
            args += ["exec /bin/sh -c " + Self.quote(remote)]
        }
        // The pinned macOS engine adds exec itself; do not prefix a second exec.
        // Widely available remote terminfo; no automatic installation on servers.
        return "/usr/bin/env TERM=xterm-256color " + args.map(Self.quote).joined(separator: " ")
    }
}

enum SSHProfileError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let value): value } }
}

enum TerminalLaunchTarget: Equatable {
    case local(URL)
    case ssh(SSHConnection)
    var localDirectory: URL {
        switch self { case .local(let directory): directory; case .ssh: FileManager.default.homeDirectoryForCurrentUser }
    }
    var remoteConnection: SSHConnection? { if case .ssh(let profile) = self { profile } else { nil } }
}

@MainActor
final class SSHConnectionStore {
    private let defaults: UserDefaults
    private let key = "ssh.connections.v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() throws -> [SSHConnection] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return try JSONDecoder().decode([SSHConnection].self, from: data)
    }
    func save(_ connections: [SSHConnection]) throws {
        for connection in connections { _ = try connection.validated() }
        defaults.set(try JSONEncoder().encode(connections), forKey: key)
    }
}
