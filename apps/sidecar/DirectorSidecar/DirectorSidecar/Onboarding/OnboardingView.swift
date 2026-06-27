//
//  OnboardingView.swift
//  DirectorSidecar
//
//  Flow to First Run — the four-view after-download onboarding window, adapted from
//  `Claude-Design_Director/Flow 2 - First Run` to the super-native design system. One content-sized
//  window (hidden titlebar so macOS still draws the traffic lights), centered progress dots, then:
//  Welcome → Point & Speak primer → Permissions (real grants) → Ready (rail-edge pick). Every surface
//  reads Theme tokens, so light + dark are one implementation; copy + contrast follow the design.md
//  WCAG rules (dark ink on gold, AA text), and controls are SF Symbols + standard SwiftUI.
//

import SwiftUI
import AppKit
import Combine

/// The onboarding window scene identifier — shared by the App scene declaration and the in-view
/// `dismissWindow` that closes it on finish.
enum OnboardingScene { static let id = "onboarding" }

struct OnboardingView: View {
    let model: OnboardingModel
    @Environment(\.theme) private var theme
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            ProgressDots(step: model.step.rawValue, count: OnboardingModel.Step.allCases.count)
            stepContent
                .frame(maxWidth: .infinity)
        }
        .frame(width: 580)
        .background(theme.window)
        .animation(theme.standardMotion, value: model.step)
        // Re-read live grants whenever the user tabs back into the app (e.g. from System Settings).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
        // Onboarding is the first scene, so it always auto-opens at launch. If it isn't actually
        // wanted (already completed and the always-show test flag is off), bounce straight to Home.
        .onAppear {
            if !OnboardingGate.shouldShowAtLaunch { goHome() }
        }
    }

    /// Finish the journey: open the Home dashboard window and close onboarding. Home only ever opens
    /// here, so the dashboard never appears until onboarding is done.
    private func goHome() {
        openWindow(id: "home")
        dismissWindow(id: OnboardingScene.id)
    }

    @ViewBuilder private var stepContent: some View {
        switch model.step {
        case .welcome: WelcomeStep(model: model)
        case .primer: PrimerStep(model: model)
        case .permissions: PermissionsStep(model: model)
        case .ready: ReadyStep(model: model) { model.finish(); goHome() }
        }
    }
}

// MARK: - Chrome

/// The four step dots, centered in a titlebar-height strip (traffic lights overlay the top-left).
private struct ProgressDots: View {
    let step: Int
    let count: Int
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i <= step ? theme.accent : theme.textTertiary.opacity(0.4))
                    .frame(width: 6, height: 6)
            }
        }
        .frame(height: 38)
        .frame(maxWidth: .infinity)
        .animation(theme.standardMotion, value: step)
        .accessibilityElement()
        .accessibilityLabel("Step \(step + 1) of \(count)")
    }
}

// MARK: - Step 0: Welcome

private struct WelcomeStep: View {
    let model: OnboardingModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 88, height: 88)
                .padding(.bottom, 24)
                .accessibilityHidden(true)
            Text("Welcome to Director")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .padding(.bottom, 10)
            Text("Director lives in your menu bar. Point at what you mean, speak your intent, and it directs background agents to carry it out — while you stay in command.")
                .font(theme.body)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 390)
                .padding(.bottom, 30)
            PrimaryCTA("Get started") { model.goNext() }
            Text(Self.versionLine)
                .font(theme.kbd)
                .foregroundStyle(theme.textTertiary)
                .padding(.top, 18)
        }
        .padding(.horizontal, 50)
        .padding(.top, 18)
        .padding(.bottom, 42)
    }

    private static var versionLine: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "Director \(v) · HandsOff"
    }
}

// MARK: - Step 1: Point & Speak primer

private struct PrimerStep: View {
    let model: OnboardingModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            StepTitle("Point & speak")
            Text("Two signals, one command. Your hand says *which*; your voice says *what*.")
                .font(theme.body)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 410)
                .padding(.bottom, 22)

            MiniStage()
                .frame(height: 200)
                .padding(.bottom, 20)

            HStack(alignment: .top, spacing: 18) {
                ExplainerColumn(symbol: "hand.point.up.left.fill", title: "Point",
                                detail: "Hold to lock onto a window, tab, or terminal.")
                ExplainerColumn(symbol: "waveform", title: "Speak",
                                detail: "Hold fn and say what you want done.")
            }
            .padding(.bottom, 24)

            NavRow(onBack: { model.goBack() }, continueLabel: "Continue",
                   continueEnabled: true, bump: 0) { model.goNext() }
        }
        .padding(.horizontal, 44)
        .padding(.top, 6)
        .padding(.bottom, 34)
    }
}

