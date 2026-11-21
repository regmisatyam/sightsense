import Foundation
import NaturalLanguage
import Observation
import QuartzCore
import Translation

/// Read: guides the camera onto text by voice, reads it once it's in view and steady, and
/// translates it into the user's language when needed. Translation runs through SwiftUI's
/// `.translationTask`, which watches `translationConfig`.
@Observable
final class TextReader {
    private(set) var translationConfig: TranslationSession.Configuration?

    @ObservationIgnored private let speech: SpeechQueue
    @ObservationIgnored private let recognizer = TextRecognizer()
    @ObservationIgnored private var pending: (text: String, language: Locale.Language)?
    /// Called with the frame when on-device OCR can't read anything, so the AI can try.
    @ObservationIgnored var onNoText: ((Frame) -> Void)?
    /// Called with the text read; returns true if it was handled (the AI agent reads it out and
    /// translates it). Otherwise it's read here, translated on the phone if needed.
    @ObservationIgnored var onText: ((String) -> Bool)?

    init(speech: SpeechQueue) {
        self.speech = speech
    }

    /// Coaches the user until the text is fully in view and the phone is steady, then reads it.
    /// After 7 s it reads whatever text it can see; after 10 s with none it gives up.
    func read(latestFrame: () -> Frame?) async {
        let start = CACurrentMediaTime()
        var lastHint: AimingHint?
        var lastSpokenAt = 0.0
        var foundText = false

        while !Task.isCancelled {
            guard let frame = latestFrame() else {
                speech.say("The camera isn't ready yet.")
                return
            }
            let boxes = await recognizer.locate(frame)
            let hint = AimingCoach.hint(for: boxes, steady: frame.motion?.isSteady ?? true)
            let elapsed = CACurrentMediaTime() - start

            if !boxes.isEmpty && !foundText {
                foundText = true
                Haptics.tap()  // felt the moment text comes into view
            }
            if hint == .ready || (elapsed > 7 && !boxes.isEmpty) {
                await readText(in: frame)
                return
            }
            if elapsed > 10 {
                if let onNoText { onNoText(frame) } else { speech.say("No text found.") }
                return
            }

            let now = CACurrentMediaTime()
            if let phrase = hint.phrase, now - lastSpokenAt > 1.5, hint != lastHint || now - lastSpokenAt > 3 {
                speech.cancelNonUrgent()
                speech.say(phrase)
                lastSpokenAt = now
                lastHint = hint
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// The text in one frame, read on the phone at the best accuracy ("" if none). For the AI agent.
    func readOnce(_ frame: Frame) async -> String {
        await recognizer.read(frame).joined(separator: "\n")
    }

    private func readText(in frame: Frame) async {
        let lines = await recognizer.read(frame)
        speech.cancelNonUrgent()
        guard !lines.isEmpty else {
            if let onNoText { onNoText(frame) } else { speech.say("I couldn't make out the text. Try again.") }
            return
        }
        let text = lines.joined(separator: "\n")
        if onText?(text) == true { return }
        guard let source = Self.foreignLanguage(of: text) else {
            speech.say(text)
            return
        }

        let name = Self.name(of: source)
        switch await LanguageAvailability().status(from: source, to: Locale.current.language) {
        case .installed:
            speech.say("Translating from \(name).")
        case .supported:
            speech.say("Translating from \(name) needs a one-time download. A prompt is on screen; ask someone to help if needed.")
        case .unsupported:
            speech.say("I can't translate \(name). Here it is as written.")
            speech.say(text)
            return
        @unknown default:
            speech.say("Translating from \(name).")
        }

        pending = (text, source)
        let config = TranslationSession.Configuration(source: source, target: nil)  // nil = user's language
        if translationConfig == config {
            translationConfig?.invalidate()  // same languages again: re-run the task
        } else {
            translationConfig = config
        }
    }

    /// Called by `.translationTask` with a session for `translationConfig`.
    func translatePending(using session: TranslationSession) async {
        guard let pending else { return }
        self.pending = nil
        // TranslationSession isn't Sendable; we use it once, serially, inside the task
        // that SwiftUI gave it to us for, which is Apple's documented usage.
        nonisolated(unsafe) let session = session
        do {
            let response = try await session.translate(pending.text)
            speech.say(response.targetText)
        } catch {
            speech.say("I couldn't translate that. Here it is in \(Self.name(of: pending.language)).")
            speech.say(pending.text)
        }
    }

    /// The text's language, if it is confidently not the user's own; otherwise nil.
    private static func foreignLanguage(of text: String) -> Locale.Language? {
        guard text.count >= 12 else { return nil }  // too short to judge reliably
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value >= 0.6 else { return nil }
        let detected = Locale.Language(identifier: best.key.rawValue)
        return detected.languageCode == Locale.current.language.languageCode ? nil : detected
    }

    private static func name(of language: Locale.Language) -> String {
        let code = language.languageCode?.identifier ?? ""
        return Locale.current.localizedString(forLanguageCode: code) ?? "another language"
    }
}
