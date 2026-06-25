//
//  SpeechService.swift
//  DirectorSidecar
//
//  Native STT service port for ADR 0005. The on-device path stays in-process
//  (SFSpeechRecognizer on all supported macOS versions, SpeechAnalyzer when the
//  runtime and SDK allow it). Hosted STT still mints temporary tokens through
//  the Worker; provider API keys never belong in the app.
//

import AVFoundation
import Foundation
import Speech

enum SpeechService {
    static let defaultExpiresInSeconds = 60
    static let minExpiresInSeconds = 1
    static let maxExpiresInSeconds = 600

    enum OnDeviceEngine: Int, Sendable, Equatable {
        case sfSpeechRecognizer = 1
        case speechAnalyzer = 2
    }

    enum SttErrorKind: String, Codable, Sendable, Equatable, CaseIterable {
        case micPermission = "mic-permission"
        case startFailed = "start-failed"
        case network
        case providerUnavailable = "provider-unavailable"
        case aborted
    }

    enum PermissionState: String, Codable, Sendable, Equatable {
        case granted
        case denied
        case notDetermined = "not-determined"
        case restricted
        case unknown
    }

    struct SttError: Codable, Sendable, Equatable {
        let kind: SttErrorKind
        let message: String
        let permissionState: PermissionState?

        init(kind: SttErrorKind, message: String, permissionState: PermissionState? = nil) {
            self.kind = kind
            self.message = message
            self.permissionState = permissionState
        }
    }

    enum Event: Sendable, Equatable {
        case ready
        case partial(text: String, confidence: Double, latencyMs: Double, receivedAt: Double)
        case final(text: String, confidence: Double, latencyMs: Double, receivedAt: Double)
        case error(SttError, receivedAt: Double)
    }

    struct StreamingToken: Codable, Sendable, Equatable {
        let token: String
        let expiresInSeconds: Int
    }

    struct WorkerTokenRequest: Sendable, Equatable {
        let url: URL
        let authorization: String
    }

    struct TokenWorkerResponse: Decodable, Sendable, Equatable {
        let token: String
        let expiresInSeconds: Int
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case invalidConfiguration(String)
        case missingCredentials(String)
        case providerUnavailable(String)

        var description: String {
            switch self {
            case .invalidConfiguration(let message), .missingCredentials(let message), .providerUnavailable(let message):
                return message
            }
        }
    }

    static func selectedOnDeviceEngine(macOSMajorVersion: Int, speechAnalyzerCompiled: Bool) -> OnDeviceEngine {
        macOSMajorVersion >= 26 && speechAnalyzerCompiled ? .speechAnalyzer : .sfSpeechRecognizer
    }

    static func runtimeOnDeviceEngine(processInfo: ProcessInfo = .processInfo) -> OnDeviceEngine {
        selectedOnDeviceEngine(
            macOSMajorVersion: processInfo.operatingSystemVersion.majorVersion,
            speechAnalyzerCompiled: speechAnalyzerCompiled
        )
    }

    static var speechAnalyzerCompiled: Bool {
        #if HANDSOFF_HAS_SPEECHANALYZER
        true
        #else
        false
        #endif
    }

    static func clampExpires(_ requested: Int?) -> Int {
        min(max(requested ?? defaultExpiresInSeconds, minExpiresInSeconds), maxExpiresInSeconds)
    }

    static func permissionState(nativeStatus: Int) -> PermissionState {
        switch nativeStatus {
        case 0:
            return .notDetermined
        case 1, 2:
            return .denied
        case 3:
            return .granted
        default:
            return .unknown
        }
    }

    static func buildWorkerTokenRequest(
        workerURL: String,
        appToken: String,
        expiresInSeconds: Int
    ) throws -> WorkerTokenRequest {
        guard var components = URLComponents(string: workerURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme,
              let host = components.host,
              !host.isEmpty
        else {
            throw Failure.invalidConfiguration("invalid-configuration: STT token Worker URL must be a valid URL")
        }
        guard scheme == "https" else {
            throw Failure.invalidConfiguration("invalid-configuration: STT token Worker URL must use https")
        }
        guard components.query == nil, components.fragment == nil else {
            throw Failure.invalidConfiguration("invalid-configuration: STT token Worker URL must not include query or fragment")
        }

        let token = appToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw Failure.missingCredentials("missing-credentials: HANDSOFF_STT_APP_AUTH_TOKEN is empty")
        }

        components.queryItems = [URLQueryItem(name: "expires_in_seconds", value: "\(expiresInSeconds)")]
        guard let url = components.url else {
            throw Failure.invalidConfiguration("invalid-configuration: STT token Worker URL must be a valid URL")
        }
        return WorkerTokenRequest(url: url, authorization: "Bearer \(token)")
    }

