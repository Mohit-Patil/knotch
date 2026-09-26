import CoreAudio
import Darwin
import Dispatch
import IOKit.pwr_mgt
import Observation
import SwiftUI

enum SystemTool: String, CaseIterable {
    case stats
    case keepAwake
    case volume

    var title: String {
        switch self {
        case .stats: "System stats"
        case .keepAwake: "Keep awake"
        case .volume: "Volume"
        }
    }

    var symbol: String {
        switch self {
        case .stats: "waveform.path.ecg"
        case .keepAwake: "sun.max"
        case .volume: "speaker.wave.2"
        }
    }
}

@MainActor @Observable
final class SystemToolsStore {
    enum AwakeDuration: Int, CaseIterable, Identifiable {
        case thirtyMinutes = 30
        case oneHour = 60
        case twoHours = 120
        case untilTurnedOff = 0

        var id: Int { rawValue }
        var label: String {
            switch self {
            case .thirtyMinutes: "30 minutes"
            case .oneHour: "1 hour"
            case .twoHours: "2 hours"
            case .untilTurnedOff: "Until turned off"
            }
        }
    }

    var cpuPercent: Double?
    var memoryUsedBytes: UInt64?
    var memoryTotalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    var downloadBytesPerSecond: Double?
    var uploadBytesPerSecond: Double?
    var statsMessage: String?

    var awakeDuration: AwakeDuration = .oneHour
    private(set) var isKeepingAwake = false
    private(set) var awakeUntil: Date?
    private(set) var awakeMessage: String?

    private(set) var outputDeviceName = "Checking output…"
    private(set) var volume = 0.0
    private(set) var hasReadableVolume = false
    private(set) var isMuted = false
    private(set) var canSetVolume = false
    private(set) var canSetMute = false
    private(set) var volumeMessage: String?
    private(set) var volumeFeedback: String?
    private(set) var showVolumeHUD: Bool
    private(set) var volumeHUDMessage: String?
    var onVolumeHUD: ((Double, Bool) -> Void)?

    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var visibleTool: SystemTool?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var feedbackTask: Task<Void, Never>?
    @ObservationIgnored private var previousCPU: CPUTicks?
    @ObservationIgnored private var previousNetwork: NetworkCounters?
    @ObservationIgnored private var outputDevice: AudioDeviceID = kAudioObjectUnknown
    @ObservationIgnored private var volumeElements: [AudioObjectPropertyElement] = []
    @ObservationIgnored private var muteElements: [AudioObjectPropertyElement] = []
    @ObservationIgnored private var controlError: String?
    @ObservationIgnored private var assertionID: IOPMAssertionID = 0
    @ObservationIgnored private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var deviceListeners: [DeviceListener] = []

    private struct DeviceListener {
        let device: AudioDeviceID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private static let volumeHUDPreferenceKey = "Knotch.showVolumeHUD"

    init() {
        showVolumeHUD = UserDefaults.standard.bool(forKey: Self.volumeHUDPreferenceKey)
        if showVolumeHUD {
            readOutputState()
            if !installVolumeListeners() {
                showVolumeHUD = false
                volumeHUDMessage = "This output device cannot provide volume change notifications."
            }
        }
    }

