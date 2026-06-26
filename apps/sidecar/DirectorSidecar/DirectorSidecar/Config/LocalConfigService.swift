//
//  LocalConfigService.swift
//  DirectorSidecar
//
//  Track E (ADR 0005): non-secret local preferences, folded in from
//  `apps/desktop/src-tauri/src/commands/storage.rs`. Mirrors the contract
//  `localConfigSchema` / `DEFAULT_LOCAL_CONFIG` (packages/contracts/src/config.ts):
//  `{ sttProvider, headPointer }`. API keys / provider auth are intentionally OUT of
//  scope — those live in the provider lane's secure storage.
//
//  Recover-to-default is the load contract: anything that fails to decode (unknown
//  provider, drifted shape, old config missing `headPointer`) OR is out-of-range
//  silently resets to the default and rewrites it. `update` is stricter — it REJECTS
//  an out-of-range config instead of silently fixing it. The file-URL functions are
//  pure I/O so they unit-test in a temp dir exactly like the Rust storage tests.
//

import Foundation

/// Mirrors `STT_PROVIDERS` in `packages/contracts/src/config.ts` and the Rust
/// `SttProvider`. An unknown value fails to decode → the load path recovers to default.
enum SttProvider: String, Codable, Sendable, Equatable, CaseIterable {
    case native
    case assemblyai
}

/// `{ sttProvider, headPointer }`. Reuses the head-track `HeadPointerConfig` (same
/// `Codable` camelCase shape) so the persisted `headPointer` block decodes verbatim
/// into the value the head-pointer service already consumes.
struct LocalConfig: Codable, Sendable, Equatable {
    var sttProvider: SttProvider
    var headPointer: HeadPointerConfig

    /// `DEFAULT_LOCAL_CONFIG`. NOTE `headPointer.speed` is 5 here — the CONTRACT default,
    /// NOT `HeadPointerConfig.default` (whose speed is 8, the head-track RUNTIME default
    /// raised for out-of-the-box feel). The persisted config must round-trip the contract
    /// value, so this default is spelled out rather than reusing `HeadPointerConfig.default`.
    static let `default` = LocalConfig(
        sttProvider: .native,
        headPointer: HeadPointerConfig(movementMode: .edge, speed: 5, distanceToEdge: 0.12)
    )

    /// `headPointer.speed ∈ [1, 30]` and `distanceToEdge ∈ [0.02, 0.4]` — the contract
    /// `headPointerConfigSchema` bounds (and the Rust `is_valid`).
    var isValid: Bool {
        (1.0...30.0).contains(headPointer.speed)
            && (0.02...0.4).contains(headPointer.distanceToEdge)
    }
}

enum LocalConfigError: Error, Equatable, CustomStringConvertible {
    case invalidSettings
    case readFailed(String)
    case writeFailed(String)

    var description: String {
        switch self {
        case .invalidSettings:
            return "local config contains invalid Head Pointer settings"
        case .readFailed(let message):
            return "Could not read local config: \(message)"
        case .writeFailed(let message):
            return message
        }
    }
}

enum LocalConfigService {
    static let configFileName = "local-config.json"

    /// `~/Library/Application Support/<bundle id>/local-config.json` — the native
    /// equivalent of Tauri's `app_config_dir().join(CONFIG_FILE_NAME)`.
    static func defaultConfigURL(
        fileManager: FileManager = .default,
        bundleID: String = Bundle.main.bundleIdentifier ?? "com.handsoff.desktop"
    ) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return base.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent(configFileName, isDirectory: false)
    }

    // MARK: File-URL operations (pure I/O; unit-tested against a temp dir)

    /// Load the config, recovering to (and rewriting) the default when the file is
    /// missing, undecodable, or out-of-range. Throws only on a non-"not found" read error.
    static func load(at url: URL) throws -> LocalConfig {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return try reset(at: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return try reset(at: url)
        } catch {
            throw LocalConfigError.readFailed(error.localizedDescription)
        }

        guard let decoded = try? JSONDecoder().decode(LocalConfig.self, from: data), decoded.isValid else {
            return try reset(at: url)
        }
        return decoded
    }

    /// Persist a config, REJECTING an out-of-range one (does not silently fix it).
    @discardableResult
    static func update(_ config: LocalConfig, at url: URL) throws -> LocalConfig {
        guard config.isValid else {
            throw LocalConfigError.invalidSettings
        }
        try write(config, to: url)
        return config
    }

    /// Restore and persist the default config.
    @discardableResult
    static func reset(at url: URL) throws -> LocalConfig {
        try update(.default, at: url)
    }

    // MARK: Convenience (default app config path)

    static func load() throws -> LocalConfig { try load(at: try defaultConfigURL()) }

    @discardableResult
    static func update(_ config: LocalConfig) throws -> LocalConfig {
        try update(config, at: try defaultConfigURL())
    }

    @discardableResult
    static func reset() throws -> LocalConfig { try reset(at: try defaultConfigURL()) }

    // MARK: Encoding

    private static func write(_ config: LocalConfig, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw LocalConfigError.writeFailed("Could not create the local config directory: \(error.localizedDescription)")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let body: Data
        do {
            body = try encoder.encode(config)
        } catch {
            throw LocalConfigError.writeFailed("Could not encode local config: \(error.localizedDescription)")
        }
        // Trailing newline to match the Rust writer's `format!("{body}\n")`.
        var bytes = body
        bytes.append(0x0A)
        do {
            try bytes.write(to: url)
        } catch {
            throw LocalConfigError.writeFailed("Could not write local config: \(error.localizedDescription)")
        }
    }
}
