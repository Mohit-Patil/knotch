import CoreGraphics

/// All frames and sizes are in AppKit points. The controller supplies current
/// NSScreen values; this service does not choose or cache a screen.
struct DisplayGeometry {
    var screenFrame: CGRect
    var visibleFrame: CGRect
    var safeAreaTop: CGFloat
    var auxiliaryTopLeft: CGRect?
    var auxiliaryTopRight: CGRect?
    var backingScale: CGFloat

    var preferredPanelSize = CGSize(width: 960, height: 520)
    var triggerSize = CGSize(width: 160, height: 28)
    var panelGap: CGFloat = 6

    func layout() -> OverlayLayout {
        let clippedVisible = screenFrame.intersection(visibleFrame)
        let usable = clippedVisible.isNull || clippedVisible.isEmpty ? screenFrame : clippedVisible
        let topBelowSafeArea = screenFrame.maxY - max(0, safeAreaTop)
        let top = clamp(topBelowSafeArea, min: usable.minY + 1, max: usable.maxY)
        let triggerWidth = min(max(1, triggerSize.width), max(1, usable.width))
        let triggerHeight = min(max(1, triggerSize.height), max(1, top - usable.minY))

        // The gap between the public auxiliary areas identifies the excluded
        // camera region. Keep the trigger centered on that gap when available.
        let notchCenter: CGFloat? = {
            guard let left = auxiliaryTopLeft, let right = auxiliaryTopRight,
                  left.maxX < right.minX else { return nil }
            return (left.maxX + right.minX) / 2
        }()
        let centerX = notchCenter ?? screenFrame.midX
        let triggerX = clamp(centerX - triggerWidth / 2,
                             min: usable.minX, max: usable.maxX - triggerWidth)
        let trigger = CGRect(x: triggerX, y: top - triggerHeight,
                             width: triggerWidth, height: triggerHeight)

        let availablePanelHeight = max(0, trigger.minY - max(0, panelGap) - usable.minY)
        let panelWidth = min(max(1, preferredPanelSize.width), max(1, usable.width))
        // When there is no room beneath the trigger, keep a positive frame in
        // the visible area. The controller can choose compact UI at that size.
        let panelHeight = min(max(1, preferredPanelSize.height),
                              max(1, availablePanelHeight), max(1, usable.height))
        let panelX = clamp(centerX - panelWidth / 2,
                           min: usable.minX, max: usable.maxX - panelWidth)
        let panelY = clamp(trigger.minY - max(0, panelGap) - panelHeight,
                           min: usable.minY, max: usable.maxY - panelHeight)
        let panel = CGRect(x: panelX, y: panelY,
                           width: panelWidth, height: panelHeight)
        return OverlayLayout(triggerFrame: trigger, panelFrame: panel,
                             usableFrame: usable, backingScale: max(1, backingScale))
    }

    private func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, lower), upper)
    }
}

struct OverlayLayout {
    var triggerFrame: CGRect
    var panelFrame: CGRect
    var usableFrame: CGRect
    var backingScale: CGFloat

    /// Convert a point size to backing pixels only at the native-view boundary.
    func backingPixels(for size: CGSize) -> CGSize {
        CGSize(width: (size.width * backingScale).rounded(),
               height: (size.height * backingScale).rounded())
    }
}
