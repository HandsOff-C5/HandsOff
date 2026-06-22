// On-device STT sidecar for HandsOff (#31, AD2).
//
// Captures microphone audio with AVAudioEngine and runs Apple's on-device
// speech recognition, emitting newline-delimited JSON events on stdout that map
// 1:1 onto the `SttStream` contract the webview consumes:
//
//   {"kind":"partial","text":"..."}
//   {"kind":"final","text":"...","confidence":0.93,"latencyMs":120}
//   {"kind":"error","errorKind":"mic-permission","message":"..."}
//   {"kind":"ready"}                      // recognition started, mic is live
//
// The Rust `stt_ondevice_*` commands spawn this binary to start a session and
// terminate the process to stop. No network, no API key: audio never leaves the
// device.
//
// Baseline path is `SFSpeechRecognizer` with `requiresOnDeviceRecognition`, which
// builds on the macOS 15 SDK and runs on all supported Macs (15–26). The macOS 26
// `SpeechAnalyzer` fast-path is added behind `if #available(macOS 26, *)` once the
// build uses the macOS 26 SDK — tracked in #81.

import AVFoundation
import Foundation
import Speech

// One emit point, serialized so concurrent callbacks never interleave a line.
enum Emitter {
    static let lock = NSLock()

    static func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
            var line = String(data: data, encoding: .utf8)
        else { return }
        line += "\n"
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    static func error(_ kind: String, _ message: String) {
        emit(["kind": "error", "errorKind": kind, "message": message])
    }
}

// Drives a single on-device recognition session for the process lifetime.
final class OnDeviceSttSession {
    private let recognizer: SFSpeechRecognizer
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let startedAt = Date()

    init?(localeIdentifier: String) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
        else {
            Emitter.error("provider-unavailable", "no recognizer for locale \(localeIdentifier)")
            return nil
        }
        self.recognizer = recognizer
    }

    // Ensure Speech + microphone authorization, then open the stream. Each
    // failure maps to an `SttError` kind the transcript panel already classifies.
    func start() {
        ensureSpeechAuthorized { [weak self] in
            self?.ensureMicAuthorized { [weak self] in
                DispatchQueue.main.async { self?.beginRecognition() }
            }
        }
    }

    // Gate on Speech authorization. When the grant already exists we must NOT
    // call `requestAuthorization`: this helper is launched as a raw sidecar
    // process, and macOS TCC kills that process before it can report a result.
    // The dashboard's permissions surface owns user setup; this helper only
    // reports the missing grant and exits cleanly.
    private func ensureSpeechAuthorized(_ next: @escaping () -> Void) {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized {
            next()
            return
        }
        Emitter.error("mic-permission", "speech recognition not authorized (\(status.rawValue))")
        exit(1)
    }

    // Same guard for the microphone: do not prompt from the raw helper process.
    private func ensureMicAuthorized(_ next: @escaping () -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized {
            next()
            return
        }
        Emitter.error("mic-permission", "microphone access not authorized (\(status.rawValue))")
        exit(1)
    }

    private func beginRecognition() {
        guard recognizer.isAvailable else {
            Emitter.error("provider-unavailable", "recognizer unavailable")
            exit(1)
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Keep audio on-device — the whole point of the provisioned-by-default path.
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            Emitter.error(
                "start-failed", "audio engine failed to start: \(error.localizedDescription)")
            exit(1)
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.emit(result)
            }
            if let error {
                Emitter.error("provider-unavailable", error.localizedDescription)
                self.stop()
                exit(1)
            }
        }

        Emitter.emit(["kind": "ready"])
    }

    private func emit(_ result: SFSpeechRecognitionResult) {
        let text = result.bestTranscription.formattedString
        if result.isFinal {
            let segments = result.bestTranscription.segments
            let confidence =
                segments.isEmpty
                ? 0
                : segments.map { Double($0.confidence) }.reduce(0, +) / Double(segments.count)
            let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            Emitter.emit([
                "kind": "final", "text": text, "confidence": confidence, "latencyMs": latencyMs,
            ])
        } else {
            Emitter.emit(["kind": "partial", "text": text])
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
    }
}

// `--locale en-US` is optional; default to the user's current language.
func parseLocale(_ args: [String]) -> String {
    if let index = args.firstIndex(of: "--locale"), index + 1 < args.count {
        return args[index + 1]
    }
    return Locale.current.identifier
}

func authString(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
    switch status {
    case .authorized: return "granted"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "not-determined"
    @unknown default: return "unknown"
    }
}

func micAuthString(_ status: AVAuthorizationStatus) -> String {
    switch status {
    case .authorized: return "granted"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "not-determined"
    @unknown default: return "unknown"
    }
}

// `--request-permissions` mode (#31): report the raw helper's current
// authorization states without prompting. This process shape cannot safely call
// TCC request APIs; doing so crashes before stdout can carry a result.
func requestPermissions() {
    Emitter.emit([
        "kind": "permissions",
        "speech": authString(SFSpeechRecognizer.authorizationStatus()),
        "microphone": micAuthString(AVCaptureDevice.authorizationStatus(for: .audio)),
    ])
    exit(0)
}

let arguments = CommandLine.arguments

// Retained for the whole process lifetime. These MUST be top-level globals, not
// locals: the recognition session owns the AVAudioEngine + recognitionTask, and
// if its last strong reference is a local that goes out of scope, ARC frees the
// session — tearing down the engine — the instant `start()` returns, before any
// audio is captured. The signal source is likewise retained so it stays active.
var activeSession: OnDeviceSttSession?
var activeTermSource: DispatchSourceSignal?

if arguments.contains("--request-permissions") {
    requestPermissions()
} else {
    let locale = parseLocale(arguments)
    guard let session = OnDeviceSttSession(localeIdentifier: locale) else { exit(1) }
    activeSession = session

    // Stop cleanly when Rust terminates us.
    signal(SIGTERM, SIG_IGN)
    let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    termSource.setEventHandler {
        session.stop()
        exit(0)
    }
    termSource.resume()
    activeTermSource = termSource

    session.start()
}

RunLoop.main.run()
