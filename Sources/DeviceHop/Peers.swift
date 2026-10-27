import Foundation
import Network

struct Message: Codable {
    var cmd: String
    var key: String?
    var addresses: [String]?
    var ok: Bool?
    var error: String?
}

/// Finds other Macs running DeviceHop via Bonjour and exchanges one JSON line per request.
final class Peers {
    static let serviceType = "_devicehop._tcp"

    let myName: String
    private(set) var peers: [String: NWEndpoint] = [:]
    var handler: ((Message, @escaping (Message) -> Void) -> Void)?
    var onChange: (() -> Void)?

    private var listener: NWListener?
    private var browser: NWBrowser?

    init(name: String) {
        myName = name
    }

    func start() throws {
        let l = try NWListener(using: .tcp)
        l.service = NWListener.Service(name: myName, type: Peers.serviceType)
        l.newConnectionHandler = { [weak self] c in self?.serve(c) }
        l.start(queue: .main)
        listener = l

        let b = NWBrowser(for: .bonjour(type: Peers.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            var found: [String: NWEndpoint] = [:]
            for r in results {
                if case let .service(name, _, _, _) = r.endpoint, name != self.myName {
                    found[name] = r.endpoint
                }
            }
            self.peers = found
            self.onChange?()
        }
        b.start(queue: .main)
        browser = b
    }

    func send(_ msg: Message, to name: String, completion: @escaping (Message?) -> Void) {
        guard let ep = peers[name] else { completion(nil); return }
        let c = NWConnection(to: ep, using: .tcp)
        var finished = false
        let done: (Message?) -> Void = { m in
            if finished { return }
            finished = true
            c.cancel()
            completion(m)
        }
        c.stateUpdateHandler = { state in
            if case .failed = state { done(nil) }
        }
        c.start(queue: .main)
        write(msg, to: c) {
            self.readLine(c) { data in
                done(data.flatMap { try? JSONDecoder().decode(Message.self, from: $0) })
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { done(nil) }
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: .main)
        readLine(c) { [weak self] data in
            guard let self, let handler = self.handler, let data,
                  let msg = try? JSONDecoder().decode(Message.self, from: data) else {
                c.cancel()
                return
            }
            handler(msg) { reply in
                self.write(reply, to: c) { c.cancel() }
            }
        }
    }

    private func write(_ m: Message, to c: NWConnection, then: @escaping () -> Void) {
        guard var d = try? JSONEncoder().encode(m) else { then(); return }
        d.append(0x0A)
        c.send(content: d, completion: .contentProcessed { _ in then() })
    }

    private func readLine(_ c: NWConnection, buffer: Data = Data(), completion: @escaping (Data?) -> Void) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            var buf = buffer
            if let data { buf.append(data) }
            if let i = buf.firstIndex(of: 0x0A) {
                completion(Data(buf[buf.startIndex..<i]))
            } else if isComplete || error != nil || buf.count > 65536 {
                completion(nil)
            } else {
                self.readLine(c, buffer: buf, completion: completion)
            }
        }
    }
}
