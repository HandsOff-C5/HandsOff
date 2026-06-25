//
//  VisualEffectBlur.swift
//  DirectorSidecar
//
//  Earned glass — wraps NSVisualEffectView for floating system surfaces (HUD, menu dropdown,
//  toast) only (design.md §7 materials). Document content uses tonal fills, never nested blur.
//  Callers swap this for an opaque fill under Reduce Transparency.
//

import SwiftUI
import AppKit

struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blending: NSVisualEffectView.BlendingMode

    init(_ material: NSVisualEffectView.Material, blending: NSVisualEffectView.BlendingMode = .withinWindow) {
        self.material = material
        self.blending = blending
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
    }
}