/// A compact, asset-free evocation of the live interaction: a target window, the Director reticle on
/// it, and a listening transcript chip (real `ListeningWaveform`).
private struct MiniStage: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(LinearGradient(colors: [theme.cardInset, theme.canvas],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(theme.separator, lineWidth: 1)

            // Target window
            VStack(alignment: .leading, spacing: 5) {
                Text("github.com · issue #42").font(theme.mono).foregroundStyle(theme.textTertiary)
                Text("Token refresh on 401").font(theme.body.weight(.medium)).foregroundStyle(theme.textPrimary)
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
            .frame(width: 200, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.card))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
            .offset(x: -90, y: -42)

            Reticle().offset(x: 38, y: -26)

            // Transcript chip
            HStack(spacing: 10) {
                ListeningWaveform(maxHeight: 16, minHeight: 5)
                Text("“Summarize that issue.”")
                    .font(theme.body).italic().foregroundStyle(theme.textPrimary)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.window.opacity(0.92)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.22), radius: 10, y: 5)
            .offset(y: 64)
        }
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// The Director reticle: concentric gold rings + white center, with a slow expanding pulse.
private struct Reticle: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().strokeBorder(theme.accent.opacity(0.9), lineWidth: 2)
                .frame(width: 30, height: 30)
                .scaleEffect(pulse ? 1.9 : 0.6)
                .opacity(pulse ? 0 : 0.9)
            Circle().strokeBorder(theme.accent, lineWidth: 2)
                .frame(width: 26, height: 26)
                .shadow(color: theme.accent.opacity(0.8), radius: 6)
            Circle().fill(.white).frame(width: 5, height: 5)
        }
        .frame(width: 30, height: 30)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

private struct ExplainerColumn: View {
    let symbol: String
    let title: String
    let detail: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                .foregroundStyle(theme.accent).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(theme.body.weight(.semibold)).foregroundStyle(theme.textPrimary)
                Text(detail).font(.system(size: 11)).foregroundStyle(theme.textSecondary).lineSpacing(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Step 2: Permissions

private struct PermissionsStep: View {
    let model: OnboardingModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            StepTitle("Grant a few permissions")
            Text("Director needs these to see your screen, hear you, and act on your behalf. Each is explicit and revocable in System Settings anytime.")
                .font(theme.body).foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 430).padding(.bottom, 20)

            AllowAllBanner { Task { await model.allowAll() } }
                .padding(.bottom, 14)

            DividerLabel("OR GRANT INDIVIDUALLY").padding(.bottom, 12)

            VStack(spacing: 9) {
                PermissionRow(symbol: "rectangle.on.rectangle", title: "Screen Recording",
                              subtitle: "See the apps and windows you point at.",
                              state: model.screen, pending: model.screenRequested) { model.allowScreen() }
                PermissionRow(symbol: "accessibility", title: "Accessibility",
                              subtitle: "Let agents click and type in approved actions.",
                              state: model.accessibility, pending: false) { model.allowAccessibility() }
                PermissionRow(symbol: "mic.fill", title: "Microphone",
                              subtitle: "Hear your spoken intent. Push-to-talk only.",
                              state: model.microphone, pending: false) { Task { await model.allowMicrophone() } }
                PermissionRow(symbol: "video.fill", title: "Camera",
                              subtitle: "Track your pointing hand. Frames never leave your Mac.",
                              state: model.camera, pending: false) { Task { await model.allowCamera() } }
            }
            .padding(.bottom, 14)

            CuaHealthRow(phase: model.cua, detail: model.cuaDetail) { Task { await model.runCuaCheck() } }
                .padding(.bottom, 10)

            if model.accessibility != .granted || model.screen != .granted {
                VStack(spacing: 8) {
                    Text("Enabled in System Settings but still shown as needed? macOS often needs a relaunch to apply Accessibility / Screen Recording — and a rebuilt-and-resigned app gets a new identity, so its old grant no longer matches (remove stale “Director” rows in Settings, then re-grant).")
                        .font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                        .multilineTextAlignment(.center).lineSpacing(1).frame(maxWidth: 460)
                    HStack(spacing: 18) {
                        Button("Recheck now") { model.refreshPermissions() }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.accentOnSurface)
                        Button("Relaunch Director") { relaunchDirector() }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.accentOnSurface)
                    }
                }
                .padding(.bottom, 14)
            } else {
                Color.clear.frame(height: 6)
            }

            NavRow(onBack: { model.goBack() }, continueLabel: "Continue",
                   continueEnabled: model.canContinue, bump: model.continueBump,
                   onSkip: { model.skip() }) { model.tryContinue() }
        }
        .padding(.horizontal, 36)
        .padding(.top, 6)
        .padding(.bottom, 28)
        // Poll live TCC status while this step is up, so an Accessibility grant (which flips live
        // in-process) reflects in the UI within ~1.5s without needing an app refocus.
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            model.refreshPermissions()
        }
        .onAppear { model.refreshPermissions() }
    }
}

