import Foundation

/// Talks to the Gemini API. For each request it tries the job's models in order: if a model
/// rejects the thinking setting it's retried without it, and if a model is unavailable or
/// overloaded the next one answers. The key is either built in or kept on your proxy server.
actor GeminiClient {
    nonisolated enum Failure: Error {
        case noKey, offline, badResponse
    }

    nonisolated let isConfigured: Bool
    nonisolated let models: GeminiModels
    /// WebSocket address for Gemini Live (needs the key in the app; the proxy doesn't relay Live).
    nonisolated let liveEndpoint: URL?
    /// Recent requests, for the laptop viewer.
    nonisolated let log = ModelLog()
    private let apiKey: String
    private let proxyHost: String
    private let appToken: String
    /// Models that turned out not to accept a thinking level.
    private var noThinking: Set<String> = []

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        func setting(_ key: String) -> String {
            let text = (info[key] as? String ?? "").trimmingCharacters(in: .whitespaces)
            return text.hasPrefix("$(") ? "" : text
        }
        apiKey = setting("GeminiAPIKey")
        proxyHost = setting("GeminiProxyHost")
        appToken = setting("GeminiAppToken")
        models = GeminiModels(info: info)
        isConfigured = !apiKey.isEmpty || !proxyHost.isEmpty
        liveEndpoint = apiKey.isEmpty ? nil : URL(string:
            "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(apiKey)")
    }

    /// Streams the answer as server-sent events from the first model that responds.
    func stream(_ role: GeminiModels.Role, parts: [[String: Any]], config: [String: Any] = [:]) async throws -> URLSession.AsyncBytes {
        try await firstAnswering(role, parts: parts, extra: config) { request in
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return (status, bytes, "") }
            var body = ""
            for try await line in bytes.lines { body += line }
            return (status, nil, body)
        }
    }

    /// The whole JSON reply from the first model that responds.
    func generate(_ role: GeminiModels.Role, parts: [[String: Any]], config: [String: Any] = [:]) async throws -> Data {
        try await firstAnswering(role, parts: parts, extra: config, streaming: false) { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (status, status == 200 ? data : nil, String(decoding: data, as: UTF8.self))
        }
    }

    private func firstAnswering<Payload>(
        _ role: GeminiModels.Role, parts: [[String: Any]], extra: [String: Any], streaming: Bool = true,
        send: (URLRequest) async throws -> (status: Int, payload: Payload?, error: String)
    ) async throws -> Payload {
        guard isConfigured else { throw Failure.noKey }
        for choice in models.chain(for: role) {
            var thinking = noThinking.contains(choice.model) ? nil : choice.thinking
            while true {
                let request = try makeRequest(model: choice.model, streaming: streaming, parts: parts,
                                              extra: extra, thinking: thinking)
                let result: (status: Int, payload: Payload?, error: String)
                let started = Date()
                func record(_ status: Int) {
                    log.record(.init(time: Date().timeIntervalSince1970, role: role.rawValue, model: choice.model,
                                     ms: Int(Date().timeIntervalSince(started) * 1000), status: status))
                }
                do {
                    result = try await send(request)
                } catch {
                    record(0)
                    throw Failure.offline  // another model won't help without a connection
                }
                record(result.status)
                if let payload = result.payload { return payload }
                print("Gemini \(choice.model) → \(result.status): \(result.error.prefix(300))")
                if result.status == 400, thinking != nil {
                    noThinking.insert(choice.model)  // retry this model without the thinking setting
                    thinking = nil
                    continue
                }
                break  // try the next model
            }
        }
        throw Failure.badResponse
    }

    private func makeRequest(model: String, streaming: Bool, parts: [[String: Any]],
                             extra: [String: Any], thinking: String?) throws -> URLRequest {
        var config = extra
        if let thinking { config["thinkingConfig"] = ["thinkingLevel": thinking] }
        var body: [String: Any] = ["contents": [["parts": parts]]]
        if !config.isEmpty { body["generationConfig"] = config }

        let host = proxyHost.isEmpty ? "generativelanguage.googleapis.com" : proxyHost
        let method = streaming ? "streamGenerateContent?alt=sse" : "generateContent"
        var request = URLRequest(url: URL(string: "https://\(host)/v1beta/models/\(model):\(method)")!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if proxyHost.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        } else {
            request.setValue(appToken, forHTTPHeaderField: "x-app-token")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

/// The parts of a Gemini reply SightSense uses.
nonisolated struct GeminiReply: Decodable {
    nonisolated struct Candidate: Decodable { let content: Content? }
    nonisolated struct Content: Decodable { let parts: [Part]? }
    nonisolated struct Part: Decodable { let text: String? }
    let candidates: [Candidate]?

    var text: String {
        candidates?.first?.content?.parts?.compactMap(\.text).joined() ?? ""
    }
}
