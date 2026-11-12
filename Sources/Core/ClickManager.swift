// Shared core: Zwift Click v2 over BLE -> keystrokes. Used by both the CLI and the menu bar app.
//
// Protocol details are credited to the reverse-engineering work in OpenBikeControl/BikeControl
// (https://github.com/OpenBikeControl/bikecontrol). This is an independent Swift implementation.
//
// Protocol notes:
//   * Advert manufacturer data: company 0x094A (Zwift), next byte = device type
//       0x0A = Click v2 right puck, 0x0B = Click v2 left puck
//   * Service 0xFC82 (or 00000001-19CA-4651-86E5-FA29DCDD09D1)
//       0002 async (notify) · 0003 syncRx (write "RideOn"+02 03) · 0004 syncTx (indicate)
//   * Button notification: opcode 0x23 + protobuf { 1: varint ButtonMap }.
//     A bit is CLEARED while the button is pressed.
//   * The LEFT puck is locked by Zwift firmware unless unlocked via the Zwift app in
//     the last ~24 h. The RIGHT puck works without that.

import AppKit
import ApplicationServices
import Combine
import CoreBluetooth
import Foundation

// MARK: - Keys & buttons ------------------------------------------------------

public struct KeyOption: Hashable, Identifiable {
    public let name: String
    public let code: CGKeyCode?
    public var id: String { name }
}

public let keyOptions: [KeyOption] = [
    KeyOption(name: "None", code: nil),
    KeyOption(name: "I", code: 0x22), KeyOption(name: "K", code: 0x28),
    KeyOption(name: "A", code: 0x00), KeyOption(name: "D", code: 0x02),
    KeyOption(name: "H", code: 0x04), KeyOption(name: "Space", code: 0x31),
    KeyOption(name: "Return", code: 0x24), KeyOption(name: "Escape", code: 0x35),
    KeyOption(name: "←", code: 0x7B), KeyOption(name: "→", code: 0x7C),
    KeyOption(name: "↑", code: 0x7E), KeyOption(name: "↓", code: 0x7D),
    KeyOption(name: "1", code: 0x12), KeyOption(name: "2", code: 0x13), KeyOption(name: "3", code: 0x14),
    KeyOption(name: "4", code: 0x15), KeyOption(name: "5", code: 0x17), KeyOption(name: "6", code: 0x16),
    KeyOption(name: "7", code: 0x1A),
]

public struct ClickButton: Identifiable {
    public let id: String          // stable name, used as mapping key
    public let label: String
    public let mask: UInt32
    public let leftPuck: Bool
    public let defaultKey: String
    public let repeats: Bool       // auto-repeat while held
}

public let clickButtons: [ClickButton] = [
    ClickButton(id: "plus",  label: "+  (right)", mask: 0x01000, leftPuck: false, defaultKey: "K", repeats: true),
    ClickButton(id: "B",     label: "B",          mask: 0x00020, leftPuck: false, defaultKey: "I", repeats: true),
    ClickButton(id: "A",     label: "A",          mask: 0x00010, leftPuck: false, defaultKey: "Return", repeats: false),
    ClickButton(id: "Y",     label: "Y",          mask: 0x00040, leftPuck: false, defaultKey: "H", repeats: false),
    ClickButton(id: "Z",     label: "Z",          mask: 0x00080, leftPuck: false, defaultKey: "None", repeats: false),
    ClickButton(id: "minus", label: "−  (left)",  mask: 0x00100, leftPuck: true,  defaultKey: "I", repeats: true),
    ClickButton(id: "up",    label: "▲",          mask: 0x00002, leftPuck: true,  defaultKey: "↑", repeats: false),
    ClickButton(id: "down",  label: "▼",          mask: 0x00008, leftPuck: true,  defaultKey: "↓", repeats: false),
    ClickButton(id: "left",  label: "◀",          mask: 0x00001, leftPuck: true,  defaultKey: "←", repeats: false),
    ClickButton(id: "right", label: "▶",          mask: 0x00004, leftPuck: true,  defaultKey: "→", repeats: false),
]