private struct AllowAllBanner: View {
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: "checkmark.shield.fill").font(.system(size: 19))
                .foregroundStyle(theme.accentOnSurface).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("Allow all permissions").font(theme.body.weight(.semibold)).foregroundStyle(theme.textPrimary)
                Text("Grant Screen, Accessibility, Mic & Camera in one tap.")
                    .font(.system(size: 11)).foregroundStyle(theme.textSecondary)
            }
            Spacer(minLength: 8)
            Button(action: action) {
                HStack(spacing: 6) { Image(systemName: "bolt.fill").font(.system(size: 12)); Text("Allow All") }
                    .font(theme.body.weight(.semibold))
            }
            .buttonStyle(DirectorButtonStyle(kind: .primary))
        }
        .padding(.horizontal, 15).padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(theme.accentWash))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(theme.accent.opacity(0.32), lineWidth: 1))
    }
}

private struct PermissionRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    let state: PermissionState
    let pending: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme

    private var granted: Bool { state == .granted }

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(theme.textSecondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(theme.body.weight(.medium)).foregroundStyle(theme.textPrimary)
                Text(granted ? subtitle : (pending ? "Pending — finish in System Settings (relaunch may be needed)." : subtitle))
                    .font(.system(size: 11)).foregroundStyle(theme.textTertiary)
            }
            Spacer(minLength: 8)
            if granted {
                GrantedPill("Allowed")
            } else {
                Button(pending ? "Settings" : "Allow", action: action)
                    .buttonStyle(DirectorButtonStyle(kind: .secondary))
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.separator, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(granted ? "Allowed" : "Not yet allowed").")
    }
}

private struct CuaHealthRow: View {
    let phase: OnboardingModel.CuaPhase
    let detail: String
    let runCheck: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "cpu").font(.system(size: 17)).foregroundStyle(theme.textSecondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("Computer-use engine").font(theme.body.weight(.medium)).foregroundStyle(theme.textPrimary)
                Text(detail).font(theme.mono).foregroundStyle(theme.textTertiary)
            }
            Spacer(minLength: 8)
            switch phase {
            case .ready: GrantedPill("Ready")
            case .checking: ProgressView().controlSize(.small)
            case .idle, .needsGrants:
                Button("Run check", action: runCheck).buttonStyle(DirectorButtonStyle(kind: .secondary))
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.sidebar))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.separator, lineWidth: 1))
    }
}

// MARK: - Step 3: Ready

private struct ReadyStep: View {
    let model: OnboardingModel
    let onDone: () -> Void
    @Environment(\.theme) private var theme

    private var grantedChips: [String] {
        var chips: [String] = []
        if model.screen == .granted || model.screenRequested { chips.append("Screen") }
        if model.accessibility == .granted { chips.append("Accessibility") }
        if model.microphone == .granted { chips.append("Mic") }
        if model.camera == .granted { chips.append("Camera") }
        if model.cua == .ready { chips.append("CUA ready") }
        return chips
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(theme.success.opacity(0.16)).frame(width: 78, height: 78)
                Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(theme.success)
            }
            .padding(.bottom, 18)
            .accessibilityHidden(true)

            Text("You're in command")
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(theme.textPrimary).padding(.bottom, 8)
            Text("Everything's ready. Director is now live in your menu bar — look for the reticle in the top-right.")
                .font(theme.body).foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380).padding(.bottom, 18)

            if !grantedChips.isEmpty {
                HStack(spacing: 7) {
                    ForEach(grantedChips, id: \.self) { GrantedPill($0) }
                }
                .padding(.bottom, 24)
            }

            EdgePicker(selected: model.railEdge) { model.pickEdge($0) }
                .padding(.bottom, 24)

            PrimaryCTA("Open Home", symbol: "square.grid.2x2", action: onDone)
        }
        .padding(.horizontal, 46)
        .padding(.top, 14)
        .padding(.bottom, 40)
    }
}

