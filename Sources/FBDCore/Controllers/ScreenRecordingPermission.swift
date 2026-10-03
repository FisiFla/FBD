import CoreGraphics
import Foundation

/// The screen-recording permission gate for every capture path (the XDR
/// software boost, the full-screen filters, PiP and local streaming).
///
/// **Why this exists rather than a bare preflight check.** `CGPreflightScreenCaptureAccess()`
/// only *queries* the permission; it never prompts. An app that checks and
/// gives up can therefore never be granted access through normal use — it never
/// appears in System Settings → Privacy & Security → Screen Recording, so the
/// only way in is for the user to add it by hand, guessing at the binary path.
/// `CGRequestScreenCaptureAccess()` is the call that shows the system prompt and
/// registers the app in that list.
///
/// So: preflight, and if that fails, ask. macOS shows the prompt at most once
/// per app, so repeated capture attempts do not nag.
///
/// Callers must be on the main thread — the request blocks until the user
/// answers the dialog.
enum ScreenRecordingPermission {
    /// True when capture is already permitted; otherwise raises the system
    /// prompt once and reports whatever the user decided.
    ///
    /// A fresh grant may not take effect for this process until it is
    /// relaunched, which is a macOS rule and not something this can work
    /// around — the caller's failure path should say so.
    static func ensure() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }
}
