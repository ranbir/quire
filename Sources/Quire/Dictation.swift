import AVFoundation
import AppKit
import QuireCore
import Speech

/// Speech-to-text for the AI instruction box. On macOS 26 it uses SpeechAnalyzer,
/// which runs on-device and works even when Siri and Dictation are turned off;
/// earlier systems fall back to SFSpeechRecognizer, which needs Dictation enabled.
/// Reports the running transcript of one session and stops after a pause in speech.
final class Dictation {
    var onTranscript: ((String) -> Void)?
    var onListeningChanged: ((Bool) -> Void)?
    var onStatus: ((String) -> Void)?
    var onError: ((String) -> Void)?
    /// Extra vocabulary, e.g. identifiers from the document, so names transcribe correctly.
    var contextualStrings: [String] = []

    private(set) var isListening = false
    private var starting = false
    private let engine = AVAudioEngine()
    private var transcript = ""
    private var silenceTimer: Timer?
    private var backend: DictationBackend?

    /// How long a pause ends dictation, and how long to wait for the first word.
    private let pauseToStop: TimeInterval = 2.0
    private let waitForSpeech: TimeInterval = 8.0

    func toggle() { isListening || starting ? stop() : start() }

    func start() {
        guard !isListening, !starting else { return }
        starting = true
        requestMicrophone { [weak self] problem in
            guard let self else { return }
            if let problem { self.starting = false; self.onError?(problem); return }
            Task { @MainActor in await self.begin() }
        }
    }

    /// Stops listening; the final transcript arrives shortly after.
    func stop() {
        starting = false
        guard isListening else { return }
        endAudio()
        backend?.finish()
    }

    /// Stops immediately and discards anything still being recognized.
    func cancel() {
        starting = false
        endAudio()
        backend?.cancel()
        backend = nil
    }

    // MARK: Private

    private func requestMicrophone(_ done: @escaping (String?) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(nil)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { done(ok ? nil : Self.deniedMessage("Microphone")) }
            }
        default: done(Self.deniedMessage("Microphone"))
        }
    }

    static func deniedMessage(_ what: String) -> String {
        "Quire doesn’t have \(what) access. Turn it on in System Settings ▸ Privacy & Security ▸ \(what)."
    }

    @MainActor private func begin() async {
        transcript = ""
        let backend: DictationBackend
        if #available(macOS 26.0, *) { backend = AnalyzerBackend() } else { backend = RecognizerBackend() }
        self.backend = backend
        backend.onText = { [weak self] text in
            DispatchQueue.main.async {
                guard let self, self.backend === backend else { return }
                self.transcript = text
                self.onTranscript?(text)
                if self.isListening { self.armSilenceTimer(self.pauseToStop) }
            }
        }
        backend.onEnd = { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.backend === backend else { return }
                self.endAudio()
                self.backend = nil
                if let error, self.transcript.isEmpty { self.onError?(error) }
            }
        }
        do {
            let input = engine.inputNode
            let micFormat = input.outputFormat(forBus: 0)
            guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else { throw AIError("No microphone was found.") }
            try await backend.prepare(micFormat: micFormat, contextualStrings: contextualStrings) { [weak self] status in
                DispatchQueue.main.async { self?.onStatus?(status) }
            }
            guard starting else { backend.cancel(); self.backend = nil; return }   // stopped while preparing
            input.installTap(onBus: 0, bufferSize: 2048, format: micFormat) { buffer, _ in backend.append(buffer) }
            engine.prepare()
            try engine.start()
            starting = false
            isListening = true
            onListeningChanged?(true)
            armSilenceTimer(waitForSpeech)
        } catch {
            starting = false
            backend.cancel()
            self.backend = nil
            onError?(error.localizedDescription)
        }
    }

    private func endAudio() {
        silenceTimer?.invalidate()
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        if isListening { isListening = false; onListeningChanged?(false) }
    }

    private func armSilenceTimer(_ interval: TimeInterval) {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self, self.isListening else { return }
            if self.transcript.isEmpty { self.cancel(); self.onError?("Didn’t hear anything — click the mic and speak.") }
            else { self.stop() }
        }
    }
}

