import AppKit
import Combine

final class AppModel: ObservableObject {
    @Published var status = "Ready"
    @Published var busy = false
    @Published var passkey: String?
    @Published var devices: [BTDevice] = []
    @Published var peerNames: [String] = []
    @Published var availableUpdate: String?
    @Published var updating = false
    @Published var selected: Set<String> {
        didSet { UserDefaults.standard.set(Array(selected).sorted(), forKey: "devices") }
    }
    @Published var sharedKey: String {
        didSet { UserDefaults.standard.set(sharedKey, forKey: "sharedKey") }
    }
    @Published var autoUpdate: Bool {
        didSet { UserDefaults.standard.set(autoUpdate, forKey: "autoUpdate") }
    }

    private let bt = Bluetooth()
    private let updater = Updater()
    private let preview: Bool
    private var peers: Peers?
    private var updateTimer: Timer?

    init(preview: Bool = false) {
        self.preview = preview
        let d = UserDefaults.standard
        sharedKey = d.string(forKey: "sharedKey") ?? ""
        selected = Set(d.stringArray(forKey: "devices") ?? [])
        autoUpdate = d.object(forKey: "autoUpdate") as? Bool ?? true

        if preview {
            loadPreviewData()
            return
        }

        if sharedKey.isEmpty {
            sharedKey = String((0..<8).map { _ in "abcdefghjkmnpqrstuvwxyz23456789".randomElement()! })
            d.set(sharedKey, forKey: "sharedKey")
        }
        refreshDevices()
        if d.stringArray(forKey: "devices") == nil {
            selected = Set(devices.map(\.address))
            d.set(Array(selected).sorted(), forKey: "devices")
        }

        bt.onPasskey = { [weak self] code in
            self?.passkey = code
            self?.status = "Type the code on the keyboard"
        }

        let p = Peers(name: Host.current().localizedName ?? "Mac")
        p.handler = { [weak self] msg, reply in self?.handle(msg, reply: reply) }
        p.onChange = { [weak self, weak p] in self?.peerNames = p?.peers.keys.sorted() ?? [] }
        p.start()
        peers = p

        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkForUpdates() }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.checkForUpdates()
        }
    }

    var version: String { Updater.current }
    var selectedCount: Int { devices.filter { selected.contains($0.address) }.count }

    func refreshDevices() {
        guard !preview else { return }
        let order: [BTDevice.Kind] = [.keyboard, .mouse, .trackpad]
        devices = bt.pairedDevices().sorted { a, b in
            let ka = order.firstIndex(of: a.kind)!, kb = order.firstIndex(of: b.kind)!
            return ka != kb ? ka < kb : a.name.localizedCompare(b.name) == .orderedAscending
        }
    }

    /// Selected addresses that are currently paired keyboards or mice here.
    private func switchable() -> [String] {
        refreshDevices()
        return devices.map(\.address).filter(selected.contains)
    }

    func setSelected(_ address: String, _ on: Bool) {
        if on { selected.insert(address) } else { selected.remove(address) }
    }

    // MARK: Switching

    func send(to peer: String) {
        guard let peers else { return }
        let addrs = switchable()
        guard !addrs.isEmpty else { status = "No keyboard or mouse here to send"; return }
        begin("Contacting \(peer)…")
        peers.send(Message(cmd: "ping", key: sharedKey), to: peer) { [weak self] reply in
            guard let self else { return }
            guard let reply, reply.ok == true else {
                self.end(reply?.error ?? "\(peer) didn't respond")
                return
            }
            self.status = "Releasing devices…"
            _ = self.bt.release(addrs)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.status = "Handing over to \(peer)…"
                peers.send(Message(cmd: "acquire", key: self.sharedKey, addresses: addrs), to: peer) { reply in
                    if reply?.ok == true {
                        self.end("Sent to \(peer)")
                    } else {
                        self.status = "\(peer) unreachable — taking devices back…"
                        self.bt.acquire(addrs) { _ in self.end("Send failed; devices reclaimed") }
                    }
                }
            }
        }
    }

    func take(from peer: String) {
        guard let peers else { return }
        begin("Asking \(peer) to let go…")
        peers.send(Message(cmd: "release", key: sharedKey), to: peer) { [weak self] reply in
            guard let self else { return }
            guard let reply, let addrs = reply.addresses, !addrs.isEmpty else {
                self.end(reply?.error ?? "\(peer) didn't respond")
                return
            }
            self.selected.formUnion(addrs)
            self.status = "Pairing \(addrs.count) device\(addrs.count == 1 ? "" : "s")…"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.bt.acquire(addrs) { failed in
                    if failed.isEmpty {
                        self.end("Connected — devices are here")
                    } else {
                        peers.send(Message(cmd: "acquire", key: self.sharedKey, addresses: failed), to: peer) { _ in }
                        self.end("Pairing failed; returned to \(peer)")
                    }
                }
            }
        }
    }

    private func handle(_ m: Message, reply: @escaping (Message) -> Void) {
        guard !sharedKey.isEmpty, m.key == sharedKey else {
            reply(Message(cmd: "reply", ok: false, error: "Shared key doesn't match"))
            return
        }
        switch m.cmd {
        case "ping":
            reply(Message(cmd: "reply", ok: !busy, error: busy ? "Other Mac is busy" : nil))
        case "release":
            let addrs = switchable()
            guard !busy, !addrs.isEmpty else {
                reply(Message(cmd: "reply", ok: false, error: busy ? "Other Mac is busy" : "Other Mac has no keyboard or mouse"))
                return
            }
            let failed = bt.release(addrs)
            status = "Devices sent to another Mac"
            refreshDevices()
            reply(Message(cmd: "reply", addresses: addrs.filter { !failed.contains($0) }, ok: failed.isEmpty))
        case "acquire":
            let addrs = (m.addresses ?? []).map(normalizeAddress)
            reply(Message(cmd: "reply", ok: true))
            selected.formUnion(addrs)
            begin("Pairing \(addrs.count) device\(addrs.count == 1 ? "" : "s")…")
            bt.acquire(addrs) { [weak self] failed in
                self?.end(failed.isEmpty ? "Connected — devices are here" : "Couldn't connect \(failed.count) device(s)")
            }
        default:
            reply(Message(cmd: "reply", ok: false, error: "Unknown command"))
        }
    }

    private func begin(_ s: String) {
        busy = true
        status = s
    }

    private func end(_ s: String) {
        busy = false
        passkey = nil
        status = s
        refreshDevices()
        if autoUpdate, availableUpdate != nil { installUpdate() }
    }

    // MARK: Updates

    func checkForUpdates(manual: Bool = false) {
        if manual { status = "Checking for updates…" }
        updater.latestVersion { [weak self] latest in
            guard let self else { return }
            guard let latest else {
                if manual { self.status = "Couldn't reach the update server" }
                return
            }
            if Updater.isNewer(latest, than: self.version) {
                self.availableUpdate = latest
                if manual { self.status = "Version \(latest) is available" }
                if self.autoUpdate, !self.busy { self.installUpdate() }
            } else {
                self.availableUpdate = nil
                if manual { self.status = "You're up to date" }
            }
        }
    }

    func installUpdate() {
        guard let v = availableUpdate, !updating, !busy else { return }
        updating = true
        status = "Installing \(v)… DeviceHop will restart"
        do {
            try updater.install(v) { [weak self] status in
                if status == 0 {
                    Updater.relaunch()
                    return
                }
                self?.updating = false
                self?.status = "Update failed — see ~/Library/Logs/DeviceHop-update.log"
            }
        } catch {
            updating = false
            status = "Update failed: \(error.localizedDescription)"
        }
    }

    func revealUpdateLog() {
        NSWorkspace.shared.activateFileViewerSelecting([Updater.logURL])
    }

    // MARK: Preview

    private func loadPreviewData() {
        devices = [
            BTDevice(address: "9c-58-3c-e9-da-c1", name: "Magic Keyboard", kind: .keyboard, connected: true, battery: 94),
            BTDevice(address: "bc-89-a7-d9-0f-ba", name: "Magic Mouse", kind: .mouse, connected: true, battery: 23),
        ]
        selected = ["9c-58-3c-e9-da-c1", "bc-89-a7-d9-0f-ba"]
        peerNames = ["Studio Mac mini"]
        sharedKey = "k7wq3mzp"
        availableUpdate = "1.2.0"
    }
}
