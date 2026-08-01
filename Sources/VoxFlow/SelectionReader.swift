import AppKit
import CoreGraphics

/// Reads the text the user has selected in ANY app, two ways:
///  1. Global hotkey ⌃⌥R (Control-Option-R) — captured by a CGEventTap using
///     the Accessibility permission VoxFlow already has.
///  2. Right-click the selection → Services → "Read Aloud with VoxFlow"
///     (registered via NSServices in Info.plist; macOS puts Services at the
///     bottom of the context menu, and users can even assign their own
///     keyboard shortcut to it in System Settings → Keyboard → Shortcuts).
///
/// The selection is captured by saving the pasteboard, synthesizing ⌘C,
/// reading the copied string, and restoring the pasteboard afterwards.
final class SelectionReader: NSObject {
    /// Called with the selected text (main queue). The receiver decides
    /// whether to speak it or, if already speaking, to stop instead.
    var onText: ((String) -> Void)?
    /// Return false to ignore triggers (feature toggled off).
    var isEnabled: (() -> Bool)?
    /// If true is returned, the trigger only stops current speech.
    var stopIfSpeaking: (() -> Bool)?
    /// ⌃⌥S — capture a screen region and OCR-read it (works where text
    /// can't be selected: browsers, images, videos, locked PDFs).
    var onScreenArea: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private static let rKeyCode: Int64 = 15
    private static let sKeyCode: Int64 = 1

    // MARK: - Global hotkey (⌃⌥R)

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap, // active: we swallow ⌃⌥R so the front app never sees it
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let reader = Unmanaged<SelectionReader>.fromOpaque(refcon).takeUnretainedValue()
                return reader.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            return false
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        guard
            keyCode == SelectionReader.rKeyCode || keyCode == SelectionReader.sKeyCode,
            flags.contains(.maskControl),
            flags.contains(.maskAlternate),
            !flags.contains(.maskCommand)
        else {
            return Unmanaged.passUnretained(event)
        }
        if keyCode == SelectionReader.sKeyCode {
            DispatchQueue.main.async { [weak self] in
                guard self?.isEnabled?() ?? true else { return }
                if self?.stopIfSpeaking?() ?? false { return }
                self?.onScreenArea?()
            }
        } else {
            DispatchQueue.main.async { [weak self] in self?.triggered() }
        }
        return nil // consume the keystroke
    }

    private func triggered() {
        guard isEnabled?() ?? true else { return }
        if stopIfSpeaking?() ?? false { return }
        captureSelection { [weak self] text in
            guard let text = text, !text.isEmpty else { return }
            self?.onText?(text)
        }
    }

    /// Save pasteboard → synthesize ⌘C → read → restore.
    private func captureSelection(_ completion: @escaping (String?) -> Void) {
        let pasteboard = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
        let changeCount = pasteboard.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        let cKeyCode: CGKeyCode = 8
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: false)
        else {
            completion(nil)
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let copied = pasteboard.changeCount != changeCount
                ? pasteboard.string(forType: .string)
                : nil
            pasteboard.clearContents()
            if !saved.isEmpty {
                pasteboard.writeObjects(saved)
            }
            completion(copied)
        }
    }

    // MARK: - macOS Service ("Read Aloud with VoxFlow" in the context menu)

    @objc func readAloudService(_ pboard: NSPasteboard, userData: String?,
                                error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard isEnabled?() ?? true else { return }
        guard let text = pboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            if self?.stopIfSpeaking?() ?? false { return }
            self?.onText?(text)
        }
    }
}
