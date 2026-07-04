import AppKit

/// Maps the frontmost application to a cleanup category (SPEC R12).
/// The category is captured at hotkey-press time — where the user started dictating.
enum ContextDetector {
    static func currentCategory() -> AppCategory {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return .general
        }
        return Settings.categoryMap[bundleID] ?? .general
    }
}
