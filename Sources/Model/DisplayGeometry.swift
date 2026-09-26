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

    var preferredPanelSize = CGSize(width: 720, height: 550)
    var userPanelSize: CGSize?
    var triggerSize = CGSize(width: 160, height: 28)
    var panelGap: CGFloat = 0

    func layout() -> OverlayLayout {
        let clippedVisible = screenFrame.intersection(visibleFrame)
        let usable = clippedVisible.isNull || clippedVisible.isEmpty ? screenFrame : clippedVisible
        if let notch = validNotchFrame() {
            return notchedLayout(notch: notch, usable: usable)
        }

        // A plain display has no hardware island. Keep its handle in the
        // measured menu-bar band instead of floating over application content.
        // The expanded window reaches the same screen edge, while its body
        // still obeys the visible frame's dock and horizontal insets.
        let menuBarHeight = max(0, screenFrame.maxY - usable.maxY)
        let handleHeight = menuBarHeight > 0 ? min(triggerSize.height, menuBarHeight) : triggerSize.height
        let triggerWidth = min(max(1, triggerSize.width), max(1, usable.width))
        let triggerHeight = min(max(1, handleHeight), max(1, screenFrame.height))
        let centerX = screenFrame.midX
        let triggerX = clamp(centerX - triggerWidth / 2,
                             min: usable.minX, max: usable.maxX - triggerWidth)
        let trigger = CGRect(x: triggerX, y: screenFrame.maxY - triggerHeight,
                             width: triggerWidth, height: triggerHeight)

        let panelUsable = CGRect(x: usable.minX, y: usable.minY,
                                 width: usable.width, height: screenFrame.maxY - usable.minY)
        let panel = panelFrame(centerX: centerX,
                               top: screenFrame.maxY - max(0, panelGap), usable: panelUsable)
        return OverlayLayout(triggerFrame: trigger, panelFrame: panel,
                             usableFrame: panelUsable, notchFrame: nil,
                             backingScale: max(1, backingScale))
    }

    private func notchedLayout(notch: CGRect, usable: CGRect) -> OverlayLayout {
        // The expanded window includes the menu-bar band. Its header occupies
        // the wings beside the cutout instead of adding a second row below it.
        let panelUsable = CGRect(x: usable.minX, y: usable.minY,
                                 width: usable.width, height: screenFrame.maxY - usable.minY)
        let panelTop = screenFrame.maxY
        // Invisible margins make the camera target reachable from adjacent
        // screen pixels. The notched trigger itself paints no cap or lip.
        let lip: CGFloat = 2
        let wing: CGFloat = 8
        let triggerX = clamp(notch.minX - wing,
                             min: screenFrame.minX, max: screenFrame.maxX - min(screenFrame.width, notch.width + 2 * wing))
        let triggerWidth = min(screenFrame.width, notch.width + 2 * wing)
        let triggerBottom = max(screenFrame.minY, notch.minY - lip)
        let trigger = CGRect(x: triggerX, y: triggerBottom,
                             width: triggerWidth, height: screenFrame.maxY - triggerBottom)
        let panel = panelFrame(centerX: notch.midX, top: panelTop, usable: panelUsable)
        return OverlayLayout(triggerFrame: trigger, panelFrame: panel,
                             usableFrame: panelUsable, notchFrame: notch,
                             backingScale: max(1, backingScale))
    }

    private func panelFrame(centerX: CGFloat, top: CGFloat, usable: CGRect) -> CGRect {
        let availablePanelHeight = max(0, top - usable.minY)
        // Every in-panel tab shares one size. User resizing applies to the
        // whole workspace, while small displays still clamp it to fit.
        let desiredWidth = userPanelSize?.width ?? preferredPanelSize.width
        let desiredHeight = userPanelSize?.height ?? preferredPanelSize.height
        let panelWidth = min(max(1, desiredWidth), max(1, usable.width))
        let panelHeight = min(max(1, desiredHeight),
                              max(1, availablePanelHeight), max(1, usable.height))
        let panelX = clamp(centerX - panelWidth / 2,
                           min: usable.minX, max: usable.maxX - panelWidth)
        let panelY = clamp(top - panelHeight,
                           min: usable.minY, max: usable.maxY - panelHeight)
        return CGRect(x: panelX, y: panelY,
                      width: panelWidth, height: panelHeight)
    }

    private func validNotchFrame() -> CGRect? {
        guard let left = auxiliaryTopLeft, let right = auxiliaryTopRight,
              left.width > 0, right.width > 0, left.height > 0, right.height > 0,
              left.maxX < right.minX,
              left.minX >= screenFrame.minX - 1,
              right.maxX <= screenFrame.maxX + 1,
              abs(left.maxY - screenFrame.maxY) <= 1,
              abs(right.maxY - screenFrame.maxY) <= 1,
              abs(left.minY - right.minY) <= 1,
              left.minY > screenFrame.minY else { return nil }
        let bottom = min(left.minY, right.minY)
        return CGRect(x: left.maxX, y: bottom,
                      width: right.minX - left.maxX,
                      height: screenFrame.maxY - bottom)
    }

    private func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, lower), upper)
    }
}

struct OverlayLayout {
    var triggerFrame: CGRect
    var panelFrame: CGRect
    var usableFrame: CGRect
    /// Physical camera exclusion derived from auxiliary areas; nil on plain displays.
    var notchFrame: CGRect?
    var backingScale: CGFloat

    /// Convert a point size to backing pixels only at the native-view boundary.
    func backingPixels(for size: CGSize) -> CGSize {
        CGSize(width: (size.width * backingScale).rounded(),
               height: (size.height * backingScale).rounded())
    }
}

/// The top stays attached to the display. Only the lower edge and its two
/// corners are drag targets; horizontal dragging from the bottom edge is inert.
enum PanelResizeHandle {
    case bottom
    case lowerLeft
    case lowerRight

    func size(from initial: CGSize, movement: CGPoint, usable: CGSize) -> CGSize {
        let horizontal: CGFloat
        switch self {
        case .bottom: horizontal = 0
        case .lowerLeft: horizontal = -2 * movement.x
        case .lowerRight: horizontal = 2 * movement.x
        }
        let minimumWidth = min(520, usable.width)
        let minimumHeight = min(280, usable.height)
        return CGSize(width: min(usable.width, max(minimumWidth, initial.width + horizontal)),
                      height: min(usable.height, max(minimumHeight, initial.height - movement.y)))
    }
}
