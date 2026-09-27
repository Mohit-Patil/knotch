#if HARNESS_TESTS
import AppKit
import Darwin
import GhosttyKit
import ImageIO

/// Bounded, repeatable real-engine stress test. Uses no user clipboard, SSH host,
/// or defaults. Memory snapshots are physical footprint, not virtual size.
@MainActor
enum PerformanceQualification {
    final class WeakSession {
        weak var value: GhosttySession?
        init(_ value: GhosttySession) { self.value = value }
    }
    static var records: [[String: Any]] = []
    static var checks: [[String: Any]] = []
    static let output = ProcessInfo.processInfo.environment["KNOTCH_EVIDENCE"] ?? "/tmp/knotch-stress.json"

    static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1048576 : -1
    }
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    static func record(_ name: String, seconds: Double = 2) async {
        let start = ProcessInfo.processInfo.systemUptime
        let cpu = cpuSeconds()
        var gaps: [Double] = []
        var peak = footprint()
        while ProcessInfo.processInfo.systemUptime - start < seconds {
            let before = ProcessInfo.processInfo.systemUptime
            try? await Task.sleep(for: .milliseconds(50))
            gaps.append(max(0, (ProcessInfo.processInfo.systemUptime - before - 0.05) * 1000))
            peak = max(peak, footprint())
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        gaps.sort()
        let row: [String: Any] = ["phase": name, "seconds": elapsed, "footprint_mib": footprint(),
                                 "peak_mib": peak, "cpu_percent_one_core": (cpuSeconds() - cpu) / elapsed * 100,
                                 "main_delay_p95_ms": gaps[min(gaps.count - 1, Int(Double(gaps.count) * 0.95))],
                                 "main_delay_max_ms": gaps.last ?? 0]
        records.append(row)
        print("STRESS \(name): \(row)")
        fflush(nil)
        writeReport()
    }
    static func check(_ name: String, _ value: Bool) {
        checks.append(["test": name, "passed": value])
        print("STRESS CHECK \(name): \(value)")
        fflush(nil)
    }
    static func writeReport() {
        let report: [String: Any] = ["records": records, "checks": checks]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }

    static func run(coordinator: AppCoordinator) async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("knotch-stress-\(UUID())")
        let board = NSPasteboard.withUniqueName()
        let leakBaseline = ProcessInfo.processInfo.environment["KNOTCH_STRESS_LEAK_BASELINE"] == "1"
        let outputOnly = ProcessInfo.processInfo.environment["KNOTCH_STRESS_OUTPUT_ONLY"] == "1"
        var weakSessions: [WeakSession] = []
        var childPIDs: Set<pid_t> = []
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let runtime = coordinator.runtime else { throw TerminalFailure.unavailable("Missing engine") }
            let history = ClipboardHistory(pasteboard: board, storageURL: folder.appendingPathComponent("history.json"))
            await history.waitUntilSettled()
            coordinator.useClipboardForFixture(history)
            coordinator.window?.title = "Knotch · Isolated performance test"
            coordinator.window?.makeKeyAndOrderFront(nil)
            let burst = folder.appendingPathComponent("burst.zsh")
            try """
            /usr/bin/awk 'BEGIN { for (i=0;i<2000;i++) printf "STRESS %06d abcdefghijklmnopqrstuvwxyz 0123456789 abcdefghijklmnopqrstuvwxyz\\n", i }'
            printf '\\nSTRESS_READY\\n'
            exec /bin/sleep 600
            """.write(to: burst, atomically: true, encoding: .utf8)
            let sustained = folder.appendingPathComponent("sustained.zsh")
            try """
            for n in {1..30}; do
              /usr/bin/awk 'BEGIN { for (i=0;i<2000;i++) printf "OUTPUT %06d abcdefghijklmnopqrstuvwxyz 0123456789 abcdefghijklmnopqrstuvwxyz\\n", i }'
              /bin/sleep 1
            done
            printf '\\nSTRESS_READY\\n'
            exec /bin/sleep 600
            """.write(to: sustained, atomically: true, encoding: .utf8)

            func openBatch(_ script: URL, count: Int) throws {
                for _ in 0..<count {
                    let session = try GhosttySession(runtime: runtime, directory: folder,
                        testCommand: "/bin/zsh -f " + SSHConnection.quote(script.path))
                    coordinator.store.adoptFixture(session)
                    coordinator.attach(session)
                    weakSessions.append(WeakSession(session))
                }
            }
            func closeBatch() {
                coordinator.window?.makeFirstResponder(nil)
                for item in coordinator.store.sessions {
                    if let session = item as? GhosttySession, let surface = session.surface {
                        let pid = ghostty_surface_foreground_pid(surface)
                        if pid > 0, pid <= UInt64(Int32.max) { childPIDs.insert(pid_t(pid)) }
                    }
                    item.setPresented(false)
                    item.view.removeFromSuperview()
                }
                coordinator.store.closeAllAfterConfirmation()
            }
            // Warm font/renderer/system caches before judging repeated-cycle growth.
            try openBatch(burst, count: 2)
            try await HarnessQualification.waitFor({ coordinator.store.sessions.allSatisfy {
                ($0 as? GhosttySession).map { HarnessQualification.screen($0).contains("STRESS_READY") } ?? false
            } }, timeout: 20)
            closeBatch()
            await record("warmed_idle", seconds: 15)
            if !leakBaseline {
                for cycleIndex in 0..<(outputOnly ? 0 : 10) {
                    let cycle = cycleIndex + 1
                    try openBatch(burst, count: 8)
                    try await HarnessQualification.waitFor({ coordinator.store.sessions.allSatisfy {
                        ($0 as? GhosttySession).map { HarnessQualification.screen($0).contains("STRESS_READY") } ?? false
                    } }, timeout: 25)
                    await record("cycle_\(cycle)_eight_tabs", seconds: 1)
                    closeBatch()
                    await record("cycle_\(cycle)_closed", seconds: 3)
                    check("Cycle \(cycle) session objects released", weakSessions.allSatisfy { $0.value == nil })
                }
                try openBatch(sustained, count: 8)
                await record("eight_tabs_sustained_output", seconds: 35)
                check("All output generators finished", coordinator.store.sessions.allSatisfy {
                    ($0 as? GhosttySession).map { HarnessQualification.screen($0).contains("STRESS_READY") } ?? false
                })
                coordinator.hideTerminal()
                await record("eight_tabs_hidden_idle", seconds: 15)
                closeBatch()
                await record("post_output_closed", seconds: 15)
                check("All terminal objects released", weakSessions.allSatisfy { $0.value == nil })
                check("All sampled child processes exited", childPIDs.allSatisfy { kill($0, 0) != 0 && errno == ESRCH })

                if !outputOnly {
                    // Fifty 3000x2000 sources exercise decoded-image pressure without
                    // allocating all originals at once. Every payload is synthetic.
                    for index in 0..<50 {
                        let data = await Task.detached(priority: .utility) {
                            autoreleasepool { imageData(seed: index) }
                        }.value
                        _ = history.addDropped(ClipboardEntry(kind: .image, data: data, imageType: "public.png"))
                        await history.waitUntilSettled()
                    }
                    check("50 images stored without inline binary payloads", history.entries.count == 50 && history.entries.allSatisfy { $0.data == nil })
                    coordinator.showClipboard()
                    coordinator.window?.makeKeyAndOrderFront(nil)
                    NSApp.activate()
                    await record("image_library_initial", seconds: 5)
                    // Ready marker lets computer-use exercise real scrolling and dragging.
                    try Data("ready".utf8).write(to: URL(fileURLWithPath: output + ".ui-ready"))
                    print("STRESS UI_READY: 50 synthetic images; 90 second browsing window")
                    fflush(nil)
                    await record("image_library_interactive", seconds: 90)
                    // Revisit every source repeatedly through the same thumbnail pipeline.
                    for pass in 1...3 {
                        for entry in history.entries {
                            let image = await ClipboardThumbnails.shared.image(for: entry)
                            if image == nil || max(image!.width, image!.height) > 420 {
                                check("Bounded thumbnail decode", false)
                            }
                        }
                        await record("thumbnail_pass_\(pass)", seconds: 3)
                    }
                    history.clearAll()
                    await history.waitUntilSettled()
                    await ClipboardThumbnails.shared.clear()
                    await record("clipboard_cleared", seconds: 10)
                }
            }
            coordinator.hideTerminal()
            await record("final_idle", seconds: leakBaseline ? 45 : (outputOnly ? 30 : 60))
            check("All history removed", history.entries.isEmpty)
            check("No retained closed sessions", weakSessions.allSatisfy { $0.value == nil })
        } catch {
            checks.append(["test": "Fixture completion", "passed": false, "error": error.localizedDescription])
        }
        writeReport()
        board.releaseGlobally()
        coordinator.store.closeAllAfterConfirmation()
        coordinator.runtime?.shutdown()
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(atPath: output + ".ui-ready")
        exit(checks.contains { $0["passed"] as? Bool == false } ? 1 : 0)
    }

    nonisolated static func imageData(seed: Int) -> Data {
        let context = CGContext(data: nil, width: 3000, height: 2000, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: CGFloat(seed % 11) / 11, green: 0.12, blue: 0.25, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
        for tile in 0..<400 {
            context.setFillColor(CGColor(red: CGFloat((tile + seed) % 17) / 17,
                                         green: CGFloat((tile * 3 + seed) % 23) / 23,
                                         blue: CGFloat((tile * 7 + seed) % 29) / 29, alpha: 1))
            context.fill(CGRect(x: (tile % 20) * 150, y: (tile / 20) * 100, width: 135, height: 85))
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
#endif
