import CoreBluetooth
import Foundation

struct Message: Codable {
    var cmd: String
    var key: String?
    var addresses: [String]?
    var ok: Bool?
    var error: String?
}

/// Finds other Macs running DeviceHop over Bluetooth LE and exchanges one JSON line per request.
/// Every Mac is both a GATT server (answers requests) and a client (sends them). Both
/// characteristics require encryption, so macOS bonds the two Macs on their first exchange.
final class Peers: NSObject, CBPeripheralManagerDelegate, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let serviceUUID = CBUUID(string: "A2A1D5B7-A491-4439-8FD4-FA42D18DC883")
    static let requestUUID = CBUUID(string: "416F6E6A-1BD6-4FA8-A4EF-76315C3C2F70")
    static let replyUUID = CBUUID(string: "BAF6FDF3-19BC-45DC-B0ED-46A3CB38E0AC")
    /// A peer that stops advertising for this long drops out of the menu.
    static let staleAfter: TimeInterval = 20

    let myName: String
    private(set) var peers: [String: CBPeripheral] = [:]
    var handler: ((Message, @escaping (Message) -> Void) -> Void)?
    var onChange: (() -> Void)?

    private var server: CBPeripheralManager?
    private var client: CBCentralManager?
    private var replyChar: CBMutableCharacteristic?
    private var lastSeen: [String: Date] = [:]
    private var pruneTimer: Timer?

    // Server side: request bytes per connected Mac, and reply chunks waiting for queue space.
    private var inbound: [UUID: Data] = [:]
    private var outbox: [(chunk: Data, to: CBCentral)] = []

    // Client side: one outgoing request at a time.
    private struct Outgoing {
        let peripheral: CBPeripheral
        let payload: Data
        var reply = Data()
        let completion: (Message?) -> Void
    }
    private var outgoing: Outgoing?
    private var outgoingID = 0

    init(name: String) {
        myName = name
        super.init()
    }

    func start() {
        server = CBPeripheralManager(delegate: self, queue: .main)
        client = CBCentralManager(delegate: self, queue: .main)
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.prune() }
    }

    func send(_ msg: Message, to name: String, completion: @escaping (Message?) -> Void) {
        guard let p = peers[name], let client, outgoing == nil,
              var d = try? JSONEncoder().encode(msg) else { completion(nil); return }
        d.append(0x0A)
        outgoing = Outgoing(peripheral: p, payload: d, completion: completion)
        outgoingID += 1
        let id = outgoingID
        p.delegate = self
        client.connect(p)
        // Generous, since the first exchange may wait on the user accepting a pairing prompt.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.outgoingID == id else { return }
            self.finish(nil)
        }
    }

    private func finish(_ m: Message?) {
        guard let o = outgoing else { return }
        outgoing = nil
        outgoingID += 1
        client?.cancelPeripheralConnection(o.peripheral)
        o.completion(m)
    }

    private func fail(_ what: String, _ error: Error?) {
        let detail = error.map { ": \($0.localizedDescription)" } ?? ""
        finish(Message(cmd: "reply", ok: false, error: "Bluetooth \(what) failed\(detail)"))
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Peers.staleAfter)
        let stale = lastSeen.filter { $0.value < cutoff }.map(\.key)
        guard !stale.isEmpty else { return }
        stale.forEach { lastSeen[$0] = nil; peers[$0] = nil }
        onChange?()
    }

    // MARK: Server

    func peripheralManagerDidUpdateState(_ pm: CBPeripheralManager) {
        guard pm.state == .poweredOn, replyChar == nil else { return }
        let request = CBMutableCharacteristic(
            type: Peers.requestUUID, properties: [.write], value: nil, permissions: [.writeEncryptionRequired])
        let reply = CBMutableCharacteristic(
            type: Peers.replyUUID, properties: [.notify], value: nil, permissions: [.readEncryptionRequired])
        let service = CBMutableService(type: Peers.serviceUUID, primary: true)
        service.characteristics = [request, reply]
        replyChar = reply
        pm.add(service)
    }

    func peripheralManager(_ pm: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil else { return }
        pm.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Peers.serviceUUID],
            CBAdvertisementDataLocalNameKey: myName,
        ])
    }

    func peripheralManager(_ pm: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests {
            let central = r.central
            let buf = (inbound[central.identifier] ?? Data()) + (r.value ?? Data())
            guard let i = buf.firstIndex(of: 0x0A) else {
                inbound[central.identifier] = buf.count > 65536 ? nil : buf
                continue
            }
            inbound[central.identifier] = nil
            if let handler, let msg = try? JSONDecoder().decode(Message.self, from: Data(buf[buf.startIndex..<i])) {
                handler(msg) { [weak self] reply in self?.sendReply(reply, to: central) }
            }
        }
        if let first = requests.first { pm.respond(to: first, withResult: .success) }
    }

    private func sendReply(_ m: Message, to central: CBCentral) {
        guard var d = try? JSONEncoder().encode(m) else { return }
        d.append(0x0A)
        let size = max(20, central.maximumUpdateValueLength)
        var i = d.startIndex
        while i < d.endIndex {
            let j = min(i + size, d.endIndex)
            outbox.append((Data(d[i..<j]), central))
            i = j
        }
        flush()
    }

    private func flush() {
        guard let server, let replyChar else { return }
        while let next = outbox.first {
            guard server.updateValue(next.chunk, for: replyChar, onSubscribedCentrals: [next.to]) else { return }
            outbox.removeFirst()
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers pm: CBPeripheralManager) {
        flush()
    }

    // MARK: Client

    func centralManagerDidUpdateState(_ cm: CBCentralManager) {
        guard cm.state == .poweredOn else { return }
        cm.scanForPeripherals(withServices: [Peers.serviceUUID],
                              options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func centralManager(_ cm: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        guard let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name,
              name != myName else { return }
        let isNew = peers[name]?.identifier != p.identifier
        peers[name] = p
        lastSeen[name] = Date()
        if isNew { onChange?() }
    }

    func centralManager(_ cm: CBCentralManager, didConnect p: CBPeripheral) {
        guard outgoing?.peripheral == p else { return }
        p.discoverServices([Peers.serviceUUID])
    }

    func centralManager(_ cm: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        if outgoing?.peripheral == p { fail("connect", error) }
    }

    func centralManager(_ cm: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        if outgoing?.peripheral == p { fail("connection", error) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == Peers.serviceUUID }) else {
            fail("service lookup", error)
            return
        }
        p.discoverCharacteristics([Peers.requestUUID, Peers.replyUUID], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard let reply = s.characteristics?.first(where: { $0.uuid == Peers.replyUUID }) else {
            fail("characteristic lookup", error)
            return
        }
        // Subscribing needs encryption; the first time, macOS pairs the two Macs here.
        p.setNotifyValue(true, for: reply)
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard let o = outgoing, o.peripheral == p, c.uuid == Peers.replyUUID else { return }
        guard error == nil, c.isNotifying,
              let request = c.service?.characteristics?.first(where: { $0.uuid == Peers.requestUUID }) else {
            fail("subscribe", error)
            return
        }
        let size = max(20, p.maximumWriteValueLength(for: .withResponse))
        var i = o.payload.startIndex
        while i < o.payload.endIndex {
            let j = min(i + size, o.payload.endIndex)
            p.writeValue(Data(o.payload[i..<j]), for: request, type: .withResponse)
            i = j
        }
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        if let error, outgoing?.peripheral == p { fail("write", error) }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard var o = outgoing, o.peripheral == p, c.uuid == Peers.replyUUID, let v = c.value else { return }
        o.reply.append(v)
        if let i = o.reply.firstIndex(of: 0x0A) {
            finish(try? JSONDecoder().decode(Message.self, from: Data(o.reply[o.reply.startIndex..<i])))
        } else {
            outgoing = o
        }
    }
}
