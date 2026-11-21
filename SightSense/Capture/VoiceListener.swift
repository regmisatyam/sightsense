import AVFoundation
import Speech

/// Hears one spoken question or command. Recognition stays on the phone when the language
/// supports it. Stops about 1.5 s after the person stops talking, when `finish()` is called
/// (e.g. the button is released), or after 15 s.
///
/// Everything here is `nonisolated`: the microphone tap and the recognizer call back on their
/// own threads, and the project otherwise defaults to the main actor.
nonisolated final class VoiceListener: @unchecked Sendable {
    private let lock = NSLock()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<String, Never>?
    private var text = ""
    private var startedAt = Date()
    private var changedAt = Date()

    /// Asks for speech recognition and microphone access (once; later calls return the answer).
    static func requestPermission() async -> Bool {
        let speech = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    /// What was said ("" if nothing).
    @concurrent func listen() async -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else { return "" }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return ""
        }

        return await withCheckedContinuation { continuation in
            lock.withLock {
                self.continuation = continuation
                self.request = request
                text = ""
                startedAt = Date()
                changedAt = Date()
            }
            let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                if let result { heard(result.bestTranscription.formattedString) }
                if error != nil || result?.isFinal == true { complete() }
            }
            lock.withLock { self.task = task }
            watchForSilence()
        }
    }

    /// Stop listening now, but keep the words already spoken (waits briefly for the last ones).
    func finish() {
        let request = lock.withLock { continuation == nil ? nil : self.request }
        guard let request else { return }
        stopMicrophone()
        request.endAudio()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in self?.complete() }
    }

    private func heard(_ newText: String) {
        lock.withLock {
            if newText != text {
                text = newText
                changedAt = Date()
            }
        }
    }

    private func watchForSilence() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            let state = lock.withLock { () -> (listening: Bool, done: Bool) in
                guard continuation != nil else { return (false, false) }
                let quiet = Date().timeIntervalSince(changedAt)
                let total = Date().timeIntervalSince(startedAt)
                return (true, (!text.isEmpty && quiet > 1.5) || (text.isEmpty && total > 7) || total > 15)
            }
            if state.done {
                complete()
            } else if state.listening {
                watchForSilence()
            }
        }
    }

    private func complete() {
        let finished = lock.withLock { () -> (CheckedContinuation<String, Never>, String)? in
            guard let continuation else { return nil }
            self.continuation = nil
            task?.cancel()
            task = nil
            request = nil
            return (continuation, text)
        }
        guard let (continuation, text) = finished else { return }
        stopMicrophone()
        continuation.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func stopMicrophone() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }
}
