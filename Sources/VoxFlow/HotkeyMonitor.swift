import AppKit
import CoreGraphics

/// Watches modifier-key events system-wide via a listen-only CGEventTap.
/// Requires Accessibility permission (checked by AppDelegate).
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isDown = false

    /// Returns false if the tap could not be created (usually missing Accessibility permission).
    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if let refcon = refcon {
                    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                    monitor.handle(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
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
        isDown = false
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // macOS disables taps that stall or when secure input starts; re-enable.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }
        guard type == .flagsChanged else { return }

        let hotkey = Settings.shared.hotkey
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == hotkey.keyCode else { return }

        // Use the device-specific bit for sided modifiers so holding the LEFT
        // twin key can't keep the hotkey stuck "pressed" (see SPEC edge cases).
        let pressed: Bool
        if let bit = hotkey.deviceFlagBit {
            pressed = (event.flags.rawValue & bit) != 0
        } else {
            pressed = event.flags.contains(hotkey.flag)
        }
        if pressed && !isDown {
            isDown = true
            DispatchQueue.main.async { [weak self] in self?.onPress?() }
        } else if !pressed && isDown {
            isDown = false
            DispatchQueue.main.async { [weak self] in self?.onRelease?() }
        }
    }
}
