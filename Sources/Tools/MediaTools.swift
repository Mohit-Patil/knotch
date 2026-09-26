import AppKit
import Observation
import SwiftUI

private enum MediaApp: String, CaseIterable, Identifiable, Sendable {
    case music
    case spotify

    var id: String { bundleID }
    var bundleID: String {
        switch self {
        case .music: "com.apple.Music"
        case .spotify: "com.spotify.client"
        }
    }
    var name: String {
        switch self {
        case .music: "Music"
        case .spotify: "Spotify"
        }
    }
    var symbol: String { self == .music ? "music.note" : "music.note.list" }
    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

private struct MediaSnapshot: Sendable {
    let state: String
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let position: Double
    let artworkURL: String
    var trackKey: String { "\(title)\u{0}\(artist)\u{0}\(album)\u{0}\(duration)" }
}

private enum MediaBridgeError: Error, Sendable {
    case unavailable
    case permissionDenied
    case failed

    var message: String {
        switch self {
        case .unavailable: "The player is no longer running. Open it and connect again."
        case .permissionDenied: "Automation access was denied. Allow Knotch to control this player in System Settings → Privacy & Security → Automation, then reconnect."
        case .failed: "The player did not respond. Try reconnecting."
        }
    }
}

/// NSAppleScript may wait for another process. All of its work is serialized off the UI thread.
private final class MediaScriptBridge: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.personal.Knotch.media-apple-events", qos: .userInitiated)

    func snapshot(for app: MediaApp) async -> Result<MediaSnapshot, MediaBridgeError> {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Result {
                    guard app.isRunning else { throw MediaBridgeError.unavailable }
                    let result = try Self.execute(Self.snapshotScript(for: app))
                    func text(_ index: Int) -> String { result.atIndex(index)?.stringValue ?? "" }
                    let rawDuration = result.atIndex(5)?.doubleValue ?? 0
                    let duration = app == .spotify ? rawDuration / 1_000 : rawDuration
                    return MediaSnapshot(state: text(1), title: text(2), artist: text(3),
                                         album: text(4), duration: max(0, duration),
                                         position: max(0, result.atIndex(6)?.doubleValue ?? 0),
                                         artworkURL: text(7))
                }.mapError { $0 as? MediaBridgeError ?? .failed })
            }
        }
    }

    func command(_ command: Command, for app: MediaApp) async -> Result<Void, MediaBridgeError> {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Result {
                    guard app.isRunning else { throw MediaBridgeError.unavailable }
                    // Every command is chosen here. Track metadata and other external strings
                    // are never interpolated into AppleScript source.
                    let verb: String
                    switch command {
                    case .playPause: verb = "playpause"
                    case .next: verb = "next track"
                    case .previous: verb = "previous track"
                    case .seek(let seconds):
                        guard seconds.isFinite, (0...86_400).contains(seconds) else {
                            throw MediaBridgeError.failed
                        }
                        verb = "set player position to \(Int(seconds.rounded()))"
                    }
                    _ = try Self.execute("tell application id \"\(app.bundleID)\" to \(verb)")
                }.mapError { $0 as? MediaBridgeError ?? .failed })
            }
        }
    }

    func musicArtwork() async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard MediaApp.music.isRunning else { continuation.resume(returning: nil); return }
                let source = """
                tell application id "com.apple.Music"
                    try
                        return raw data of artwork 1 of current track
                    on error
                        return missing value
                    end try
                end tell
                """
                let result = try? Self.execute(source)
                continuation.resume(returning: result?.data)
            }
        }
    }

    enum Command: Sendable {
        case playPause, next, previous, seek(Double)
    }

    private static func snapshotScript(for app: MediaApp) -> String {
        let artwork = app == .spotify ? "artwork url of activeTrack" : "\"\""
        return """
        tell application id "\(app.bundleID)"
            if player state is playing then
                set stateText to "playing"
            else if player state is paused then
                set stateText to "paused"
            else
                set stateText to "stopped"
            end if
            if stateText is "stopped" then return {stateText, "", "", "", 0, 0, ""}
            set activeTrack to current track
            return {stateText, name of activeTrack, artist of activeTrack, album of activeTrack, duration of activeTrack, player position, \(artwork)}
        end tell
        """
    }

    private static func execute(_ source: String) throws -> NSAppleEventDescriptor {
        // An unresponsive player must not leave Connect's native-dialog state
        // open indefinitely. This applies to reads, artwork, and controls.
        let boundedSource = """
        with timeout of 8 seconds
        \(source)
        end timeout
        """
        guard let script = NSAppleScript(source: boundedSource) else { throw MediaBridgeError.failed }
        var error: NSDictionary?
        let result: NSAppleEventDescriptor? = script.executeAndReturnError(&error)
        if error != nil {
            let code = error?["NSAppleScriptErrorNumber"] as? Int
            if code == -1743 { throw MediaBridgeError.permissionDenied }
            if code == -600 { throw MediaBridgeError.unavailable }
            throw MediaBridgeError.failed
        }
        guard let result else { throw MediaBridgeError.failed }
        return result
    }
}

