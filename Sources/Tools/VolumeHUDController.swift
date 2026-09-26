import AppKit
import SwiftUI

/// A non-interactive readout. It never activates Knotch or reveals the workspace.
@MainActor
final class VolumeHUDController {
    private final class HUDPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?

    func show(volume: Double, muted: Bool, screen: NSScreen) {
        guard volume.isFinite else { return }
        dismissal?.cancel()
        let window: NSPanel
        if let panel { window = panel }
        else {
            window = HUDPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.level = .statusBar
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel = window
        }
        window.contentView = NSHostingView(rootView: VolumeReadout(volume: min(1, max(0, volume)), muted: muted))
        let size = CGSize(width: 188, height: 46)
        let topInset = max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
        window.setFrame(NSRect(x: screen.frame.midX - size.width / 2,
                               y: screen.frame.maxY - topInset - size.height - 6,
                               width: size.width, height: size.height), display: true)
        window.alphaValue = 1
        window.orderFrontRegardless()
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1300))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        dismissal?.cancel()
        dismissal = nil
        panel?.orderOut(nil)
    }
    func shutdown() { hide(); panel = nil }
}

private struct VolumeReadout: View {
    let volume: Double
    let muted: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: muted || volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .frame(width: 22)
            ProgressView(value: muted ? 0 : volume).tint(.white)
            Text(muted ? "Mute" : "\(Int((volume * 100).rounded()))%")
                .monospacedDigit().frame(width: 34)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black, in: RoundedRectangle(cornerRadius: 15))
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(muted ? "Muted" : "Volume \(Int((volume * 100).rounded())) percent")
    }
}
