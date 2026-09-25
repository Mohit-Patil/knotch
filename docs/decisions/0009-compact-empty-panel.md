# Compact empty and Settings panels

The owner showed an empty 1280×720 panel on an external display. It covered a large portion of the desktop while offering only two actions and a Settings tab. The Open Project button also looked disabled in the nonactivating hover preview because SwiftUI's prominent button style dims when its app is inactive.

With no shell, Knotch now opens a 600×240-point panel. Selecting Settings uses 640×320 points so its controls fit. A terminal session still uses the responsive 960–1280 by 520–720-point panel. The compact sizes are clamped to the active display's usable frame by the same `DisplayGeometry` path; the top edge and camera-safe placement remain unchanged. Open Project and Home Shell use fixed-contrast fills and labels, so their appearance does not depend on key-window status.

Model tests cover the external display's exact compact frames. The focused native fixture checks empty, Settings and terminal geometry, real Ghostty session continuity, and dialog-level restoration. Release/test builds passed. After installing and restarting with no live shell, manual UI inspection showed the compact empty panel and fitted Settings panel. The inactive hover-preview colors were not captured with computer control; the fixed colors are verified in source and active UI only. Dynamic size changes when closing the last shell were not frame-timing measured.