    /// The owning panel should call this when it appears and disappears.
    func setVisible(_ visible: Bool, tool: SystemTool? = nil) {
        // A disappearing old tab must not stop a newly appeared tool's timer.
        if !visible, let tool, visibleTool != tool { return }
        pollTimer?.invalidate()
        pollTimer = nil
        if visible {
            visibleTool = tool
            sample()
            if tool != .keepAwake {
                pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.sample() }
                }
            }
        } else {
            visibleTool = nil
            previousCPU = nil
            previousNetwork = nil
            cpuPercent = nil
            downloadBytesPerSecond = nil
            uploadBytesPerSecond = nil
        }
    }

    /// Release this app's power assertion when the owner is torn down.
    func shutdown() {
        setVisible(false)
        removeVolumeListeners()
        expiryTask?.cancel()
        expiryTask = nil
        feedbackTask?.cancel()
        feedbackTask = nil
        releaseAwakeAssertion()
    }

    func setShowVolumeHUD(_ enabled: Bool) {
        guard enabled != showVolumeHUD else { return }
        if enabled {
            readOutputState()
            guard installVolumeListeners() else {
                volumeHUDMessage = "This output device cannot provide volume change notifications."
                return
            }
            showVolumeHUD = true
            volumeHUDMessage = nil
        } else {
            showVolumeHUD = false
            removeVolumeListeners()
            volumeHUDMessage = nil
        }
        UserDefaults.standard.set(showVolumeHUD, forKey: Self.volumeHUDPreferenceKey)
    }

    func setKeepingAwake(_ enabled: Bool) {
        if enabled {
            guard !isKeepingAwake else { return }
            var newID: IOPMAssertionID = 0
            let status = IOPMAssertionCreateWithName(
                kIOPMAssertionTypeNoIdleSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Knotch Keep Awake" as CFString,
                &newID
            )
            guard status == kIOReturnSuccess else {
                awakeMessage = "macOS could not start Keep Awake (\(status))."
                return
            }
            assertionID = newID
            isKeepingAwake = true
            awakeMessage = nil
            scheduleAwakeExpiry()
        } else {
            releaseAwakeAssertion()
        }
    }

    func setAwakeDuration(_ duration: AwakeDuration) {
        awakeDuration = duration
        if isKeepingAwake { scheduleAwakeExpiry() }
    }

    func setVolume(_ requested: Double) {
        guard canSetVolume, outputDevice != kAudioObjectUnknown else { return }
        let value = Float32(min(max(requested, 0), 1))
        var success = true
        for element in volumeElements {
            var address = volumeAddress(element)
            var newValue = value
            let status = AudioObjectSetPropertyData(outputDevice, &address, 0, nil,
                                                    UInt32(MemoryLayout<Float32>.size), &newValue)
            if status != noErr { success = false }
        }
        if success {
            volume = Double(value)
            showVolumeFeedback("Volume \(Int((Double(value) * 100).rounded()))%")
            controlError = nil
        } else {
            controlError = "This output device did not accept the volume change."
        }
        readOutputState()
    }

    func setMuted(_ muted: Bool) {
        guard canSetMute, outputDevice != kAudioObjectUnknown else { return }
        var success = true
        for element in muteElements {
            var address = muteAddress(element)
            var value: UInt32 = muted ? 1 : 0
            let status = AudioObjectSetPropertyData(outputDevice, &address, 0, nil,
                                                    UInt32(MemoryLayout<UInt32>.size), &value)
            if status != noErr { success = false }
        }
        if success {
            isMuted = muted
            showVolumeFeedback(muted ? "Muted" : "Unmuted")
            controlError = nil
        } else {
            controlError = "This output device did not accept the mute change."
        }
        readOutputState()
    }

    private func sample() {
        switch visibleTool {
        case .stats:
            readCPU()
            readMemory()
            readNetwork()
        case .volume:
            readOutputState()
        case .keepAwake:
            break
        case nil:
            readCPU()
            readMemory()
            readNetwork()
            readOutputState()
        }
    }

    private func scheduleAwakeExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        guard awakeDuration.rawValue > 0 else {
            awakeUntil = nil
            return
        }
        let seconds = TimeInterval(awakeDuration.rawValue * 60)
        awakeUntil = Date().addingTimeInterval(seconds)
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.releaseAwakeAssertion()
        }
    }

    private func releaseAwakeAssertion() {
        expiryTask?.cancel()
        expiryTask = nil
        if assertionID != 0 {
            let status = IOPMAssertionRelease(assertionID)
            if status != kIOReturnSuccess {
                awakeMessage = "macOS could not release Keep Awake (\(status))."
                return
            }
            assertionID = 0
        }
        isKeepingAwake = false
        awakeUntil = nil
        awakeMessage = nil
    }

    private struct CPUTicks {
        let busy: UInt64
        let total: UInt64
    }

    private func readCPU() {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                         &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else {
            cpuPercent = nil
            statsMessage = "CPU information is unavailable."
            return
        }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        guard Int(infoCount) >= Int(cpuCount) * Int(CPU_STATE_MAX) else {
            cpuPercent = nil
            statsMessage = "CPU information is unavailable."
            return
        }
        var busy: UInt64 = 0
        var total: UInt64 = 0
        for cpu in 0..<Int(cpuCount) {
            let offset = cpu * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[offset + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[offset + Int(CPU_STATE_SYSTEM)]))
            let idle = UInt64(UInt32(bitPattern: info[offset + Int(CPU_STATE_IDLE)]))
            let nice = UInt64(UInt32(bitPattern: info[offset + Int(CPU_STATE_NICE)]))
            busy += user + system + nice
            total += user + system + nice + idle
        }
        let current = CPUTicks(busy: busy, total: total)
        if let previousCPU, current.total > previousCPU.total {
            let totalDelta = current.total - previousCPU.total
            let busyDelta = current.busy >= previousCPU.busy ? current.busy - previousCPU.busy : 0
            cpuPercent = min(100, Double(busyDelta) / Double(totalDelta) * 100)
        }
        previousCPU = current
        statsMessage = nil
    }

    private func readMemory() {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            memoryUsedBytes = nil
            return
        }
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else {
            memoryUsedBytes = nil
            return
        }
        let availablePages = UInt64(stats.free_count) + UInt64(stats.inactive_count)
            + UInt64(stats.speculative_count)
        let availableBytes = availablePages * UInt64(pageSize)
        memoryUsedBytes = memoryTotalBytes > availableBytes ? memoryTotalBytes - availableBytes : 0
    }

    private struct NetworkCounters {
        struct Interface {
            let received: UInt32
            let sent: UInt32
        }
        let interfaces: [String: Interface]
        let sampledAt: Date
    }

    private func readNetwork() {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else {
            downloadBytesPerSecond = nil
            uploadBytesPerSecond = nil
            return
        }
        defer { if let first { freeifaddrs(first) } }
        var interfaces: [String: NetworkCounters.Interface] = [:]
        var cursor = first
        while let current = cursor {
            let item = current.pointee
            if item.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
               (item.ifa_flags & UInt32(IFF_UP)) != 0,
               (item.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
               let data = item.ifa_data?.assumingMemoryBound(to: if_data.self) {
                let name = String(cString: item.ifa_name)
                interfaces[name] = NetworkCounters.Interface(
                    received: data.pointee.ifi_ibytes,
                    sent: data.pointee.ifi_obytes
                )
            }
            cursor = item.ifa_next
        }
        let current = NetworkCounters(interfaces: interfaces, sampledAt: Date())
        if let previousNetwork {
            let interval = current.sampledAt.timeIntervalSince(previousNetwork.sampledAt)
            if interval > 0 {
                var received: UInt64 = 0
                var sent: UInt64 = 0
                for (name, counters) in current.interfaces {
                    guard let prior = previousNetwork.interfaces[name] else { continue }
                    received += UInt64(counters.received &- prior.received)
                    sent += UInt64(counters.sent &- prior.sent)
                }
                downloadBytesPerSecond = Double(received) / interval
                uploadBytesPerSecond = Double(sent) / interval
            }
        }
        previousNetwork = current
    }

    private func installVolumeListeners() -> Bool {
        removeVolumeListeners()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.defaultOutputChanged() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
        guard status == noErr else { return false }
        defaultDeviceListener = block
        installDeviceListeners()
        return true
    }

    private func defaultOutputChanged() {
        guard showVolumeHUD else { return }
        readOutputState()
        installDeviceListeners()
    }

    private func installDeviceListeners() {
        removeDeviceListeners()
        guard outputDevice != kAudioObjectUnknown else {
            volumeHUDMessage = "Waiting for an output device that supports volume notifications."
            return
        }
        let selectors: [AudioObjectPropertySelector] = [
            kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute
        ]
        for selector in selectors {
            for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioDevicePropertyScopeOutput,
                    mElement: element
                )
                guard AudioObjectHasProperty(outputDevice, &address) else { continue }
                let device = outputDevice
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.outputVolumeChanged(on: device) }
                }
                if AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main, block) == noErr {
                    deviceListeners.append(DeviceListener(device: device, address: address, block: block))
                }
            }
        }
        volumeHUDMessage = deviceListeners.isEmpty
            ? "This output device cannot provide volume change notifications." : nil
    }

    private func outputVolumeChanged(on device: AudioDeviceID) {
        guard showVolumeHUD, device == outputDevice else { return }
        let oldVolume = volume
        let oldMute = isMuted
        readOutputState()
        guard outputDevice == device else {
            installDeviceListeners()
            return
        }
        if (hasReadableVolume && abs(volume - oldVolume) >= 0.005) || isMuted != oldMute {
            onVolumeHUD?(volume, isMuted)
        }
    }

    private func removeVolumeListeners() {
        removeDeviceListeners()
        if let defaultDeviceListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main,
                defaultDeviceListener
            )
            self.defaultDeviceListener = nil
        }
    }

    private func removeDeviceListeners() {
        for listener in deviceListeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(
                listener.device, &address, DispatchQueue.main, listener.block
            )
        }
        deviceListeners.removeAll()
    }

    private func volumeAddress(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: element)
    }

    private func muteAddress(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: element)
    }

    private func readOutputState() {
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &defaultAddress, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else {
            outputDevice = kAudioObjectUnknown
            outputDeviceName = "No output device"
            hasReadableVolume = false
            canSetVolume = false
            canSetMute = false
            volumeMessage = "Connect an audio output device to control volume."
            return
        }
        if device != outputDevice { controlError = nil }
        outputDevice = device
        outputDeviceName = deviceName(device) ?? "Current output"

        let elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]
        volumeElements = elements.filter { element in
            var address = volumeAddress(element)
            guard AudioObjectHasProperty(device, &address) else { return false }
            var writable = DarwinBoolean(false)
            return AudioObjectIsPropertySettable(device, &address, &writable) == noErr && writable.boolValue
        }
        // Use the master control when available; otherwise set the two standard
        // stereo channels together, so a slider change does not skew balance.
        if volumeElements.contains(kAudioObjectPropertyElementMain) {
            volumeElements = [kAudioObjectPropertyElementMain]
        }
        canSetVolume = !volumeElements.isEmpty
        let readElements = canSetVolume ? volumeElements : elements.filter { element in
            var address = volumeAddress(element)
            return AudioObjectHasProperty(device, &address)
        }
        let readings: [Double] = readElements.compactMap { element in
            var address = volumeAddress(element)
            var scalar: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &scalar) == noErr else {
                return nil
            }
            return Double(scalar)
        }
        hasReadableVolume = !readings.isEmpty
        if hasReadableVolume { volume = readings.reduce(0, +) / Double(readings.count) }

        muteElements = elements.filter { element in
            var address = muteAddress(element)
            guard AudioObjectHasProperty(device, &address) else { return false }
            var writable = DarwinBoolean(false)
            return AudioObjectIsPropertySettable(device, &address, &writable) == noErr && writable.boolValue
        }
        if muteElements.contains(kAudioObjectPropertyElementMain) {
            muteElements = [kAudioObjectPropertyElementMain]
        }
        canSetMute = !muteElements.isEmpty
        let readMuteElements = canSetMute ? muteElements : elements.filter { element in
            var address = muteAddress(element)
            return AudioObjectHasProperty(device, &address)
        }
        let muteReadings: [Bool] = readMuteElements.compactMap { element in
            var address = muteAddress(element)
            var muted: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr {
                return muted != 0
            }
            return nil
        }
        if !muteReadings.isEmpty { isMuted = muteReadings.allSatisfy { $0 } }
        if !canSetVolume && !canSetMute {
            volumeMessage = "This output device manages its own volume and mute."
        } else if !canSetVolume {
            volumeMessage = "This output device manages its own volume."
        } else if !canSetMute {
            volumeMessage = "Mute is unavailable for this output device."
        } else {
            volumeMessage = nil
        }
        if let controlError { volumeMessage = controlError }
    }

    private func deviceName(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let name else {
            return nil
        }
        // kAudioObjectPropertyName returns a retained CFString to the caller.
        return name.takeRetainedValue() as String
    }

    private func showVolumeFeedback(_ message: String) {
        volumeFeedback = message
        feedbackTask?.cancel()
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.volumeFeedback = nil
        }
    }
}

