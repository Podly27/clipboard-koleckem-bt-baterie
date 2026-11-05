import Cocoa
import Carbon

final class KeyboardSwitch {
    var tap: CFMachPort?
    var armed = false
    var leftShift = false
    var usedKey = false
    var modifiersActive = false
    var lastSwitch = Date.distantPast
    var enabled = UserDefaults.standard.object(forKey: "layoutShortcut") as? Bool ?? true
    func start() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue) | (CGEventMask(1) << CGEventType.keyDown.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, info in
            let owner = Unmanaged<KeyboardSwitch>.fromOpaque(info!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else { owner.handle(type, event) }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap {
            CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
    func handle(_ type: CGEventType, _ event: CGEvent) {
        guard enabled else { armed = false; leftShift = false; return }
        if type == .keyDown {
            // Plain typing must not cancel the next modifier-only gesture.
            if modifiersActive { usedKey = true; armed = false }
            return
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        // Use the left-Shift device bit from this event, not a later global
        // keyboard snapshot which may already reflect the next release.
        if key == 56 { leftShift = event.flags.rawValue & 0x2 != 0 }
        let flags = event.flags
        let modifier = flags.contains(.maskAlternate) || flags.contains(.maskCommand)
        let allReleased = !flags.contains(.maskShift) && !modifier && !flags.contains(.maskControl)
        if !modifiersActive && !allReleased { usedKey = false; armed = false }
        modifiersActive = !allReleased
        if allReleased {
            let shouldSwitch = armed && !usedKey && Date().timeIntervalSince(lastSwitch) > 0.35
            armed = false; usedKey = false; leftShift = false
            if shouldSwitch {
                lastSwitch = Date()
                DispatchQueue.main.async { self.switchLayout() }
            }
        } else if leftShift && modifier && !flags.contains(.maskControl) && !usedKey {
            armed = true
        }
    }

    func switchLayout() {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource],
              let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
        func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
            guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
            return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
        }
        func identifier(_ source: TISInputSource) -> String {
            property(source, kTISPropertyInputSourceID) as? String ?? ""
        }
        // Use the actual layout IDs: US International can advertise a
        // language other than English, so language matching is insufficient.
        let czechID = "com.apple.keylayout.Czech"
        let englishID = "com.apple.keylayout.USInternational-PC"
        let currentID = identifier(current)
        let targetID = currentID == czechID ? englishID : czechID
        if let next = list.first(where: { identifier($0) == targetID }) {
            TISSelectInputSource(next)
        }
    }

    func toggle() {
        enabled.toggle(); armed = false; usedKey = false; modifiersActive = false; leftShift = false
        UserDefaults.standard.set(enabled, forKey: "layoutShortcut")
    }
}
