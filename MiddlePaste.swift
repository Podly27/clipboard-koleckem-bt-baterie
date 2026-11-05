import Cocoa
import ApplicationServices

final class MiddlePaste: NSObject {
    var status: String { tr("Zpřístupnění", "Accessibility") + ": " + (AXIsProcessTrusted() ? tr("ano", "yes") : tr("ne", "no")) + ", " + tr("kolečko", "middle click") + ": " + (tap == nil ? tr("neaktivní", "inactive") : tr("aktivní", "active")) }
    var history: [String] = []
    var hold: DispatchWorkItem?
    var holdPoint: CGPoint?
    var historyMenu: NSMenu?
    var clipboardChange = -1
    func syncClipboard() {
        let board = NSPasteboard.general
        guard board.changeCount != clipboardChange else { return }
        clipboardChange = board.changeCount
        let types = board.types ?? []
        selection = (types.contains(.png) || types.contains(.tiff)) ? "" : (board.string(forType: .string) ?? "")
        if !selection.isEmpty {
            history.removeAll { $0 == selection }
            history.insert(selection, at: 0)
            if history.count > 10 { history.removeLast() }
        }
    }
    func publishSelection(_ text: String) {
        guard !text.isEmpty else { return }
        let board = NSPasteboard.general
        if board.string(forType: .string) != text {
            board.clearContents()
            board.setString(text, forType: .string)
        }
        syncClipboard()
    }
    var userInputGeneration = 0
    var pendingCapture: DispatchWorkItem?
    var mouseHeld = false
    var dragStart: CGPoint?
    var copying = false
    var inserting = false
    var interceptMiddle = false
    let syntheticTag: Int64 = 0x42544254
    var tap: CFMachPort?
    var poll: Timer?
    var selection = ""
    var enabled = UserDefaults.standard.object(forKey: "middlePaste") as? Bool ?? true
    func screenshotActive() -> Bool {
        // The screenshot overlay may leave the underlying app frontmost.
        let names = ["screencapture", "screenshot", "snip", "shottr", "cleanshot", "monosnap", "lightshot"]
        if NSWorkspace.shared.runningApplications.contains(where: { app in
            let id = (app.bundleIdentifier ?? "").lowercased()
            let name = (app.localizedName ?? "").lowercased()
            return id.contains("screencapture") || id == "com.apple.screenshot" || name == "screenshot"
        }) { return true }
        if let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            if windows.contains(where: { window in
                let owner = (window[kCGWindowOwnerName as String] as? String ?? "").lowercased()
                return names.contains { owner.contains($0) }
            }) { return true }
        }
        // Firefox screenshots live inside the browser, not in a separate app.
        if let app = NSWorkspace.shared.frontmostApplication,
           (app.bundleIdentifier ?? "").lowercased().contains("firefox") {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.05)
            var window: CFTypeRef?
            if AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &window) == .success, let window {
                var remaining = 220
                let deadline = Date().addingTimeInterval(0.12)
                func scan(_ element: AXUIElement, depth: Int) -> Bool {
                    guard depth < 16, remaining > 0, Date() < deadline else { return false }
                    remaining -= 1
                    for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
                        var value: CFTypeRef?
                        if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let text = value as? String {
                            let text = text.lowercased()
                            if ["save visible", "save full page", "uložit viditeln", "uložit celou stránku", "drag or click on the page", "táhněte nebo klikněte", "screenshot-buttons", "screenshots-preview"].contains(where: { text.contains($0) }) { return true }
                            // Restrict generic screenshot labels to controls, not page content.
                            var role: CFTypeRef?
                            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
                            if ["AXDialog", "AXToolbar"].contains(role as? String ?? ""), text.contains("screenshot") || text.contains("snímek obrazovky") { return true }
                        }
                    }
                    var children: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success, let children = children as? [AXUIElement] {
                        for child in children { if scan(child, depth: depth + 1) { return true } }
                    }
                    return false
                }
                if scan(window as! AXUIElement, depth: 0) { return true }
            }
        }
        return false
    }
    func start() {
        try? status.write(toFile: "/tmp/bateriebt-middle-status.txt", atomically: true, encoding: .utf8)
        guard enabled, AXIsProcessTrusted(), tap == nil else { return }
        let mask = [CGEventType.otherMouseDown, .otherMouseUp, .leftMouseDown, .leftMouseUp, .keyDown].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
            let owner = Unmanaged<MiddlePaste>.fromOpaque(context!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if event.getIntegerValueField(.eventSourceUserData) == owner.syntheticTag { return Unmanaged.passUnretained(event) }
            if type == .keyDown {
                owner.userInputGeneration += 1
                owner.pendingCapture?.cancel()
                owner.pendingCapture = nil
                return Unmanaged.passUnretained(event)
            }
            if owner.screenshotActive() {
                owner.pendingCapture?.cancel()
                owner.pendingCapture = nil
                owner.dragStart = nil
                owner.mouseHeld = false
                return Unmanaged.passUnretained(event)
            }
            if type == .leftMouseDown {
                owner.pendingCapture?.cancel()
                owner.pendingCapture = nil
                owner.mouseHeld = true
                owner.dragStart = event.location
            }
            if type == .leftMouseUp {
                owner.mouseHeld = false
                let moved = owner.dragStart.map { hypot(event.location.x - $0.x, event.location.y - $0.y) > 4 } ?? false
                if moved || event.getIntegerValueField(.mouseEventClickState) >= 2 {
                    let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    let work = DispatchWorkItem { [weak owner] in
                        guard let owner else { return }
                        owner.pendingCapture = nil
                        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                        owner.captureViaCopy()
                    }
                    owner.pendingCapture = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval + 0.08, execute: work)
                }
                return Unmanaged.passUnretained(event)
            }
            if type == .otherMouseDown { try? "Tlačítko: \(event.getIntegerValueField(.mouseEventButtonNumber)), \(owner.status)".write(toFile: "/tmp/bateriebt-middle-click.txt", atomically: true, encoding: .utf8) }
            guard event.getIntegerValueField(.mouseEventButtonNumber) == 2 else { return Unmanaged.passUnretained(event) }
            if type == .otherMouseUp {
                let intercepted = owner.interceptMiddle
                owner.interceptMiddle = false
                owner.hold?.cancel()
                owner.hold = nil
                let point = owner.holdPoint
                owner.holdPoint = nil
                if intercepted, let point {
                    DispatchQueue.main.async { owner.focusAndPaste(at: point) }
                }
                return intercepted ? nil : Unmanaged.passUnretained(event)
            }
            owner.syncClipboard()
            guard owner.enabled, !owner.history.isEmpty else { return Unmanaged.passUnretained(event) }
            if type == .otherMouseDown {
                owner.interceptMiddle = owner.isTextTarget(at: event.location)
                guard owner.interceptMiddle else { return Unmanaged.passUnretained(event) }
                let point = event.location
                owner.holdPoint = point
                let work = DispatchWorkItem { [weak owner] in
                    guard let owner, owner.interceptMiddle else { return }
                    owner.holdPoint = nil
                    owner.showHistory(at: point)
                }
                owner.hold = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
            }
            return nil
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        if poll == nil { poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.syncClipboard() } }
    }
    func capture() {
        guard enabled, !screenshotActive(), !mouseHeld, pendingCapture == nil, !inserting, !copying, let app = NSWorkspace.shared.frontmostApplication else { return }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.1)
        var focus: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &focus) == .success, let focus else { return }
        let element = focus as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.3)
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &role)
        guard (role as? String) != "AXSecureTextField" else { return }
        var text: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &text) == .success, let value = text as? String, !value.isEmpty { selection = value }
    }
    func captureViaCopy() {
        guard enabled, !screenshotActive(), !copying, !inserting, let app = NSWorkspace.shared.frontmostApplication else { return }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.2)
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let focused {
            let element = focused as! AXUIElement
            var subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
            if subrole as? String == "AXSecureTextField" { return }
            var selected: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
               let text = selected as? String, !text.isEmpty {
                publishSelection(text)
                return
            }
        }
        // Firefox's screenshot overlay can expose the underlying page as
        // focused. Only issue Copy if the browser's actual Edit > Copy menu
        // command is enabled; screenshot toolbar buttons do not qualify.
        if (app.bundleIdentifier ?? "").lowercased().contains("firefox") {
            var bar: CFTypeRef?
            guard AXUIElementCopyAttributeValue(root, kAXMenuBarAttribute as CFString, &bar) == .success, let bar else { return }
            func copyEnabled(_ element: AXUIElement, depth: Int) -> Bool {
                guard depth < 5 else { return false }
                var role: CFTypeRef?
                var title: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
                AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
                if role as? String == "AXMenuItem", ["copy", "kopírovat"].contains((title as? String ?? "").lowercased()) {
                    var enabled: CFTypeRef?
                    AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled)
                    return (enabled as? NSNumber)?.boolValue == true
                }
                var children: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success, let list = children as? [AXUIElement] {
                    return list.contains { copyEnabled($0, depth: depth + 1) }
                }
                return false
            }
            guard copyEnabled(bar as! AXUIElement, depth: 0) else { return }
        }
        copying = true
        let board = NSPasteboard.general
        let generation = userInputGeneration
        let before = board.changeCount
        let source = CGEventSource(stateID: .combinedSessionState)
        for pressed in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: pressed)
            event?.flags = .maskCommand
            event?.setIntegerValueField(.eventSourceUserData, value: syntheticTag)
            event?.postToPid(app.processIdentifier)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            defer { self?.copying = false }
            guard let self, self.userInputGeneration == generation, board.changeCount != before else { return }
            // Never restore over a screenshot or other non-text copy.
            let types = board.types ?? []
            guard !types.contains(.png), !types.contains(.tiff), board.string(forType: .string) != nil else { return }
            self.syncClipboard()
        }
    }
    func isTextTarget(at point: CGPoint) -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success else { return false }
        var current = hit
        for _ in 0..<8 {
            guard let element = current else { break }
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            let name = role as? String ?? ""
            if name == "AXLink" { return false }
            if ["AXTextField", "AXTextArea", "AXComboBox"].contains(name) { return true }
            var settable: DarwinBoolean = false
            if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
               settable.boolValue, ["AXWebArea", "AXGroup", "AXStaticText"].contains(name) { return true }
            var editable: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editable) == .success,
               (editable as? NSNumber)?.boolValue == true { return true }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success, let parent else { break }
            current = (parent as! AXUIElement)
        }
        return false
    }
    func showHistory(at point: CGPoint) {
        guard enabled, !screenshotActive(), !history.isEmpty else { return }
        pendingCapture?.cancel()
        pendingCapture = nil
        let menu = NSMenu(title: tr("Historie schránky", "Clipboard History"))
        for (index, entry) in history.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            let preview = entry.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            let item = NSMenuItem(title: String(preview.prefix(70)) + (preview.count > 70 ? "…" : ""),
                                  action: #selector(insertHistory(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry
            menu.addItem(item)
        }
        historyOrigin = point
        historyMenu = menu
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        historyMenu = nil
    }
    @objc func insertHistory(_ item: NSMenuItem) {
        guard enabled, let text = item.representedObject as? String else { return }
        publishSelection(text)
        if let point = historyOrigin {
            DispatchQueue.main.async { [weak self] in self?.focusAndPaste(at: point) }
        }
    }
    var historyOrigin: CGPoint?
    func focusAndPaste(at point: CGPoint) {
        // A middle click does not focus text fields on macOS. Place the caret
        // with a regular click, then insert the saved primary selection.
        syncClipboard()
        let text = selection
        guard !text.isEmpty, !inserting, !screenshotActive() else { return }
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        inserting = true
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.setIntegerValueField(.eventSourceUserData, value: syntheticTag)
            event?.setIntegerValueField(.mouseEventClickState, value: 1)
            event?.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            defer { self.inserting = false }
            guard self.enabled else { return }
            self.paste(text)
        }
    }
    func paste(_ text: String) {
        // Send Unicode keyboard input without replacing the regular clipboard.
        let units = Array(text.utf16)
        guard !units.isEmpty, let source = CGEventSource(stateID: .combinedSessionState) else { return }
        for offset in stride(from: 0, to: units.count, by: 20) {
            let chunk = Array(units[offset..<min(offset + 20, units.count)])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true), let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
            chunk.withUnsafeBufferPointer { buffer in down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!) }
            down.flags = []; up.flags = []
            down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        }
    }
    func toggle() {
        enabled.toggle()
        UserDefaults.standard.set(enabled, forKey: "middlePaste")
        if enabled {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            start()
        } else { selection = "" }
    }
}
