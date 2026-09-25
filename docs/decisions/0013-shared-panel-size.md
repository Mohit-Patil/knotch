# One panel size across all tabs

The owner requested Terminal and the other tabs to match Settings in size. The default expanded panel is now 720×550 points for Terminal, Clipboard, Settings, and the no-session state. The selected display's usable frame still clamps the panel when necessary, and the top remains aligned with the notch or screen edge. Switching tabs no longer changes panel geometry.

The existing bottom-edge and lower-corner resize controls remain on terminal surfaces. Their saved size, and the width/height controls in Settings, now set the panel size for every tab. Reset returns the shared default. The Ghostty surface and PTY grid resize in place when the size changes; tab selection does not recreate a session.
