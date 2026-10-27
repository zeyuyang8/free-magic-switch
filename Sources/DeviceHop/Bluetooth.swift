import Foundation
import IOBluetooth
import IOKit

struct BTDevice: Identifiable {
    let address: String
    let name: String
    let connected: Bool
    var battery: Int?

    var id: String { address }

    var symbol: String {
        let n = name.lowercased()
        if n.contains("keyboard") { return "keyboard" }
        if n.contains("mouse") { return "magicmouse" }
        if n.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if n.contains("airpods") || n.contains("headphone") || n.contains("beats") { return "headphones" }
        return "dot.radiowaves.left.and.right"
    }
}

func normalizeAddress(_ a: String) -> String {
    a.lowercased().replacingOccurrences(of: ":", with: "-")
}

final class Bluetooth: NSObject, IOBluetoothDevicePairDelegate {
    var onPasskey: ((String) -> Void)?

    private var pairing: IOBluetoothDevicePair?
    private var pairCompletion: ((Bool) -> Void)?
    private var pairToken = 0

    func pairedDevices() -> [BTDevice] {
        let battery = batteryLevels()
        let list = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return list.compactMap { d in
            guard let raw = d.addressString else { return nil }
            let addr = normalizeAddress(raw)
            return BTDevice(address: addr, name: d.name ?? raw, connected: d.isConnected(), battery: battery[addr])
        }
    }

    private func batteryLevels() -> [String: Int] {
        var result: [String: Int] = [:]
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iter) == KERN_SUCCESS else {
            return result
        }
        defer { IOObjectRelease(iter) }
        var service = IOIteratorNext(iter)
        while service != 0 {
            let addr = IORegistryEntryCreateCFProperty(service, "DeviceAddress" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            let pct = IORegistryEntryCreateCFProperty(service, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
            if let addr, let pct { result[normalizeAddress(addr)] = pct }
            IOObjectRelease(service)
            service = IOIteratorNext(iter)
        }
        return result
    }

    /// Disconnects and unpairs; returns addresses that failed.
    func release(_ addresses: [String]) -> [String] {
        var failed: [String] = []
        // Private IOBluetooth selector; same one blueutil uses for --unpair.
        let remove = Selector(("remove"))
        for a in addresses {
            guard let d = IOBluetoothDevice(addressString: a) else { failed.append(a); continue }
            if d.isConnected() { d.closeConnection() }
            if d.isPaired() {
                if d.responds(to: remove) { d.perform(remove) } else { failed.append(a) }
            }
        }
        return failed
    }

    /// Pairs and connects each device in turn; completion gets the addresses that failed.
    func acquire(_ addresses: [String], completion: @escaping ([String]) -> Void) {
        var remaining = addresses
        var failed: [String] = []
        func next() {
            guard !remaining.isEmpty else { completion(failed); return }
            let a = remaining.removeFirst()
            acquireOne(a, attemptsLeft: 6) { ok in
                if !ok { failed.append(a) }
                next()
            }
        }
        next()
    }

    private func acquireOne(_ a: String, attemptsLeft: Int, done: @escaping (Bool) -> Void) {
        guard let d = IOBluetoothDevice(addressString: a) else { done(false); return }
        let retry = {
            if attemptsLeft > 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self.acquireOne(a, attemptsLeft: attemptsLeft - 1, done: done)
                }
            } else {
                done(false)
            }
        }
        if d.isPaired() {
            if d.isConnected() || d.openConnection() == kIOReturnSuccess { done(true) } else { retry() }
            return
        }
        guard let p = IOBluetoothDevicePair(device: d) else { retry(); return }
        p.delegate = self
        pairing = p
        pairToken += 1
        let token = pairToken
        pairCompletion = { ok in
            if ok {
                _ = d.openConnection()
                done(true)
            } else {
                retry()
            }
        }
        if p.start() != kIOReturnSuccess {
            finishPairing(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.pairToken == token, self.pairCompletion != nil else { return }
            self.pairing?.stop()
            self.finishPairing(false)
        }
    }

    private func finishPairing(_ ok: Bool) {
        let c = pairCompletion
        pairCompletion = nil
        pairing = nil
        c?(ok)
    }

    func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        finishPairing(error == kIOReturnSuccess)
    }

    func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        (sender as? IOBluetoothDevicePair)?.replyUserConfirmation(true)
    }

    func devicePairingUserPasskeyNotification(_ sender: Any!, passkey: BluetoothPasskey) {
        onPasskey?(String(format: "%06u", passkey))
    }
}