struct SystemToolsView: View {
    let tool: SystemTool
    let store: SystemToolsStore

    private let accent = Color(red: 0.52, green: 0.69, blue: 0.91)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(accent)
                    .frame(width: 34, height: 34)
                    .background(accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
                Text(tool.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
            }
            switch tool {
            case .stats: statsContent
            case .keepAwake: awakeContent
            case .volume: volumeContent
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.105, green: 0.111, blue: 0.124))
        .preferredColorScheme(.dark)
        .onAppear { store.setVisible(true, tool: tool) }
        .onDisappear { store.setVisible(false, tool: tool) }
    }

    private var statsContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            metric("CPU", value: store.cpuPercent.map { "\(Int($0.rounded()))%" } ?? "Measuring…",
                   symbol: "cpu")
            metric("Memory", value: memoryLabel, symbol: "memorychip")
            metric("Download", value: rateLabel(store.downloadBytesPerSecond), symbol: "arrow.down")
            metric("Upload", value: rateLabel(store.uploadBytesPerSecond), symbol: "arrow.up")
            if let message = store.statsMessage {
                footnote(message)
            } else {
                footnote("Live activity across active network interfaces")
            }
        }
    }

    private var memoryLabel: String {
        guard let used = store.memoryUsedBytes else { return "Unavailable" }
        return "\(bytes(used)) / \(bytes(store.memoryTotalBytes))"
    }

    private func rateLabel(_ value: Double?) -> String {
        guard let value else { return "Measuring…" }
        return "\(bytes(UInt64(max(0, value))))/s"
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .binary)
    }

    private var awakeContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Prevent idle sleep while a task is running. Your display may still dim.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.65))

            HStack {
                Text("Duration")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                Spacer()
                Picker("Duration", selection: Binding(
                    get: { store.awakeDuration },
                    set: { store.setAwakeDuration($0) }
                )) {
                    ForEach(SystemToolsStore.AwakeDuration.allCases) { duration in
                        Text(duration.label).tag(duration)
                    }
                }
                .labelsHidden()
                .frame(width: 165)
            }
            .padding(11)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))

            Button {
                store.setKeepingAwake(!store.isKeepingAwake)
            } label: {
                Label(store.isKeepingAwake ? "Turn off Keep Awake" : "Start Keep Awake",
                      systemImage: store.isKeepingAwake ? "power" : "sun.max.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .foregroundStyle(.white)
                    .background(store.isKeepingAwake ? .white.opacity(0.10) : accent.opacity(0.65),
                                in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            if store.isKeepingAwake {
                footnote(store.awakeUntil.map { "Active until \($0.formatted(date: .omitted, time: .shortened))" }
                         ?? "Active until you turn it off")
            } else {
                footnote(store.awakeMessage ?? "Off · Your Mac follows its normal sleep settings")
            }
        }
    }

    private var volumeContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "hifispeaker")
                    .foregroundStyle(accent)
                Text(store.outputDeviceName)
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text(store.hasReadableVolume ? "\(Int((store.volume * 100).rounded()))%" : "Unavailable")
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            .font(.system(size: 12, weight: .medium))

            Slider(value: Binding(get: { store.volume }, set: { store.setVolume($0) }), in: 0...1)
                .tint(accent)
                .disabled(!store.canSetVolume)
                .accessibilityLabel("Output volume")
                .accessibilityValue("\(Int((store.volume * 100).rounded())) percent")

            Button {
                store.setMuted(!store.isMuted)
            } label: {
                Label(store.isMuted ? "Unmute" : "Mute",
                      systemImage: store.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 31)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(!store.canSetMute)

            Toggle("Show volume changes near the notch", isOn: Binding(
                get: { store.showVolumeHUD }, set: { store.setShowVolumeHUD($0) }
            ))
            .toggleStyle(.switch)
            .font(.caption)
            if let message = store.volumeHUDMessage { footnote(message) }

            if let feedback = store.volumeFeedback {
                footnote(feedback)
            } else if let message = store.volumeMessage {
                footnote(message)
            } else {
                footnote("Changes apply to the current output device")
            }
        }
    }

    private func metric(_ title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(accent)
                .frame(width: 18)
            Text(title)
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            Text(value)
                .foregroundStyle(.white)
                .monospacedDigit()
        }
        .font(.system(size: 12, weight: .medium))
        .padding(11)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.49))
            .fixedSize(horizontal: false, vertical: true)
    }
}
