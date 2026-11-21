import Foundation

/// One update for the laptop viewer, sent as JSON: the camera frame and, for that moment, what the
/// app measured (objects, coordinates, path), heard, said, and asked the AI models.
/// Image points are normalized [x, y] pairs, top-left origin.
nonisolated struct ViewerSnapshot: Encodable, Sendable {
    var time: Double
    /// JPEG (faces blurred), base64; filled in off the main thread.
    var frame = ""
    var mode: String
    var grid: Grid?
    var objects: [Object]
    var path: PathState
    var found: Found?
    var status: Status
    var agent: AgentState
    var spoken: [Line]
    var models: [ModelLog.Call]
    var guidance: String?
    /// Faces in view and who they matched (recognition runs on the phone).
    var faces: [FaceMark] = []

    nonisolated struct FaceMark: Encodable, Sendable {
        var box: [Double]
        var name: String?
        /// Match score against its limit: at or under the limit (and clearly best) = recognized.
        var distance: Float?
        var limit: Float?
        var usable: Bool
    }

    nonisolated struct Grid: Encodable, Sendable {
        var pitch: Double  // degrees below the horizon
        var horizon: Double
        var rings: [Ring]
        var lanes: [Lane]
    }

    /// Points on the floor `meters` away, in every direction ahead.
    nonisolated struct Ring: Encodable, Sendable {
        var meters: Double
        var points: [[Double]]
        var label: [Double]?
    }

    /// The walking lane's edges (and center), on the floor.
    nonisolated struct Lane: Encodable, Sendable {
        var x: Double
        var points: [[Double]]
    }

    nonisolated struct Object: Encodable, Sendable {
        var id: Int
        var label: String
        var box: [Double]  // x, y, width, height
        var meters: Double
        var bearing: Double
        var x: Double
        var z: Double
        var inPath: Bool
        var urgent: Bool
        var closing: Double?
    }

    nonisolated struct PathState: Encodable, Sendable {
        var obstacle: Mark?
        var drop: Mark?
        var clear: Bool
    }

    nonisolated struct Mark: Encodable, Sendable {
        var meters: Double
        var bearing: Double
        var x: Double
        var z: Double
        var at: [Double]?
    }

    /// What Find or guidance last pointed at.
    nonisolated struct Found: Encodable, Sendable {
        var label: String
        var at: [Double]
        var meters: Double?
        var bearing: Double
        var age: Double
    }

    nonisolated struct Status: Encodable, Sendable {
        var fps: Double
        var detectMs: Double
        var depthMs: Double
        var detector: String
        var depth: String
        var walking: Bool
        var heading: Double?
        var beeps: String
        var level: String
        var filtered: Int
        var pipelineMs: Double?
        var thermal: String
    }

    nonisolated struct AgentState: Encodable, Sendable {
        var state: String
        var listening: Bool
        var speaking: Bool
        var working: Bool
        var live: Bool
        var muted: Bool
        var heard: String
        var said: String
        var tools: [Tool]
    }

    nonisolated struct Tool: Encodable, Sendable {
        var time: Double
        var name: String
        var args: String
        var result: String
    }

    /// Something the app said ("agent"), or would have said while the AI was offline ("not spoken").
    nonisolated struct Line: Encodable, Sendable {
        var time: Double
        var text: String
        var priority: String
        var voice: String
    }
}

/// Recent Gemini requests (for the viewer): which model answered which job, and how fast.
nonisolated final class ModelLog: @unchecked Sendable {
    nonisolated struct Call: Encodable, Sendable {
        let time: Double
        let role: String
        let model: String
        /// Until the answer started arriving.
        let ms: Int
        /// HTTP status; 0 = no connection.
        let status: Int
    }

    private let lock = NSLock()
    private var calls: [Call] = []

    func record(_ call: Call) {
        lock.withLock {
            calls.append(call)
            if calls.count > 12 { calls.removeFirst(calls.count - 12) }
        }
    }

    var recent: [Call] { lock.withLock { calls } }
}
