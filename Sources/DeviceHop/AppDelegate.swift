import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let bt = Bluetooth()
    private let peers = Peers(name: Host.current().localizedName ?? "Mac")
    private let defaults = UserDefaults.standard
    private var statusItem: NSStatusItem!
    private var status = "Idle"
    private var busy = false

    private var sharedKey: String {
        get {
            if let k = defaults.string(forKey: "sharedKey"), !k.isEmpty { return k }
            let k = String((0..<8).map { _ in "abcdefghjkmnpqrstuvwxyz23456789".randomElement()! })
            defaults.set(k, forKey: "sharedKey")
            return k
        }
        set { defaults.set(newValue, forKey: "sharedKey") }
    }

    private var selected: [String] {
        get {
            if let s = defaults.stringArray(forKey: "devices") { return s }
            return bt.pairedDevices().filter { $0.name.localizedCaseInsensitiveContains("magic") }.map(\.address)
        }
        set { defaults.set(Array(Set(newValue)).sorted(), forKey: "devices") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon("keyboard")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        bt.onPasskey = { [weak self] code in
            self?.statusItem.button?.title = " Type \(code) ⏎"
            self?.setStatus("Type \(code) then Return on the keyboard")
        }
        peers.handler = { [weak self] msg, reply in self?.handle(msg, reply: reply) }
        do {
            try peers.start()
        } catch {
            setStatus("Network error: \(error.localizedDescription)")
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(disabled("DeviceHop — \(status)"))
        menu.addItem(.separator())

        let names = peers.peers.keys.sorted()
        if names.isEmpty {
            menu.addItem(disabled("No other Macs found (run DeviceHop on them)"))
        } else {
            menu.addItem(disabled("Send devices to"))
            for n in names { menu.addItem(item("  → \(n)", #selector(sendTo(_:)), n)) }
            menu.addItem(disabled("Take devices from"))
            for n in names { menu.addItem(item("  ← \(n)", #selector(takeFrom(_:)), n)) }
        }
        menu.items.filter { $0.action != nil }.forEach { $0.isEnabled = !busy }

        menu.addItem(.separator())
        menu.addItem(disabled("Devices to switch"))
        let sel = Set(selected)
        let paired = bt.pairedDevices()
        for d in paired {
            let i = item("  \(d.name)\(d.connected ? "" : " (not connected)")", #selector(toggleDevice(_:)), d.address)
            i.state = sel.contains(d.address) ? .on : .off
            menu.addItem(i)
        }
        if paired.isEmpty { menu.addItem(disabled("  No paired Bluetooth devices")) }

        menu.addItem(.separator())
        menu.addItem(disabled("Shared key: \(sharedKey)"))
        menu.addItem(item("Set Shared Key…", #selector(setKey), nil))
        menu.addItem(item("Quit DeviceHop", #selector(NSApplication.terminate(_:)), nil))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func item(_ title: String, _ action: Selector, _ obj: Any?) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = action == #selector(NSApplication.terminate(_:)) ? NSApp : self
        i.representedObject = obj
        return i
    }

    @objc private func toggleDevice(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? String else { return }
        var s = selected
        if let idx = s.firstIndex(of: a) { s.remove(at: idx) } else { s.append(a) }
        selected = s
    }

    @objc private func setKey() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Shared key"
        alert.informativeText = "Use the same key on every Mac. Requests with a different key are ignored."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = sharedKey
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let k = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !k.isEmpty { sharedKey = k }
        }
    }

    // MARK: Switching

    @objc private func sendTo(_ sender: NSMenuItem) {
        guard let peer = sender.representedObject as? String else { return }
        let addrs = selected
        guard !addrs.isEmpty else { setStatus("No devices selected"); return }
        begin("Contacting \(peer)…")
        peers.send(Message(cmd: "ping", key: sharedKey), to: peer) { [weak self] reply in
            guard let self else { return }
            guard let reply, reply.ok == true else {
                self.end(reply?.error ?? "\(peer) did not respond")
                return
            }
            self.setStatus("Releasing devices…")
            let failed = self.bt.release(addrs)
            if !failed.isEmpty { self.setStatus("Could not unpair \(failed.count) device(s)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.peers.send(Message(cmd: "acquire", key: self.sharedKey, addresses: addrs), to: peer) { reply in
                    if reply?.ok == true {
                        self.end("Sent to \(peer)")
                    } else {
                        self.setStatus("\(peer) unreachable, taking devices back…")
                        self.bt.acquire(addrs) { _ in self.end("Send failed; devices reclaimed") }
                    }
                }
            }
        }
    }

    @objc private func takeFrom(_ sender: NSMenuItem) {
        guard let peer = sender.representedObject as? String else { return }
        begin("Asking \(peer) to release…")
        peers.send(Message(cmd: "release", key: sharedKey), to: peer) { [weak self] reply in
            guard let self else { return }
            guard let reply, let addrs = reply.addresses, !addrs.isEmpty else {
                self.end(reply?.error ?? "\(peer) did not respond")
                return
            }
            self.selected = self.selected + addrs
            self.setStatus("Pairing \(addrs.count) device(s)…")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.bt.acquire(addrs) { failed in
                    if failed.isEmpty {
                        self.end("Took devices from \(peer)")
                    } else {
                        self.peers.send(Message(cmd: "acquire", key: self.sharedKey, addresses: failed), to: peer) { _ in }
                        self.end("Pairing failed; returned \(failed.count) device(s) to \(peer)")
                    }
                }
            }
        }
    }

    private func handle(_ m: Message, reply: @escaping (Message) -> Void) {
        guard m.key == sharedKey else {
            reply(Message(cmd: "reply", ok: false, error: "Shared key mismatch"))
            return
        }
        switch m.cmd {
        case "ping":
            reply(Message(cmd: "reply", ok: !busy, error: busy ? "Peer is busy" : nil))
        case "release":
            let addrs = selected
            guard !busy, !addrs.isEmpty else {
                reply(Message(cmd: "reply", ok: false, error: busy ? "Peer is busy" : "Peer has no devices selected"))
                return
            }
            let failed = bt.release(addrs)
            setStatus("Released devices to another Mac")
            reply(Message(cmd: "reply", addresses: addrs.filter { !failed.contains($0) }, ok: failed.isEmpty))
        case "acquire":
            let addrs = (m.addresses ?? []).map(normalizeAddress)
            reply(Message(cmd: "reply", ok: true))
            selected = selected + addrs
            begin("Pairing \(addrs.count) device(s)…")
            bt.acquire(addrs) { [weak self] failed in
                self?.end(failed.isEmpty ? "Devices connected" : "Could not connect \(failed.count) device(s)")
            }
        default:
            reply(Message(cmd: "reply", ok: false, error: "Unknown command"))
        }
    }

    // MARK: Status

    private func begin(_ s: String) {
        busy = true
        setIcon("arrow.left.arrow.right")
        setStatus(s)
    }

    private func end(_ s: String) {
        busy = false
        setIcon("keyboard")
        statusItem.button?.title = ""
        setStatus(s)
    }

    private func setStatus(_ s: String) {
        status = s
        statusItem.button?.toolTip = "DeviceHop — \(s)"
    }

    private func setIcon(_ symbol: String) {
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "DeviceHop")
    }
}