/// One recognition session. `append` is called on the audio thread.
private class DictationBackend {
    var onText: ((String) -> Void)?
    var onEnd: ((String?) -> Void)?
    func prepare(micFormat: AVAudioFormat, contextualStrings: [String], status: @escaping (String) -> Void) async throws {}
    func append(_ buffer: AVAudioPCMBuffer) {}
    func finish() {}
    func cancel() {}
}

// MARK: - macOS 26: SpeechAnalyzer

@available(macOS 26.0, *)
private final class AnalyzerBackend: DictationBackend {
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var results: Task<Void, Never>?

    override func prepare(micFormat: AVAudioFormat, contextualStrings: [String], status: @escaping (String) -> Void) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            throw AIError("On-device speech recognition doesn’t support your language (\(Locale.current.identifier)).")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            status("Downloading the speech model for \(locale.identifier) (one time)…")
            try await install.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: micFormat) else {
            throw AIError("The speech recognizer can’t use this microphone’s audio format.")
        }
        analyzerFormat = format
        converter = format == micFormat ? nil : AVAudioConverter(from: micFormat, to: format)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(contextualStrings.prefix(100))
            try? await analyzer.setContext(context)
        }

        results = Task { [weak self] in
            var finalized = ""
            do {
                for try await r in transcriber.results {
                    let piece = String(r.text.characters)
                    if r.isFinal {
                        finalized = Self.join(finalized, piece)
                        self?.onText?(finalized)
                    } else {
                        self?.onText?(Self.join(finalized, piece))
                    }
                }
                self?.onEnd?(nil)
            } catch is CancellationError {
                self?.onEnd?(nil)
            } catch {
                self?.onEnd?(error.localizedDescription)
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// Recognized segments don't always carry the space between them.
    private static func join(_ a: String, _ b: String) -> String {
        let b = b.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a.hasSuffix(" ") ? a + b : a + " " + b
    }

    override func append(_ buffer: AVAudioPCMBuffer) {
        guard let input else { return }
        guard let converter, let format = analyzerFormat else { input.yield(AnalyzerInput(buffer: buffer)); return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 { input.yield(AnalyzerInput(buffer: out)) }
    }

    override func finish() {
        input?.finish()
        input = nil
        let analyzer = analyzer
        Task { try? await analyzer?.finalizeAndFinishThroughEndOfInput() }
    }

    override func cancel() {
        input?.finish()
        input = nil
        results?.cancel()
        let analyzer = analyzer
        Task { await analyzer?.cancelAndFinishNow() }
    }
}

// MARK: - macOS 13–15: SFSpeechRecognizer

private final class RecognizerBackend: DictationBackend {
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    override func prepare(micFormat: AVAudioFormat, contextualStrings: [String], status: @escaping (String) -> Void) async throws {
        let authorized: Bool = await withCheckedContinuation { c in
            if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
            } else {
                c.resume(returning: SFSpeechRecognizer.authorizationStatus() == .authorized)
            }
        }
        guard authorized else { throw AIError(Dictation.deniedMessage("Speech Recognition")) }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw AIError("Speech recognition isn’t available. On this version of macOS it needs Dictation turned on in System Settings ▸ Keyboard.")
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        req.taskHint = .dictation
        req.contextualStrings = Array(contextualStrings.prefix(100))
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            if let result {
                self?.onText?(result.bestTranscription.formattedString)
                if result.isFinal { self?.onEnd?(nil) }
            }
            if let error {
                let code = (error as NSError).code
                // 1110: no speech detected; 216/301: cancelled.
                self?.onEnd?([216, 301].contains(code) ? nil : code == 1110 ? "Didn’t catch that — try again." : error.localizedDescription)
            }
        }
    }

    override func append(_ buffer: AVAudioPCMBuffer) { request?.append(buffer) }
    override func finish() { request?.endAudio() }
    override func cancel() { task?.cancel() }
}
