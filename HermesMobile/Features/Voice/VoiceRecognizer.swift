import AVFoundation
import Speech

/// On-device speech recognition for voice mode, fed the same mic buffers as the
/// endpointer (the file-fed mic's too). It gives the live caption in both modes
/// and the utterance text when Settings → Recognition is On-device.
/// `requiresOnDeviceRecognition` is always set: audio never goes to Apple.
@MainActor final class VoiceRecognizer {
    enum Availability: Equatable { case ready, denied, unavailable }

    /// Partial text of the utterance in progress.
    var onPartial: ((String) -> Void)?
    private let recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latest = ""
    private var failed = false
    private var final: CheckedContinuation<String, Never>?
    private(set) var availability: Availability = .unavailable

    init(locale: Locale = .current) {
        recognizer = SFSpeechRecognizer(locale: locale)
    }

    /// Asks for speech-recognition permission (only when voice mode starts) and
    /// reports whether on-device recognition works for this locale.
    func prepare() async -> Availability {
        let status: SFSpeechRecognizerAuthorizationStatus
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        } else { status = SFSpeechRecognizer.authorizationStatus() }
        guard status == .authorized else { availability = .denied; return availability }
        guard let recognizer, recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
            availability = .unavailable; return availability
        }
        availability = .ready
        return availability
    }

    /// A new utterance started: open a recognition request.
    func begin() {
        guard availability == .ready, let recognizer else { return }
        cancel()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        self.request = request
        latest = ""
        failed = false
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                guard let self else { return }
                if let text { self.latest = text; self.onPartial?(text) }
                if failed { self.failed = true }
                if isFinal || failed { self.resolve() }
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) { request?.append(buffer) }

    /// The utterance ended: the final text, or nil when on-device recognition
    /// failed or produced nothing (the caller then asks the server), waiting at
    /// most `timeout` for the recognizer to finish.
    func finish(timeout: Duration = .seconds(3)) async -> String? {
        guard request != nil else { return nil }
        request?.endAudio()
        let text = await withCheckedContinuation { continuation in
            final = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resolve()
            }
        }
        request = nil
        task = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return failed || trimmed.isEmpty ? nil : trimmed
    }

    /// Speech too short to send: drop it.
    func cancel() {
        task?.cancel()
        task = nil
        request = nil
        resolve()
    }

    private func resolve() {
        let continuation = final
        final = nil
        continuation?.resume(returning: latest)
    }
}