    static func validateWorkerTokenResponse(_ body: TokenWorkerResponse) throws -> StreamingToken {
        guard !body.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.providerUnavailable("provider-unavailable: Worker returned an empty token")
        }
        guard minExpiresInSeconds ... maxExpiresInSeconds ~= body.expiresInSeconds else {
            throw Failure.providerUnavailable("provider-unavailable: Worker returned an invalid token expiry")
        }
        return StreamingToken(token: body.token, expiresInSeconds: body.expiresInSeconds)
    }

    static func tokenRequest(workerURL: String, appToken: String, requestedExpiresInSeconds: Int? = nil) throws -> URLRequest {
        let shape = try buildWorkerTokenRequest(
            workerURL: workerURL,
            appToken: appToken,
            expiresInSeconds: clampExpires(requestedExpiresInSeconds)
        )
        var request = URLRequest(url: shape.url)
        request.httpMethod = "GET"
        request.setValue(shape.authorization, forHTTPHeaderField: "Authorization")
        return request
    }

    @MainActor
    final class OnDeviceStream {
        private var continuation: AsyncStream<Event>.Continuation?
        private var sfSpeechRecognizer: SFSpeechRecognizerSession?
        #if HANDSOFF_HAS_SPEECHANALYZER
        private var speechAnalyzer: SpeechAnalyzerSession?
        #endif

        func start() -> AsyncStream<Event> {
            stop()
            return AsyncStream { continuation in
                self.continuation = continuation
                #if HANDSOFF_HAS_SPEECHANALYZER
                if Self.canUseSpeechAnalyzer() {
                    if #available(macOS 26.0, *) {
                        let session = SpeechAnalyzerSession { event in
                            continuation.yield(event)
                        }
                        self.speechAnalyzer = session
                        session.start()
                        return
                    }
                }
                #endif
                if #available(macOS 10.15, *) {
                    let session = SFSpeechRecognizerSession { event in
                        continuation.yield(event)
                    }
                    self.sfSpeechRecognizer = session
                    session.start()
                } else {
                    continuation.yield(.error(
                        SttError(kind: .providerUnavailable, message: "on-device speech recognition requires macOS 10.15 or newer"),
                        receivedAt: Self.nowMs()
                    ))
                    continuation.finish()
                }
            }
        }

        func stop() {
            sfSpeechRecognizer?.stop()
            sfSpeechRecognizer = nil
            #if HANDSOFF_HAS_SPEECHANALYZER
            speechAnalyzer?.stop()
            speechAnalyzer = nil
            #endif
            continuation?.finish()
            continuation = nil
        }

        private static func canUseSpeechAnalyzer(processInfo: ProcessInfo = .processInfo) -> Bool {
            selectedOnDeviceEngine(
                macOSMajorVersion: processInfo.operatingSystemVersion.majorVersion,
                speechAnalyzerCompiled: speechAnalyzerCompiled
            ) == .speechAnalyzer
        }

        fileprivate static func nowMs() -> Double {
            Date().timeIntervalSince1970 * 1000
        }
    }
}

@available(macOS 10.15, *)
@MainActor
private final class SFSpeechRecognizerSession {
    private let emit: @MainActor (SpeechService.Event) -> Void
    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private let engine = AVAudioEngine()
    private let startedAt = Date()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var stopping = false

    init(emit: @escaping @MainActor (SpeechService.Event) -> Void) {
        self.emit = emit
    }

    func start() {
        if let error = permissionError() {
            emit(.error(error, receivedAt: SpeechService.OnDeviceStream.nowMs()))
            return
        }

        guard let recognizer else {
            emitError(kind: .providerUnavailable, message: "no recognizer for current locale")
            return
        }
        guard recognizer.isAvailable else {
            emitError(kind: .providerUnavailable, message: "recognizer unavailable")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            emitError(kind: .startFailed, message: "no microphone input channels available")
            return
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            emitError(kind: .startFailed, message: error.localizedDescription)
            return
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.emit(result: result)
                }
                if let error, !self.stopping {
                    self.emitError(kind: .providerUnavailable, message: error.localizedDescription)
                    self.stop()
                }
            }
        }
        emit(.ready)
    }

    func stop() {
        stopping = true
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
    }

    private func permissionError() -> SpeechService.SttError? {
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        if speechStatus != .authorized {
            return SpeechService.SttError(
                kind: .micPermission,
                message: "speech recognition not authorized",
                permissionState: SpeechService.permissionState(nativeStatus: Int(speechStatus.rawValue))
            )
        }

        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if microphoneStatus != .authorized {
            return SpeechService.SttError(
                kind: .micPermission,
                message: "microphone access not authorized",
                permissionState: SpeechService.permissionState(nativeStatus: Int(microphoneStatus.rawValue))
            )
        }

        return nil
    }

    private func emit(result: SFSpeechRecognitionResult) {
        let text = result.bestTranscription.formattedString
        let latencyMs = Date().timeIntervalSince(startedAt) * 1000
        let receivedAt = SpeechService.OnDeviceStream.nowMs()
        if result.isFinal {
            let segments = result.bestTranscription.segments
            let confidence = segments.isEmpty ? 0 : segments.reduce(0) { $0 + Double($1.confidence) } / Double(segments.count)
            emit(.final(text: text, confidence: confidence, latencyMs: latencyMs, receivedAt: receivedAt))
        } else {
            emit(.partial(text: text, confidence: 0, latencyMs: latencyMs, receivedAt: receivedAt))
        }
    }

    private func emitError(kind: SpeechService.SttErrorKind, message: String) {
        emit(.error(SpeechService.SttError(kind: kind, message: message), receivedAt: SpeechService.OnDeviceStream.nowMs()))
    }
}