let allButtonsMask = clickButtons.reduce(UInt32(0)) { $0 | $1.mask }
let myWhooshBundleID = "com.whoosh.whooshgame"

// MARK: - Protocol helpers ----------------------------------------------------

let zwiftCompanyID: UInt16 = 0x094A
let deviceTypes: [UInt8: String] = [0x0A: "Click v2 right", 0x0B: "Click v2 left"]
let rideService   = CBUUID(string: "FC82")
let legacyService = CBUUID(string: "00000001-19CA-4651-86E5-FA29DCDD09D1")
let asyncChar     = CBUUID(string: "00000002-19CA-4651-86E5-FA29DCDD09D1")
let syncRxChar    = CBUUID(string: "00000003-19CA-4651-86E5-FA29DCDD09D1")
let syncTxChar    = CBUUID(string: "00000004-19CA-4651-86E5-FA29DCDD09D1")
let rideOnHandshake = Data("RideOn".utf8) + Data([0x02, 0x03])
let opControllerNotification: UInt8 = 0x23
let opBattery: UInt8 = 0x19

func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined(separator: " ") }

func readVarint(_ d: [UInt8], _ i: Int) -> (UInt64, Int)? {
    var result: UInt64 = 0, shift: UInt64 = 0, j = i
    while j < d.count, shift < 64 {
        let b = d[j]; j += 1
        result |= UInt64(b & 0x7F) << shift
        if b & 0x80 == 0 { return (result, j) }
        shift += 7
    }
    return nil
}

/// Field 1 (ButtonMap) of a RideKeyPadStatus protobuf payload.
func parseButtonMap(_ p: [UInt8]) -> UInt32? {
    var i = 0
    while i < p.count {
        guard let (tag, n) = readVarint(p, i) else { return nil }
        i = n
        switch tag & 7 {
        case 0:
            guard let (v, n2) = readVarint(p, i) else { return nil }
            if tag >> 3 == 1 { return UInt32(truncatingIfNeeded: v) }
            i = n2
        case 2:
            guard let (len, n2) = readVarint(p, i) else { return nil }
            i = n2 + Int(len)
        case 5: i += 4
        case 1: i += 8
        default: return nil
        }
    }
    return nil
}

func postKey(_ code: CGKeyCode) {
    DispatchQueue.global(qos: .userInteractive).async {
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
        usleep(40_000) // hold a couple of frames so the game sees it
        CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
    }
}

// MARK: - Manager -------------------------------------------------------------

public struct PuckState: Identifiable {
    public let id: UUID
    public var name: String
    public var connected: Bool
    public var ready: Bool
    public var battery: Int?
    public var isLeft: Bool
}

