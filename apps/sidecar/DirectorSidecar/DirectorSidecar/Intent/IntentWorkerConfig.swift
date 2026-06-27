//
//  IntentWorkerConfig.swift
//  DirectorSidecar
//
//  ADR 0005 Track D. Sources the intent-Worker endpoint so the in-process loop's resolver can be
//  built. The provider-secret boundary is unchanged: the app holds only the Worker URL + the
//  app-cohort token (the OpenAI key stays server-side, in `workers/llm-intent`). The names mirror
//  `apps/desktop/.env.local` EXACTLY — `HANDSOFF_INTENT_WORKER_URL` / `HANDSOFF_INTENT_APP_AUTH_TOKEN`
//  — so the same source of truth feeds both stacks during the migration.
//
//  BLOCKER (ADR 0005 § Immediate findings): a reviewed config/keychain story must replace the Rust
//  build-script env baking before Tauri is removed. Until then this reads the live environment first
//  (a binary launched from a shell that sourced `.env.local`) then the Info.plist (a baked build), so
//  the bundled `.app` works without inventing a secret store. When NEITHER is set, the loop still
//  runs perception/dispatch and the resolver returns a clean `blocked` intent — real degraded
//  behavior, never mock data.
//

import Foundation

enum IntentWorkerConfig {
    static let workerURLKey = "HANDSOFF_INTENT_WORKER_URL"
    static let appTokenKey = "HANDSOFF_INTENT_APP_AUTH_TOKEN"

    /// Read a key from the live environment first, then the bundle Info.plist. Blank values count
    /// as absent (a placeholder env var must not masquerade as configuration).
    static func value(
        _ key: String,
        env: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> String? {
        if let fromEnv = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !fromEnv.isEmpty {
            return fromEnv
        }
        if let fromPlist = (bundle.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !fromPlist.isEmpty {
            return fromPlist
        }
        return nil
    }

    /// Both halves present AND the URL is a valid HTTPS Worker URL.
    static func client(
        env: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> IntentWorkerClient? {
        guard let url = value(workerURLKey, env: env, bundle: bundle),
              let token = value(appTokenKey, env: env, bundle: bundle),
              let client = try? IntentWorkerClient(workerURL: url, appToken: token) else {
            return nil
        }
        return client
    }

    /// The resolver the loop's "head" calls: the live Worker-backed `NextToolCallResolver` when the
    /// endpoint is configured, else a resolver that returns a typed `blocked` intent explaining the
    /// gap. Either way the loop is wired directly — no bridge, no fabricated tool call.
    static func resolver(
        env: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        model: String = NextToolCallResolver.defaultModel
    ) -> NextToolCallResolving {
        guard let client = client(env: env, bundle: bundle) else {
            return notConfiguredResolver
        }
        return LoopResolver.worker(client: client, model: model)
    }

    /// The degraded resolver: a clean `blocked` intent (no transport, no mock) naming the missing keys.
    /// The 4th argument (the optional U5 vision screenshot) is ignored — an unconfigured resolver
    /// never reaches the Worker, so there is nothing to send the capture to.
    static let notConfiguredResolver: NextToolCallResolving = { input, createdAt, _, _ in
        Contracts.ResolvedIntent.blockedIntent(
            status: .blocked,
            input: input,
            id: "intent-worker-unconfigured",
            createdAt: createdAt,
            reason: "Intent worker is not configured. Set \(workerURLKey) and \(appTokenKey).")
    }
}