#if HANDSOFF_HAS_SPEECHANALYZER
@available(macOS 26.0, *)
private enum SpeechAnalyzerServiceError: LocalizedError {
    case noInputChannels
    case noAudioFormat
    case localeNotSupported(String)
    case localeNotInstalled(String)
    case converterUnavailable
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .noInputChannels:
            return "no microphone input channels available"
        case .noAudioFormat:
            return "no compatible audio format available for the transcriber"
        case .localeNotSupported(let locale):
            return "SpeechAnalyzer does not support \(locale)"
        case .localeNotInstalled(let locale):
            return "SpeechAnalyzer on-device model for \(locale) is not installed"
        case .converterUnavailable:
            return "audio converter unavailable"
        case .conversionFailed(let message):
            return message
        }
    }
}

@available(macOS 26.0, *)
@MainActor
private final class SpeechAnalyzerSession {
    private let emit: @MainActor (SpeechService.Event) -> Void
    private let engine = AVAudioEngine()
    private let startedAt = Date()
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var tapInstalled = false
    private var stopping = false

    init(emit: @escaping @MainActor (SpeechService.Event) -> Void) {
        self.emit = emit
    }

    func start() {
        startTask = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        stopping = true
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
        inputContinuation?.finish()
        startTask?.cancel()
        resultTask?.cancel()
        if let analyzer {
            Task {
                await analyzer.cancelAndFinishNow()
            }
        }
        analyzer = nil
        inputContinuation = nil
    }

    private func run() async {
        do {
            let locale = Locale.current
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            try await ensureInstalledModel(for: transcriber, locale: locale)

            let analyzer = SpeechAnalyzer(modules: [transcriber])
            guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw SpeechAnalyzerServiceError.noAudioFormat
            }
            let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
            self.analyzer = analyzer
            inputContinuation = inputBuilder

            startResultTask(for: transcriber)
            try await analyzer.start(inputSequence: inputSequence)
            try startAudioEngine(analyzerFormat: analyzerFormat)
            emit(.ready)
        } catch {
            if !stopping {
                emitError(kind: .startFailed, message: error.localizedDescription)
            }
            stop()
        }
    }

    private func ensureInstalledModel(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let localeID = locale.identifier(.bcp47)
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.map({ $0.identifier(.bcp47) }).contains(localeID) else {
            throw SpeechAnalyzerServiceError.localeNotSupported(localeID)
        }

        let installed = await SpeechTranscriber.installedLocales
        guard installed.map({ $0.identifier(.bcp47) }).contains(localeID) else {
            throw SpeechAnalyzerServiceError.localeNotInstalled(localeID)
        }
    }

    private func startResultTask(for transcriber: SpeechTranscriber) {
        resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    let latencyMs = Date().timeIntervalSince(self.startedAt) * 1000
                    let receivedAt = SpeechService.OnDeviceStream.nowMs()
                    if result.isFinal {
                        self.emit(.final(text: text, confidence: 0, latencyMs: latencyMs, receivedAt: receivedAt))
                    } else {
                        self.emit(.partial(text: text, confidence: 0, latencyMs: latencyMs, receivedAt: receivedAt))
                    }
                }
            } catch {
                guard let self, !self.stopping, !(error is CancellationError) else { return }
                self.emitError(kind: .providerUnavailable, message: error.localizedDescription)
            }
        }
    }

    private func startAudioEngine(analyzerFormat: AVAudioFormat) throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else {
            throw SpeechAnalyzerServiceError.noInputChannels
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, !self.stopping else { return }
            do {
                let converted = try self.convert(buffer, to: analyzerFormat)
                self.inputContinuation?.yield(AnalyzerInput(buffer: converted))
            } catch {
                Task { @MainActor in
                    self.emitError(kind: .providerUnavailable, message: error.localizedDescription)
                    self.stop()
                }
            }
        }
        tapInstalled = true

        engine.prepare()
        try engine.start()
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format.sampleRate == format.sampleRate,
           buffer.format.channelCount == format.channelCount,
           buffer.format.commonFormat == format.commonFormat,
           buffer.format.isInterleaved == format.isInterleaved {
            return buffer
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            throw SpeechAnalyzerServiceError.converterUnavailable
        }
        converter.primeMethod = .none

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = max(1, AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1)
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw SpeechAnalyzerServiceError.converterUnavailable
        }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error {
            throw SpeechAnalyzerServiceError.conversionFailed(
                conversionError?.localizedDescription ?? "audio conversion failed"
            )
        }
        return converted
    }

    private func emitError(kind: SpeechService.SttErrorKind, message: String) {
        emit(.error(SpeechService.SttError(kind: kind, message: message), receivedAt: SpeechService.OnDeviceStream.nowMs()))
    }
}
#endif