@MainActor @Observable
final class MediaToolsStore {
    private let bridge = MediaScriptBridge()
    private var pollTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var artworkKey: String?
    private var generation = 0
    private var isVisible = false

    private(set) var installedApps: [String] = []
    private(set) var runningApps: [String] = []
    private(set) var connectedAppID: String?
    private(set) var isConnecting = false
    private(set) var status: String?
    private(set) var title = ""
    private(set) var artist = ""
    private(set) var album = ""
    private(set) var state = "stopped"
    private(set) var duration: Double = 0
    private(set) var position: Double = 0
    private(set) var artwork: NSImage?

    init() {}

    func setVisible(_ visible: Bool) {
        isVisible = visible
        if visible {
            refreshApplications()
            startPollingIfNeeded()
        } else {
            // Any in-flight Connect, command, or poll belongs to the old
            // presentation. Its result may arrive after the panel has closed.
            generation += 1
            isConnecting = false
            pollTask?.cancel()
            pollTask = nil
            artworkTask?.cancel()
            artworkTask = nil
            artworkKey = nil
        }
    }

    func shutdown() {
        setVisible(false)
        generation += 1
        connectedAppID = nil
        isConnecting = false
        clearTrack()
    }

    func refreshApplications() {
        installedApps = MediaApp.allCases.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil
        }.map(\.bundleID)
        runningApps = MediaApp.allCases.filter(\.isRunning).map(\.bundleID)
    }

    func connect(to bundleID: String, context: ToolsContext) {
        guard let app = MediaApp.allCases.first(where: { $0.bundleID == bundleID }),
              app.isRunning, !isConnecting else {
            refreshApplications()
            status = "Open the player before connecting."
            return
        }
        generation += 1
        let request = generation
        pollTask?.cancel()
        artworkTask?.cancel()
        connectedAppID = nil
        isConnecting = true
        status = nil
        clearTrack()
        // Only an explicit Connect tap can reach this first Automation request.
        context.beginDialog()
        Task {
            defer { context.endDialog() }
            let result = await bridge.snapshot(for: app)
            guard request == generation else { return }
            isConnecting = false
            switch result {
            case .success(let snapshot):
                connectedAppID = app.bundleID
                apply(snapshot, for: app)
                startPollingIfNeeded()
            case .failure(let error):
                status = error.message
                refreshApplications()
            }
        }
    }

    func disconnect() {
        generation += 1
        pollTask?.cancel()
        pollTask = nil
        artworkTask?.cancel()
        artworkTask = nil
        connectedAppID = nil
        status = nil
        clearTrack()
    }

    func playPause() { send(.playPause) }
    func next() { send(.next) }
    func previous() { send(.previous) }
    func seek(to seconds: Double) {
        guard duration > 0 else { return }
        send(.seek(min(max(0, seconds), duration)))
    }

    private func send(_ command: MediaScriptBridge.Command) {
        guard let app = MediaApp.allCases.first(where: { $0.bundleID == connectedAppID }) else { return }
        let request = generation
        Task {
            let result = await bridge.command(command, for: app)
            guard request == generation else { return }
            switch result {
            case .success:
                await updateSnapshot(for: app, request: request)
            case .failure(let error):
                fail(error)
            }
        }
    }

    private func startPollingIfNeeded() {
        guard isVisible, pollTask == nil,
              let app = MediaApp.allCases.first(where: { $0.bundleID == connectedAppID }) else { return }
        let request = generation
        pollTask = Task {
            while !Task.isCancelled, request == generation, isVisible {
                await updateSnapshot(for: app, request: request)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func updateSnapshot(for app: MediaApp, request: Int) async {
        let result = await bridge.snapshot(for: app)
        guard request == generation, connectedAppID == app.bundleID else { return }
        switch result {
        case .success(let snapshot): apply(snapshot, for: app)
        case .failure(let error): fail(error)
        }
    }

    private func fail(_ error: MediaBridgeError) {
        disconnect()
        status = error.message
        refreshApplications()
    }

    private func apply(_ snapshot: MediaSnapshot, for app: MediaApp) {
        let changed = title != snapshot.title || artist != snapshot.artist || album != snapshot.album
        title = snapshot.title
        artist = snapshot.artist
        album = snapshot.album
        state = snapshot.state
        duration = snapshot.duration
        position = min(snapshot.duration, snapshot.position)
        status = nil
        guard changed || artworkKey != snapshot.trackKey else { return }
        artworkTask?.cancel()
        artwork = nil
        artworkKey = snapshot.trackKey
        guard isVisible, !snapshot.title.isEmpty else { return }
        let request = generation
        artworkTask = Task {
            let bytes: Data?
            if app == .music {
                bytes = await bridge.musicArtwork()
            } else if let url = URL(string: snapshot.artworkURL),
                      url.scheme == "https",
                      let host = url.host?.lowercased(),
                      host == "i.scdn.co" || host == "images.spotify.com" {
                let response = try? await URLSession.shared.data(from: url)
                bytes = response.flatMap { $0.0.count <= 5_000_000 ? $0.0 : nil }
            } else {
                bytes = nil
            }
            guard !Task.isCancelled, request == generation,
                  connectedAppID == app.bundleID, title == snapshot.title,
                  artist == snapshot.artist else { return }
            artwork = bytes.flatMap(NSImage.init(data:))
        }
    }

    private func clearTrack() {
        title = ""
        artist = ""
        album = ""
        state = "stopped"
        duration = 0
        position = 0
        artwork = nil
        artworkKey = nil
    }
}

struct MediaToolsView: View {
    let store: MediaToolsStore
    let context: ToolsContext
    @State private var seekValue: Double = 0
    @State private var isScrubbing = false

    private let accent = Color(red: 0.59, green: 0.73, blue: 1)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("NOW PLAYING")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .tracking(2)
                            .foregroundStyle(accent)
                        Text("Music at a glance")
                            .font(.system(size: 25, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Connect a running player to view and control it.")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer()
                    Button { store.refreshApplications() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.7))
                    .accessibilityLabel("Refresh music players")
                }

                if let message = store.status {
                    Label(message, systemImage: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange.opacity(0.9))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }

                playerCard
                sourceList
            }
            .padding(22)
        }
        .background(Color(red: 0.105, green: 0.111, blue: 0.124))
        .preferredColorScheme(.dark)
        .onChange(of: store.position) { _, newValue in
            if !isScrubbing { seekValue = newValue }
        }
        .onChange(of: store.title) { _, _ in
            isScrubbing = false
            seekValue = store.position
        }
    }

    private var playerCard: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                Group {
                    if let art = store.artwork {
                        Image(nsImage: art).resizable().scaledToFill()
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.white.opacity(0.38))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.white.opacity(0.06))
                    }
                }
                .frame(width: 92, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.title.isEmpty ? "Nothing playing" : store.title)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(2)
                        .foregroundStyle(.white)
                    Text(store.artist.isEmpty ? "Connect Music or Spotify" : store.artist)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .foregroundStyle(.white.opacity(0.66))
                    if !store.album.isEmpty {
                        Text(store.album)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .foregroundStyle(.white.opacity(0.42))
                    }
                }
                Spacer(minLength: 0)
            }
            if store.connectedAppID != nil {
                VStack(spacing: 4) {
                    Slider(value: $seekValue, in: 0...max(1, store.duration)) { editing in
                        isScrubbing = editing
                        if !editing { store.seek(to: seekValue) }
                    }
                    .tint(accent)
                    .disabled(store.duration <= 0 || store.title.isEmpty)
                    .accessibilityLabel("Playback position")
                    HStack {
                        Text(time(seekValue))
                        Spacer()
                        Text(time(store.duration))
                    }
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
                }
                HStack(spacing: 28) {
                    control("backward.end.fill", "Previous track") { store.previous() }
                    control(store.state == "playing" ? "pause.fill" : "play.fill",
                            store.state == "playing" ? "Pause" : "Play") { store.playPause() }
                        .font(.system(size: 22))
                    control("forward.end.fill", "Next track") { store.next() }
                }
                .disabled(store.title.isEmpty)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)) }
    }

    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PLAYERS")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.5)
                .foregroundStyle(.white.opacity(0.45))
            ForEach(MediaApp.allCases) { app in
                let installed = store.installedApps.contains(app.bundleID)
                let running = store.runningApps.contains(app.bundleID)
                let connected = store.connectedAppID == app.bundleID
                HStack(spacing: 12) {
                    Image(systemName: app.symbol)
                        .frame(width: 24)
                        .foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(.system(size: 13, weight: .medium))
                        Text(connected ? "Connected" : running ? "Running" : installed ? "Not running" : "Not installed")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer()
                    if connected {
                        Button("Disconnect") { store.disconnect() }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white.opacity(0.6))
                    } else {
                        Button(store.isConnecting ? "Connecting…" : "Connect") {
                            store.connect(to: app.bundleID, context: context)
                        }
                        .disabled(!running || store.isConnecting)
                        .buttonStyle(.plain)
                        .foregroundStyle(running ? accent : .white.opacity(0.35))
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(12)
                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }
            Text("Uses macOS Automation for the selected app. Browser audio is not available here.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.38))
        }
    }

    private func control(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel(label)
    }

    private func time(_ value: Double) -> String {
        guard value.isFinite else { return "0:00" }
        let seconds = Int(max(0, value))
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}
