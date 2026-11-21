import Foundation
import Network

/// A tiny web server on the local network for the laptop viewer (Apple's Network framework only):
/// - `GET /` → the viewer page (viewer.html in the app);
/// - `GET /events` → a Server-Sent Events stream: one JSON snapshot (camera frame + what the
///   app measured and said) per message. Browsers reconnect to it on their own.
/// A laptop that falls behind skips frames instead of building up a delay.
/// It also advertises itself with Bonjour, which is what makes iOS ask for local network access.
nonisolated final class ViewerServer: @unchecked Sendable {
    static let port: UInt16 = 8080
    static let bonjourType = "_sightsense._tcp"  // also listed in Info.plist (NSBonjourServices)

    nonisolated enum Status: Sendable, Equatable {
        case starting, ready
        /// Settings › Privacy & Security › Local Network › SightSense is off.
        case noLocalNetworkAccess
        case failed(String)
    }

    /// A way to reach the phone, e.g. ("Wi-Fi", "172.16.248.246").
    nonisolated struct Address: Sendable, Hashable {
        let label: String
        let host: String
        var url: String { "http://\(host):\(ViewerServer.port)" }
    }

    private let queue = DispatchQueue(label: "SightSense.viewer")
    private let lock = NSLock()
    private let page: Data
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]  // only touched on `queue`
    private var watching = 0
    private var state = Status.starting

    /// One laptop's open event stream.
    private final class Client: @unchecked Sendable {
        let connection: NWConnection
        var sending = false
        init(_ connection: NWConnection) { self.connection = connection }
    }

    init(page: Data) {
        self.page = page
    }

    /// How many laptops are watching right now.
    var viewerCount: Int { lock.withLock { watching } }
    var status: Status { lock.withLock { state } }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!)
        listener.service = NWListener.Service(name: "SightSense", type: Self.bonjourType)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state) }
        listener.start(queue: queue)
        lock.withLock { self.listener = listener }
    }

    func stop() {
        let listener = lock.withLock { () -> NWListener? in
            defer { self.listener = nil }
            return self.listener
        }
        listener?.cancel()
        queue.async { [self] in
            clients.values.forEach { $0.connection.cancel() }
            clients.removeAll()
            updateCount()
        }
    }

    /// Sends one snapshot (JSON, no newlines) to every laptop that's ready for it.
    func broadcast(_ json: Data) {
        queue.async { [self] in
            let event = Data("data: ".utf8) + json + Data("\n\n".utf8)
            for client in clients.values where !client.sending {
                client.sending = true
                client.connection.send(content: event, completion: .contentProcessed { [weak self] error in
                    client.sending = false
                    if error != nil { self?.drop(client) }
                })
            }
        }
    }

    private func listenerChanged(_ newState: NWListener.State) {
        let status: Status? = switch newState {
        case .ready: .ready
        case .waiting(let error), .failed(let error): Self.isPolicyDenied(error) ? .noLocalNetworkAccess : .failed("\(error)")
        default: nil
        }
        guard let status else { return }
        if status != .ready { print("Viewer server: \(status)") }
        lock.withLock { state = status }
    }

    /// Local network access refused (kDNSServiceErr_PolicyDenied).
    private static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == -65570 }
        return false
    }

    // MARK: - Requests

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }
            switch Self.requestPath(data) {
            case "/", "/index.html":
                respond(connection, status: "200 OK", type: "text/html; charset=utf-8", body: page)
            case "/events":
                subscribe(connection)
            default:
                respond(connection, status: "404 Not Found", type: "text/plain", body: Data("Not found".utf8))
            }
        }
    }

    /// The path of an HTTP GET request ("/events"), or nil if it isn't one.
    static func requestPath(_ request: Data) -> String? {
        guard let text = String(data: request.prefix(2048), encoding: .utf8),
              let line = text.split(separator: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return parts[1].split(separator: "?").first.map(String.init) ?? "/"
    }

    private func respond(_ connection: NWConnection, status: String, type: String, body: Data) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func subscribe(_ connection: NWConnection) {
        let client = Client(connection)
        clients[ObjectIdentifier(client)] = client
        updateCount()
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\n"
            + "Connection: keep-alive\r\n\r\nretry: 1000\n\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            if error != nil { self?.drop(client) }
        })
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.drop(client)
            default: break
            }
        }
        watchForClose(client)
    }

    /// The browser closing the page ends the stream.
    private func watchForClose(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                self?.drop(client)
            } else {
                self?.watchForClose(client)
            }
        }
    }

    private func drop(_ client: Client) {
        guard clients.removeValue(forKey: ObjectIdentifier(client)) != nil else { return }
        client.connection.cancel()
        updateCount()
    }

    private func updateCount() {
        let count = clients.count
        lock.withLock { watching = count }
    }

    // MARK: - Address

    /// The phone's addresses a laptop can use: Wi-Fi first, then its Personal Hotspot (Wi-Fi or USB).
    static func localAddresses() -> [Address] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var wifi: [Address] = []
        var other: [Address] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  interface.ifa_flags & UInt32(IFF_UP) != 0, interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }  // not cellular
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            guard !text.hasPrefix("169.254.") else { continue }  // self-assigned: no one can reach it
            if name == "en0" {
                wifi.append(Address(label: "Wi-Fi", host: text))
            } else {
                other.append(Address(label: name.hasPrefix("bridge") ? "Personal Hotspot (Wi-Fi or USB)" : "Network", host: text))
            }
        }
        return wifi + other
    }
}
