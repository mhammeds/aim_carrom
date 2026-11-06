import Foundation
import Network

/// Listens on 127.0.0.1:Link.port for results from the broadcast extension.
final class LinkReceiver: ObservableObject {
    @Published private(set) var latest: AimResult?
    @Published private(set) var lastSeen: Date?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "carrom.link")
    var onResult: ((AimResult) -> Void)?

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.udp
            params.requiredInterfaceType = .loopback
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Link.port)!)
            l.newConnectionHandler = { [weak self] conn in
                conn.start(queue: self?.queue ?? .main)
                self?.receive(on: conn)
            }
            l.start(queue: queue)
            listener = l
        } catch {
            print("listener error", error)
        }
    }

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self = self else { return }
            if let data = data, let r = try? JSONDecoder().decode(AimResult.self, from: data) {
                self.onResult?(r)
                DispatchQueue.main.async {
                    self.latest = r
                    self.lastSeen = Date()
                }
            }
            if error == nil { self.receive(on: conn) }
        }
    }
}
