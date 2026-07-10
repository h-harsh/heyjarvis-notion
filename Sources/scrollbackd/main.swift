import Foundation
import ScrollbackCore

// scrollbackd — the capture + index daemon.
//
// This is a versioned skeleton. The event-driven Accessibility-tree capture loop
// (AX notifications + app-switch + typing-pause triggers) lands in the next M1
// increment. By design this target links NO networking: all egress flows through
// scrollback-courier. See CLAUDE.md (Architecture) and docs/decisions.md.

print("scrollbackd \(scrollbackCoreVersion) — capture daemon (skeleton; capture loop pending)")
