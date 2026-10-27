import CoreBluetooth
import Foundation

struct Message: Codable {
    var cmd: String
    var key: String?
    var addresses: [String]?
    var ok: Bool?
    var error: String?
    var ts: Int64?
    var sig: String?
}

/// Finds other Macs running DeviceHop over Bluetooth LE and exchanges one JSON line per request.
/// Every Mac is both a GATT server (answers requests) and a client (sends them).
final class Peers: NSObject, CBPeripheralManagerDelegate, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let serviceUUID = CBUUID(string: "A2A1D5B7-A491-4439-8FD4-FA42D18DC883")
    static let requestUUID = CBUUID(string: "416F6E6A-1BD6-4FA8-A4EF-76315C3C2F70")
    static let replyUUID = CBUUID(string: "BAF6FDF3-19BC-45DC-B0ED-46A3CB38E0AC")
    /// Unencrypted, read-only Mac name. The 128-bit service UUID leaves no room for the
    /// local name in a 31-byte advertisement, so clients connect briefly to read it instead.
    static let nameUUID = CBUUID(string: "6E1D3C5A-2F7B-4C8E-9A0D-5B4E3F2A1C7D")
    /// A peer that stops advertising for this long drops out of the menu.
    static let staleAfter: TimeInterval = 20

    let myName: String
    private(set) var peers: [String: CBPeripheral] = [:]
    var handler: ((Message, @escaping (Message) -> Void) -> Void)?
    var onChange: (() -> Void)?

    private var server: CBPeripheralManager?
    private var client: CBCentralManager?
    private var replyChar: CBMutableCharacteristic?
    private var pruneTimer: Timer?

    // Discovery, keyed by peripheral identifier.
    private var known: [UUID: CBPeripheral] = [:]
    private var lastSeen: [UUID: Date] = [:]
    private var names: [UUID: String] = [:]
    private var resolveFailedAt: [UUID: Date] = [:]
    private var resolving: CBPeripheral?
    private var resolvingID = 0

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
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
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
        resolveNext()
    }

    private func fail(_ what: String, _ error: Error?) {
        let detail = error.map { ": \($0.localizedDescription)" } ?? ""
        finish(Message(cmd: "reply", ok: false, error: "Bluetooth \(what) failed\(detail)"))
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Peers.staleAfter)
        let stale = lastSeen.filter { $0.value < cutoff }.map(\.key)
        guard !stale.isEmpty else { return }
        for id in stale where resolving?.identifier != id && outgoing?.peripheral.identifier != id {
            lastSeen[id] = nil
            known[id] = nil
            names[id] = nil
            resolveFailedAt[id] = nil
        }
        rebuildPeers()
    }

    private func rebuildPeers() {
        var next: [String: CBPeripheral] = [:]
        for (id, name) in names where name != myName {
            if let p = known[id] { next[name] = p }
        }
        let changed = Set(next.keys) != Set(peers.keys)
            || next.contains { peers[$0.key]?.identifier != $0.value.identifier }
        peers = next
        if changed { onChange?() }
    }

    // MARK: Name resolution

    private func resolveNext() {
        guard resolving == nil, outgoing == nil, let client, client.state == .poweredOn else { return }
        let retryAfter = Date().addingTimeInterval(-30)
        guard let p = known.values.first(where: { p in
            names[p.identifier] == nil && (resolveFailedAt[p.identifier].map { $0 < retryAfter } ?? true)
        }) else { return }
        resolving = p
        resolvingID += 1
        let id = resolvingID
        p.delegate = self
        client.connect(p)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.resolvingID == id else { return }
            self.finishResolve(nil)
        }
    }

    private func finishResolve(_ name: String?) {
        guard let p = resolving else { return }
        resolving = nil
        resolvingID += 1
        client?.cancelPeripheralConnection(p)
        if let name, !name.isEmpty {
            names[p.identifier] = name
        } else {
            resolveFailedAt[p.identifier] = Date()
        }
        rebuildPeers()
        resolveNext()
    }

    // MARK: Server

    func peripheralManagerDidUpdateState(_ pm: CBPeripheralManager) {
        guard pm.state == .poweredOn, replyChar == nil else { return }
        // No link-layer encryption: macOS won't pair two Macs for it ("Authentication is
        // insufficient"). Messages are instead signed with the shared key (see Auth).
        let request = CBMutableCharacteristic(
            type: Peers.requestUUID, properties: [.write], value: nil, permissions: [.writeable])
        let reply = CBMutableCharacteristic(
            type: Peers.replyUUID, properties: [.notify], value: nil, permissions: [.readable])
        let name = CBMutableCharacteristic(
            type: Peers.nameUUID, properties: [.read], value: Data(myName.utf8), permissions: [.readable])
        let service = CBMutableService(type: Peers.serviceUUID, primary: true)
        service.characteristics = [request, reply, name]
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
        let id = p.identifier
        known[id] = p
        lastSeen[id] = Date()
        if names[id] == nil, let adName = advertisementData[CBAdvertisementDataLocalNameKey] as? String, !adName.isEmpty {
            names[id] = adName
        }
        if names[id] != nil { rebuildPeers() } else { resolveNext() }
    }

    func centralManager(_ cm: CBCentralManager, didConnect p: CBPeripheral) {
        guard outgoing?.peripheral == p || resolving == p else { return }
        p.discoverServices([Peers.serviceUUID])
    }

    func centralManager(_ cm: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        if resolving == p { finishResolve(nil) }
        if outgoing?.peripheral == p { fail("connect", error) }
    }

    func centralManager(_ cm: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        if resolving == p { finishResolve(nil) }
        if outgoing?.peripheral == p { fail("connection", error) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        let s = p.services?.first(where: { $0.uuid == Peers.serviceUUID })
        if resolving == p {
            if let s { p.discoverCharacteristics([Peers.nameUUID], for: s) } else { finishResolve(nil) }
            return
        }
        guard let s else {
            fail("service lookup", error)
            return
        }
        p.discoverCharacteristics([Peers.requestUUID, Peers.replyUUID], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        if resolving == p {
            if let c = s.characteristics?.first(where: { $0.uuid == Peers.nameUUID }) {
                p.readValue(for: c)
            } else {
                finishResolve(nil)
            }
            return
        }
        guard let reply = s.characteristics?.first(where: { $0.uuid == Peers.replyUUID }) else {
            fail("characteristic lookup", error)
            return
        }
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
        if resolving == p, c.uuid == Peers.nameUUID {
            finishResolve(c.value.flatMap { String(data: $0, encoding: .utf8) })
            return
        }
        guard var o = outgoing, o.peripheral == p, c.uuid == Peers.replyUUID, let v = c.value else { return }
        o.reply.append(v)
        if let i = o.reply.firstIndex(of: 0x0A) {
            finish(try? JSONDecoder().decode(Message.self, from: Data(o.reply[o.reply.startIndex..<i])))
        } else {
            outgoing = o
        }
    }
}
