import AVFoundation
import Foundation
import Speech

public typealias HandsOffSttEventCallback = @convention(c) (UnsafePointer<CChar>?) -> Void

@_silgen_name("handsoff_emit_stt_ready")
private func handsoffEmitSttReady(_ callback: HandsOffSttEventCallback)

@_silgen_name("handsoff_emit_stt_partial")
private func handsoffEmitSttPartial(_ callback: HandsOffSttEventCallback, _ text: UnsafePointer<CChar>)

@_silgen_name("handsoff_emit_stt_final")
private func handsoffEmitSttFinal(
    _ callback: HandsOffSttEventCallback,
    _ text: UnsafePointer<CChar>,
    _ confidence: Double,
    _ latencyMs: Int64
)

@_silgen_name("handsoff_emit_stt_error")
private func handsoffEmitSttError(
    _ callback: HandsOffSttEventCallback,
    _ kind: UnsafePointer<CChar>,
    _ message: UnsafePointer<CChar>
)

@available(macOS 26.0, *)
private enum HandsOffSpeechAnalyzerError: LocalizedError {
    case noInputChannels
    case localeNotSupported(String)
    case localeNotInstalled(String)
    case converterUnavailable
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .noInputChannels:
            return "no microphone input channels available"
        case let .localeNotSupported(locale):
            return "SpeechAnalyzer does not support \(locale)"
        case let .localeNotInstalled(locale):
            return "SpeechAnalyzer on-device model for \(locale) is not installed"
        case .converterUnavailable:
            return "audio converter unavailable"
        case let .conversionFailed(message):
            return message
        }
    }
}

@available(macOS 26.0, *)
private final class HandsOffSpeechAnalyzerSession: @unchecked Sendable {
    private let callback: HandsOffSttEventCallback
    private let engine = AVAudioEngine()
    private let startedAt = Date()
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var tapInstalled = false
    private var stopping = false

    init(callback: @escaping HandsOffSttEventCallback) {
        self.callback = callback
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
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveLiveTranscription)
            try await ensureInstalledModel(for: transcriber, locale: locale)

            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
            self.analyzer = analyzer
            self.inputContinuation = inputBuilder

            startResultTask(for: transcriber)
            try await analyzer.start(inputSequence: inputSequence)
            try startAudioEngine(analyzerFormat: analyzerFormat)
            handsoffEmitSttReady(callback)
        } catch {
            if !stopping {
                emitError(kind: "start-failed", message: error.localizedDescription)
            }
            stop()
        }
    }

    private func ensureInstalledModel(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let localeID = locale.identifier(.bcp47)
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.map({ $0.identifier(.bcp47) }).contains(localeID) else {
            throw HandsOffSpeechAnalyzerError.localeNotSupported(localeID)
        }

        let installed = await SpeechTranscriber.installedLocales
        guard installed.map({ $0.identifier(.bcp47) }).contains(localeID) else {
            throw HandsOffSpeechAnalyzerError.localeNotInstalled(localeID)
        }
    }

    private func startResultTask(for transcriber: SpeechTranscriber) {
        resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        let latencyMs = Int(Date().timeIntervalSince(self.startedAt) * 1000)
                        self.emitFinal(text: text, confidence: 0, latencyMs: latencyMs)
                    } else {
                        self.emitPartial(text)
                    }
                }
            } catch {
                guard let self, !self.stopping, !(error is CancellationError) else { return }
                self.emitError(kind: "provider-unavailable", message: error.localizedDescription)
            }
        }
    }

    private func startAudioEngine(analyzerFormat: AVAudioFormat) throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else {
            throw HandsOffSpeechAnalyzerError.noInputChannels
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, !self.stopping else { return }
            do {
                let converted = try self.convert(buffer, to: analyzerFormat)
                self.inputContinuation?.yield(AnalyzerInput(buffer: converted))
            } catch {
                self.emitError(kind: "provider-unavailable", message: error.localizedDescription)
                DispatchQueue.main.async {
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
            buffer.format.isInterleaved == format.isInterleaved
        {
            return buffer
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            throw HandsOffSpeechAnalyzerError.converterUnavailable
        }
        converter.primeMethod = .none

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = max(1, AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1)
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw HandsOffSpeechAnalyzerError.converterUnavailable
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
            throw HandsOffSpeechAnalyzerError.conversionFailed(
                conversionError?.localizedDescription ?? "audio conversion failed"
            )
        }
        return converted
    }

    private func emitError(kind: String, message: String) {
        kind.withCString { kindPointer in
            message.withCString { messagePointer in
                handsoffEmitSttError(callback, kindPointer, messagePointer)
            }
        }
    }

    private func emitPartial(_ text: String) {
        text.withCString { textPointer in
            handsoffEmitSttPartial(callback, textPointer)
        }
    }

    private func emitFinal(text: String, confidence: Double, latencyMs: Int) {
        text.withCString { textPointer in
            handsoffEmitSttFinal(callback, textPointer, confidence, Int64(latencyMs))
        }
    }
}

@available(macOS 26.0, *)
private var activeSpeechAnalyzerSession: HandsOffSpeechAnalyzerSession?

@available(macOS 26.0, *)
@_cdecl("handsoff_speechanalyzer_start")
public func handsoff_speechanalyzer_start(_ callback: HandsOffSttEventCallback?) -> Int32 {
    guard let callback else { return 0 }
    activeSpeechAnalyzerSession?.stop()
    let session = HandsOffSpeechAnalyzerSession(callback: callback)
    activeSpeechAnalyzerSession = session
    session.start()
    return 1
}

@available(macOS 26.0, *)
@_cdecl("handsoff_speechanalyzer_stop")
public func handsoff_speechanalyzer_stop() {
    activeSpeechAnalyzerSession?.stop()
    activeSpeechAnalyzerSession = nil
}
