import Cocoa
import Darwin
import IOKit
import CoreBluetooth

struct Device { let name: String; let percent: Int? }
final class Delegate: NSObject, NSApplicationDelegate, CBCentralManagerDelegate, CBPeripheralDelegate {
    let middlePaste = MiddlePaste()
    let keyboardSwitch = KeyboardSwitch()
    var permissionTimer: Timer?
    var central: CBCentralManager!
    var peripherals: [CBPeripheral] = []
    var levels: [UUID: Int] = [:]
    var systemDevices: [Device] = []
    var readingSystem = false
    func readSystemBatteries() {
        guard !readingSystem else { return }
        readingSystem = true
        DispatchQueue.global(qos: .utility).async {
            let process = Process(); let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            process.arguments = ["SPBluetoothDataType", "-json"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            var devices: [Device] = []
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let reports = json["SPBluetoothDataType"] as? [[String: Any]] {
                    for report in reports {
                        for group in report["device_connected"] as? [[String: [String: Any]]] ?? [] {
                            for (name, values) in group {
                                let raw = values["device_batteryLevelMain"] ?? values["device_batteryLevel"]
                                let percent: Int? = (raw as? NSNumber)?.intValue ?? (raw as? String).flatMap { Int($0.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) }
                                devices.append(Device(name: name, percent: percent.flatMap { (0...100).contains($0) ? $0 : nil }))
                            }
                        }
                    }
                }
            } catch { }
            let result = devices
            DispatchQueue.main.async {
                self.systemDevices = result; self.readingSystem = false; self.refresh()
            }
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        peripherals = central.retrieveConnectedPeripherals(withServices: [CBUUID(string: "1812"), CBUUID(string: "180F")])
        for p in peripherals { p.delegate = self; central.connect(p) }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([CBUUID(string: "180F")])
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] { peripheral.discoverCharacteristics([CBUUID(string: "2A19")], for: service) }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            if c.properties.contains(.read) { peripheral.readValue(for: c) }
            if c.properties.contains(.notify) { peripheral.setNotifyValue(true, for: c) }
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if error == nil, let value = characteristic.value?.first, value <= 100 { if levels[peripheral.identifier] != Int(value) { levels[peripheral.identifier] = Int(value); refresh() } }
    }

    var items: [NSStatusItem] = []
    var timer: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        for _ in 0..<2 { items.append(NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)) }
        readSystemBatteries()
        central = CBCentralManager(delegate: self, queue: .main)
        middlePaste.start()
        keyboardSwitch.start()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.middlePaste.start(); self?.keyboardSwitch.start() }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.readSystemBatteries(); self?.refresh() }
    }
    func devices() -> [Device] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [Device] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? { IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) }
            guard let name = property("Product") as? String else { continue }
            let battery = property("BatteryPercent") as? NSNumber
            let value = battery?.intValue
            result.append(Device(name: name, percent: value.flatMap { (0...100).contains($0) ? $0 : nil }))
        }
        return result
    }
    @objc func refresh() {
        let found = systemDevices + devices() + peripherals.map { Device(name: $0.name ?? "", percent: levels[$0.identifier]) }
        for p in peripherals where p.state == .connected {
            for service in p.services ?? [] {
                for c in service.characteristics ?? [] where c.properties.contains(.read) { p.readValue(for: c) }
            }
        }
        for index in 0..<2 {
            let matches = found.filter { device in
                let n = device.name.lowercased()
                return index == 0 ? (n.contains("mv400") || n.contains("mouse") || n.contains("myš")) : (n.replacingOccurrences(of: "-", with: "").contains("etk200") || (n.contains("keyboard") && !n.contains("internal")))
            }
            let device = matches.first(where: { $0.percent != nil }) ?? matches.first
            let percent = device?.percent
            let color: NSColor = percent.map { $0 <= 20 ? .systemRed : ($0 <= 30 ? .systemOrange : .systemGreen) } ?? .secondaryLabelColor
            let symbol = index == 0 ? "computermouse.fill" : "keyboard.fill"
            if let original = NSImage(systemSymbolName: symbol, accessibilityDescription: index == 0 ? tr("Myš", "Mouse") : tr("Klávesnice", "Keyboard")) {
                let image = NSImage(size: NSSize(width: 23, height: 18), flipped: false) { rect in
                    original.draw(in: rect)
                    color.setFill()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                image.isTemplate = false
                items[index].button?.image = image
            }
            items[index].button?.title = percent.map { " \($0)%" } ?? " ?"
            items[index].button?.toolTip = device?.name ?? (index == 0 ? "Eternico MV400" : "ETK200FBT1")
            let menu = NSMenu()
            menu.addItem(withTitle: device?.name ?? tr("Zařízení nenalezeno", "Device not found"), action: nil, keyEquivalent: "")
            menu.addItem(withTitle: percent.map { tr("Baterie", "Battery") + ": \($0) %" } ?? tr("macOS neposkytuje stav baterie", "Battery level unavailable"), action: nil, keyEquivalent: "")
            menu.addItem(withTitle: tr("Baterie BT 1.4", "BT Battery 1.4"), action: nil, keyEquivalent: "")
            menu.addItem(.separator())
            let refresh = menu.addItem(withTitle: tr("Obnovit (automaticky každou minutu)", "Refresh (automatic every minute)"), action: #selector(self.refresh), keyEquivalent: "r")
            refresh.target = self
            menu.addItem(withTitle: middlePaste.status, action: nil, keyEquivalent: "")
            let pasteItem = menu.addItem(withTitle: tr("Vkládání označeného textu kolečkem", "Middle-click to paste selected text"), action: #selector(togglePaste), keyEquivalent: "")
            pasteItem.target = self
            pasteItem.state = middlePaste.enabled ? .on : .off
            let shortcut = menu.addItem(withTitle: tr("CZ/EN: Option nebo Win + levý Shift", "CZ/EN: Option or Win + Left Shift"), action: #selector(toggleLayout), keyEquivalent: "")
            shortcut.target = self
            shortcut.state = keyboardSwitch.enabled ? .on : .off
            let access = menu.addItem(withTitle: tr("Povolit Zpřístupnění…", "Enable Accessibility…"), action: #selector(accessibility), keyEquivalent: "")
            access.target = self
            let settings = menu.addItem(withTitle: tr("Nastavení Bluetooth…", "Bluetooth Settings…"), action: #selector(bluetooth), keyEquivalent: "")
            settings.target = self
            menu.addItem(withTitle: tr("Ukončit", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            items[index].menu = menu
        }
    }
    @objc func toggleLayout() { keyboardSwitch.toggle(); refresh() }
    @objc func togglePaste() { middlePaste.toggle(); refresh() }
    @objc func accessibility() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    @objc func bluetooth() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!) }
}
// Prevent the project copy and installed copy handling the same shortcut.
let lockPath = FileManager.default.temporaryDirectory.appendingPathComponent("cz.local.bateriebt.lock").path
let instanceLock = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
if instanceLock < 0 || flock(instanceLock, LOCK_EX | LOCK_NB) != 0 { exit(0) }
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
