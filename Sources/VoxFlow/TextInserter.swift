import AppKit
import CoreGraphics

/// Inserts text into the focused app: saves the pasteboard, writes the transcript,
/// synthesizes Cmd-V, and restores the previous pasteboard 0.5 s later (SPEC R8).
final class TextInserter {
    private var pendingRestore: DispatchWorkItem?

    func insert(_ text: String) {
        let pasteboard = NSPasteboard.general

        // A restore still pending from a rapid previous dictation would clobber
        // the new transcript before the paste target reads it — cancel it.
        pendingRestore?.cancel()
        pendingRestore = nil

        // Snapshot every item/type so clipboard managers and images survive.
        let saved: [NSPasteboardItem] = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Give the pasteboard a beat to settle before the paste keystroke.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.postCmdV()
            let restore = DispatchWorkItem {
                pasteboard.clearContents()
                if !saved.isEmpty {
                    pasteboard.writeObjects(saved)
                }
            }
            self?.pendingRestore = restore
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: restore)
        }
    }

    private func postCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKeyCode: CGKeyCode = 9
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