public final class ClickManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published public private(set) var pucks: [PuckState] = []
    @Published public private(set) var pressed: Set<String> = []
    @Published public private(set) var lastEvent = "—"
    @Published public private(set) var accessibilityOK = AXIsProcessTrusted()
    @Published public private(set) var bluetoothStatus = "Starting…"

    @Published public var enabled: Bool { didSet { defaults.set(enabled, forKey: "enabled") } }
    @Published public var onlyWhenMyWhooshFront: Bool { didSet { defaults.set(onlyWhenMyWhooshFront, forKey: "onlyMyWhoosh") } }
    @Published public var mapping: [String: String] { didSet { defaults.set(mapping, forKey: "mapping") } }

    public var log: (String) -> Void = { _ in }
    public var verbose = false

    // Shared between the CLI and the app (different bundle IDs).
    private let defaults = UserDefaults(suiteName: "local.click2whoosh.shared")!
    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var rawPressed: [UUID: UInt32] = [:]
    private var repeatTimers: [String: Timer] = [:]
    private var axTimer: Timer?

    public override init() {
        enabled = defaults.object(forKey: "enabled") as? Bool ?? true
        onlyWhenMyWhooshFront = defaults.object(forKey: "onlyMyWhoosh") as? Bool ?? true
        var m = defaults.dictionary(forKey: "mapping") as? [String: String] ?? [:]
        for b in clickButtons where m[b.id] == nil { m[b.id] = b.defaultKey }
        mapping = m
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let ok = AXIsProcessTrusted()
            if ok != self.accessibilityOK { self.accessibilityOK = ok }
        }
        RunLoop.main.add(t, forMode: .common)
        axTimer = t
    }

    public func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    public func resetMapping() {
        mapping = Dictionary(uniqueKeysWithValues: clickButtons.map { ($0.id, $0.defaultKey) })
    }

    // MARK: Scan / connect

    private func startScan() {
        bluetoothStatus = "Scanning — press a button on each puck to wake it"
        log("Scanning for Zwift Click v2…")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func update(_ id: UUID, _ f: (inout PuckState) -> Void) {
        if let i = pucks.firstIndex(where: { $0.id == id }) { f(&pucks[i]) }
    }

    private func name(_ p: CBPeripheral) -> String { pucks.first { $0.id == p.identifier }?.name ?? "?" }

    public func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: startScan()
        case .unauthorized: bluetoothStatus = "Bluetooth permission denied (System Settings › Privacy & Security › Bluetooth)"
        case .poweredOff: bluetoothStatus = "Bluetooth is off"
        default: bluetoothStatus = "Bluetooth unavailable (\(c.state.rawValue))"
        }
        if c.state != .poweredOn { log(bluetoothStatus) }
    }

    public func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                               advertisementData ad: [String: Any], rssi: NSNumber) {
        guard peripherals[p.identifier] == nil,
              let m = ad[CBAdvertisementDataManufacturerDataKey] as? Data, m.count >= 3,
              UInt16(m[0]) | UInt16(m[1]) << 8 == zwiftCompanyID else { return }
        if verbose { log("Zwift advert \(p.name ?? "") rssi=\(rssi) mfr=\(hex(m))") }
        guard let n = deviceTypes[m[2]] else { return }
        log("Found \(n) — connecting")
        peripherals[p.identifier] = p
        if pucks.contains(where: { $0.id == p.identifier }) {
            update(p.identifier) { $0.connected = false; $0.ready = false }
        } else {
            pucks.append(PuckState(id: p.identifier, name: n, connected: false, ready: false, battery: nil, isLeft: m[2] == 0x0B))
            pucks.sort { !$0.isLeft && $1.isLeft }
        }
        p.delegate = self
        c.connect(p)
    }

    public func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log("Connected \(name(p))")
        update(p.identifier) { $0.connected = true }
        p.discoverServices([rideService, legacyService])
    }

    public func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log("Failed to connect \(name(p)): \(error?.localizedDescription ?? "")")
        forget(p)
    }

    public func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        log("Disconnected \(name(p)) — will reconnect when it wakes")
        forget(p)
    }

    private func forget(_ p: CBPeripheral) {
        peripherals[p.identifier] = nil
        rawPressed[p.identifier] = nil
        update(p.identifier) { $0.connected = false; $0.ready = false }
        for (k, t) in repeatTimers where k.hasPrefix(p.identifier.uuidString) { t.invalidate(); repeatTimers[k] = nil }
        recomputePressed()
        central.stopScan(); startScan()
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = p.services?.first(where: { $0.uuid == rideService || $0.uuid == legacyService }) else {
            log("\(name(p)): Zwift service not found (locked?)")
            return
        }
        p.discoverCharacteristics([asyncChar, syncRxChar, syncTxChar], for: svc)
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor svc: CBService, error: Error?) {
        guard let chars = svc.characteristics else { return }
        for ch in chars where ch.uuid == asyncChar || ch.uuid == syncTxChar { p.setNotifyValue(true, for: ch) }
        if let rx = chars.first(where: { $0.uuid == syncRxChar }) {
            let type: CBCharacteristicWriteType = rx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            p.writeValue(rideOnHandshake, for: rx, type: type)
            update(p.identifier) { $0.ready = true }
            log("\(name(p)): ready")
        }
    }

    public func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let data = ch.value, !data.isEmpty else { return }
        if verbose { log("\(name(p)) \(ch.uuid.uuidString.prefix(8)): \(hex(data))") }
        let bytes = [UInt8](data)
        switch bytes[0] {
        case opControllerNotification:
            if let map = parseButtonMap(Array(bytes.dropFirst())) { handle(p.identifier, buttonMap: map) }
        case opBattery where bytes.count >= 3:
            let pct = Int(bytes[2])
            update(p.identifier) { $0.battery = pct }
        default: break
        }
    }

    // MARK: Buttons

    private func recomputePressed() {
        let all = rawPressed.values.reduce(UInt32(0), |)
        pressed = Set(clickButtons.filter { all & $0.mask != 0 }.map(\.id))
    }

    private func handle(_ id: UUID, buttonMap: UInt32) {
        let now = ~buttonMap & allButtonsMask
        let before = rawPressed[id] ?? 0
        rawPressed[id] = now
        recomputePressed()

        for b in clickButtons {
            let timerKey = "\(id.uuidString)/\(b.id)"
            let down = now & b.mask != 0, wasDown = before & b.mask != 0
            if down && !wasDown {
                guard let code = keyOptions.first(where: { $0.name == mapping[b.id] })?.code else {
                    report("\(b.label) (unmapped)"); continue
                }
                guard fire(b, code) else { continue }
                if b.repeats {
                    let t = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
                        guard let self else { return }
                        let r = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in _ = self?.fire(b, code, quiet: true) }
                        RunLoop.main.add(r, forMode: .common)
                        self.repeatTimers[timerKey] = r
                    }
                    RunLoop.main.add(t, forMode: .common)
                    repeatTimers[timerKey] = t
                }
            } else if !down && wasDown {
                repeatTimers[timerKey]?.invalidate(); repeatTimers[timerKey] = nil
            }
        }
    }

    /// Sends the key if allowed; returns whether it was sent.
    private func fire(_ b: ClickButton, _ code: CGKeyCode, quiet: Bool = false) -> Bool {
        let keyName = mapping[b.id] ?? "?"
        guard enabled else { if !quiet { report("\(b.label) → paused") }; return false }
        guard AXIsProcessTrusted() else {
            accessibilityOK = false
            if !quiet { report("\(b.label) → \(keyName) dropped: no Accessibility permission") }
            return false
        }
        let front = NSWorkspace.shared.frontmostApplication
        if onlyWhenMyWhooshFront && front?.bundleIdentifier != myWhooshBundleID {
            if !quiet { report("\(b.label) → \(keyName) skipped: MyWhoosh not in front (\(front?.localizedName ?? "?"))") }
            return false
        }
        if !dryRun { postKey(code) }
        if !quiet { report("\(b.label) → \(keyName) → \(front?.localizedName ?? "?")") }
        return true
    }

    // MARK: Test mode

    /// Never posts keystrokes (test mode).
    public var dryRun = false

    /// Test mode (env CLICK2WHOOSH_SIMULATE=1): fakes a right puck and rapid random button
    /// presses so the UI can be exercised without hardware. Implies dryRun.
    public func startSimulation() {
        dryRun = true
        let id = UUID()
        pucks.append(PuckState(id: id, name: "Simulated right", connected: true, ready: true, battery: 80, isLeft: false))
        let t = Timer(timeInterval: 0.07, repeats: true) { [weak self] _ in
            let b = clickButtons.randomElement()!
            let map = Bool.random() ? ~b.mask : 0xFFFFFFFF
            self?.handle(id, buttonMap: map)
        }
        RunLoop.main.add(t, forMode: .common)
    }

    private func report(_ s: String) {
        lastEvent = s
        log(s)
    }
}
