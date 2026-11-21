import Foundation
import Observation
import QuartzCore

/// The laptop viewer (Settings › Testing › Laptop viewer): serves a CCTV-style page on the local
/// network and, while a laptop is watching, sends it about 8 snapshots a second. Nothing is
/// encoded or sent when no one is watching.
@Observable
final class ViewerFeed {
    private(set) var isOn = false
    /// Where a laptop can open the page (kept up to date while on): Wi-Fi, Personal Hotspot.
    private(set) var addresses: [ViewerServer.Address] = []
    private(set) var status = ViewerServer.Status.starting
    private(set) var watching = 0

    @ObservationIgnored private var server: ViewerServer?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var lastSentAt: CFTimeInterval = 0
    @ObservationIgnored private var sending = false
    /// The corners' recent history.
    @ObservationIgnored private(set) var spoken: [ViewerSnapshot.Line] = []
    @ObservationIgnored private(set) var tools: [ViewerSnapshot.Tool] = []

    func setOn(_ on: Bool) {
        if on, !isOn {
            guard let url = Bundle.main.url(forResource: "viewer", withExtension: "html"),
                  let page = try? Data(contentsOf: url) else {
                print("Viewer: viewer.html is missing from the app")
                return
            }
            let server = ViewerServer(page: page)
            do {
                try server.start()
            } catch {
                print("Viewer: couldn't start (\(error))")
                return
            }
            self.server = server
            isOn = true
            refresh()
            print("Laptop viewer: \(addresses.map(\.url).joined(separator: " or ").isEmpty ? "connect to Wi-Fi" : addresses.map(\.url).joined(separator: " or "))")
            // Addresses change (another network, Personal Hotspot turned on); so do status and viewers.
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    self?.refresh()
                }
            }
        } else if !on, isOn {
            monitor?.cancel()
            monitor = nil
            server?.stop()
            server = nil
            isOn = false
            addresses = []
            watching = 0
        }
    }

    func refresh() {
        guard let server else { return }
        let latest = ViewerServer.localAddresses()
        if latest != addresses { addresses = latest }
        if server.status != status { status = server.status }
        if server.viewerCount != watching { watching = server.viewerCount }
    }

    /// True when a laptop is watching and it's time for the next snapshot (about 8 a second).
    var wantsSnapshot: Bool {
        guard let server, !sending, server.viewerCount > 0 else { return false }
        return CACurrentMediaTime() - lastSentAt >= 0.12
    }

    /// Encodes the frame (faces blurred) and the snapshot off the main thread, then sends them.
    func publish(_ snapshot: ViewerSnapshot, frame: Frame) {
        guard let server, wantsSnapshot else { return }
        lastSentAt = CACurrentMediaTime()
        sending = true
        Task.detached { [weak self] in
            var snapshot = snapshot
            snapshot.frame = FrameImage.jpeg(frame, maxSide: 640, quality: 0.5, blurFaces: true)?.base64EncodedString() ?? ""
            if let json = try? JSONEncoder().encode(snapshot) { server.broadcast(json) }
            await MainActor.run { self?.sending = false }
        }
    }

    func logSpeech(_ text: String, priority: SpeechPriority, spoken wasSpoken: Bool) {
        guard isOn else { return }
        let name = switch priority {
        case .urgent: "urgent"
        case .normal: "normal"
        case .ambient: "ambient"
        }
        append(&spoken, ViewerSnapshot.Line(time: Date().timeIntervalSince1970, text: text, priority: name,
                                            voice: wasSpoken ? "agent" : "not spoken"))
    }

    func logTool(_ name: String, args: [String: String], result: String) {
        guard isOn else { return }
        let arguments = args.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        append(&tools, ViewerSnapshot.Tool(time: Date().timeIntervalSince1970, name: name, args: arguments,
                                           result: String(result.prefix(240))))
    }

    private func append<Item>(_ list: inout [Item], _ item: Item) {
        list.append(item)
        if list.count > 10 { list.removeFirst(list.count - 10) }
    }
}