/// The rail / listening-edge segmented control. Right is the product default.
private struct EdgePicker: View {
    let selected: RailEdge
    let onPick: (RailEdge) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "dock.rectangle").font(.system(size: 15)).foregroundStyle(theme.textSecondary)
                Text("Listening panel edge").font(theme.body.weight(.semibold)).foregroundStyle(theme.textPrimary)
            }
            .padding(.bottom, 4)
            Text("Where the rail appears when you hold fn to speak.")
                .font(.system(size: 11)).foregroundStyle(theme.textTertiary).padding(.bottom, 11)

            HStack(spacing: 3) {
                segment(.left, symbol: "rectangle.lefthalf.filled", label: "Left edge")
                segment(.right, symbol: "rectangle.righthalf.filled", label: "Right edge")
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.cardInset))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.separator, lineWidth: 1))
    }

    private func segment(_ edge: RailEdge, symbol: String, label: String) -> some View {
        let on = selected == edge
        return Button { onPick(edge) } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 13))
                Text(label).font(theme.body.weight(on ? .medium : .regular))
            }
            .foregroundStyle(on ? theme.textPrimary : theme.textSecondary)
            .padding(.horizontal, 16).padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(on ? theme.controlBg : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Shared components

private struct StepTitle: View {
    let text: String
    @Environment(\.theme) private var theme
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(theme.textPrimary)
            .multilineTextAlignment(.center)
            .padding(.bottom, 6)
    }
}

/// A prominent gold CTA with dark ink (the design's hero button — more generous padding than the
/// shared `DirectorButtonStyle`, same accent + ink tokens).
private struct PrimaryCTA: View {
    let title: String
    var symbol: String? = nil
    let action: () -> Void
    @Environment(\.theme) private var theme

    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).font(.system(size: 14, weight: .medium)) }
                Text(title).font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(theme.goldInk)
            .padding(.horizontal, 28).padding(.vertical, 11)
            .background(Capsule(style: .continuous).fill(theme.accent))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Back (plain) + optional Skip + Continue (gold, dims + shakes when disabled).
private struct NavRow: View {
    let onBack: () -> Void
    let continueLabel: String
    let continueEnabled: Bool
    let bump: Int
    var onSkip: (() -> Void)? = nil
    let onContinue: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 16) {
            Button("Back", action: onBack).buttonStyle(.plain)
                .font(theme.body).foregroundStyle(theme.textSecondary)
            Spacer()
            // Escape hatch when something can't be granted live (or a backend isn't built yet) — only
            // shown while Continue is still gated, so a fully-granted flow stays clean.
            if let onSkip, !continueEnabled {
                Button("Skip for now", action: onSkip).buttonStyle(.plain)
                    .font(theme.body).foregroundStyle(theme.textTertiary)
            }
            Button(action: onContinue) {
                Text(continueLabel).font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.goldInk)
                    .padding(.horizontal, 24).padding(.vertical, 10)
                    .background(Capsule(style: .continuous).fill(theme.accent))
                    .opacity(continueEnabled ? 1 : 0.45)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .modifier(Shake(animatableData: CGFloat(bump)))
            .animation(.default, value: bump)
        }
    }
}

private struct GrantedPill: View {
    let label: String
    @Environment(\.theme) private var theme
    init(_ label: String) { self.label = label }
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(theme.success)
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textPrimary)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(theme.success.opacity(0.16)))
        .accessibilityLabel("\(label), granted")
    }
}

private struct DividerLabel: View {
    let text: String
    @Environment(\.theme) private var theme
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(theme.separator).frame(height: 1)
            Text(text).font(.system(size: 10, weight: .semibold)).tracking(0.8)
                .foregroundStyle(theme.textTertiary).fixedSize()
            Rectangle().fill(theme.separator).frame(height: 1)
        }
    }
}

/// Quit and reopen Director — the reliable way to apply a Screen Recording / Accessibility grant
/// macOS won't surface to the running process (the preflight cache + signature re-validation both
/// clear on a fresh launch). Launches a new instance via LaunchServices, then terminates this one.
private func relaunchDirector() {
    let config = NSWorkspace.OpenConfiguration()
    config.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
        Task { @MainActor in NSApp.terminate(nil) }
    }
}

/// A small horizontal shake, driven by an incrementing counter (disabled-Continue feedback).
private struct Shake: GeometryEffect {
    var travel: CGFloat = 5
    var shakes: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(animatableData * .pi * shakes), y: 0))
    }
}
