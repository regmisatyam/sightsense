import CoreGraphics
import Foundation
import QuartzCore

/// The agent's tools: what the AI can do in the app (declared in `AgentProtocol.tools`).
/// Each returns what the agent should hear; the agent then tells the person in its own words.
/// None of them speak themselves, except guidance updates, which come later.
extension AppModel {
    func runTool(_ name: String, _ args: [String: String]) async -> String {
        switch name {
        case "get_obstacles":
            return obstaclesReport()
        case "find":
            return await findForAgent(args["target"] ?? "")
        case "guide_to":
            return startGuidance(args["target"] ?? "the way out", announce: false)
        case "stop_guidance":
            wayFinder.stop()
            explorer.stopGuiding()
            return "Guidance stopped."
        case "read_text":
            return await readForAgent()
        case "look_closely":
            return await lookClosely(args["question"] ?? "What details can you see?")
        case "where_am_i":
            return await explorer.whereAmIText()
        case "nearby_places":
            return args["direction"] == "ahead" ? await explorer.aheadOfMeText() : await explorer.aroundMeText()
        case "remember_person":
            return await people.remember(args["name"] ?? "", latestFrame: { [weak self] in self?.latestFrame })
        case "forget_person":
            return await people.forget(args["name"] ?? "")
        case "who_is_here":
            return whoIsHere()
        case "set_mode":
            return setModeForAgent(args["mode"] ?? "")
        case "set_beeps":
            let on = args["on"] == "true"
            settings.beepMode = on ? .path : .off
            return on ? "Beeps are on; they play only while walking." : "Beeps are off."
        case "set_announcements":
            return shiftAnnouncements(by: args["amount"] == "fewer" ? -1 : 1)
        default:
            return "There's no tool called \(name)."
        }
    }

    /// What the phone's own sensors measured just now.
    private func obstaclesReport() -> String {
        if fastLoop.detectorSource == .loading { return "The phone's sensors are still starting up." }
        let measured = fastLoop.measurements()
        var report = measured.isEmpty
            ? "The phone measures nothing in front of them within about 5 meters right now. It can still miss things, so don't call the way clear."
            : "Measured just now: " + measured.joined(separator: "; ") + "."
        if let target = wayFinder.target { report += " The app is guiding them to \(target)." }
        return report
    }

    private func findForAgent(_ target: String) async -> String {
        guard let frame = latestFrame else { return "The camera isn't ready yet." }
        guard let found = try? await describer.find(target, in: frame) else {
            return "Finding didn't work: the vision service didn't answer."
        }
        guard let first = found.first else { return "No \(target) is in view of the camera right now." }
        return locate(first, count: found.count, target: target, in: frame)
    }

    /// "Exit door, slightly left, 8 steps. Follow the sound." — and points the beacon at it.
    func locate(_ thing: FoundThing, count: Int, target: String, in frame: Frame) -> String {
        let bearing = atan((thing.x - 0.5) * 2 * tan(frame.camera.horizontalFOV / 2)) * 180 / .pi
        let name = thing.label.isEmpty ? target : thing.label
        var sentence = name.prefix(1).uppercased() + name.dropFirst() + ", " + SpokenPosition.direction(bearing)
        let meters = fastLoop.distance(to: CGPoint(x: thing.x, y: thing.y))
        if let meters {
            sentence += ", " + SpokenPosition.distance(meters, units: settings.units)
        }
        lastSighting = Sighting(label: name, x: thing.x, y: thing.y, meters: meters, bearing: bearing, time: CACurrentMediaTime())
        sentence += "."
        if count > 1 { sentence += " I see \(count) of them; this is the nearest." }
        if explorer.guide(toward: name, relativeBearing: bearing) { sentence += " Follow the sound." }
        return sentence
    }

    private func readForAgent() async -> String {
        guard let frame = latestFrame else { return "The camera isn't ready yet." }
        let text = await reader.readOnce(frame)
        if !text.isEmpty {
            return "The phone read this text, exactly:\n\(text)\nRead it to them; translate it into their language if it's in another one."
        }
        let seen = await ask(.readText, about: frame)
        return seen.isEmpty
            ? "No readable text in view. Ask them to point the phone at the text and hold still, then try again."
            : "The reading model sees: \(seen)"
    }

    private func lookClosely(_ question: String) async -> String {
        guard let frame = latestFrame else { return "The camera isn't ready yet." }
        let style = SceneDescriber.Style.answer(question: question, measured: fastLoop.measurements(),
                                                places: explorer.placeSummaries(), units: settings.units, deep: true)
        let answer = await ask(style, about: frame)
        return answer.isEmpty ? "The careful look didn't work this time: the vision service didn't answer." : answer
    }

    /// A REST vision model's whole answer ("" if it failed).
    private func ask(_ style: SceneDescriber.Style, about frame: Frame) async -> String {
        var sentences: [String] = []
        do {
            for try await sentence in try await describer.describe(frame, style: style) { sentences.append(sentence) }
        } catch {
            return ""
        }
        return sentences.joined(separator: " ")
    }

    private func setModeForAgent(_ name: String) -> String {
        let modes: [String: AppMode] = ["navigation": .navigate, "calm": .calm, "live": .live]
        guard let newMode = modes[name] else { return "There's no \(name) mode." }
        setMode(newMode, announce: false)
        switch newMode {
        case .navigate: return "Navigation mode is on: quiet unless something is in the way."
        case .calm: return "Calm mode is on: gentle narration while nothing is near."
        case .live: return "Live mode is on: the microphone stays open, so they can just talk."
        }
    }
}
