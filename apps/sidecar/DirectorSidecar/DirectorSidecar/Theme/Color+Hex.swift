//
//  Color+Hex.swift
//  DirectorSidecar
//
//  Hex → SwiftUI Color in the sRGB space (design.md tokens are sRGB hex). Opaque tokens
//  pass alpha 1; rgba() tokens pass the base hex + an explicit alpha.
//

import SwiftUI

extension Color {
    /// `Color(hex: 0xD4A018)` → solid; `Color(hex: 0xD4A018, alpha: 0.14)` → translucent.
    init(hex: UInt, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
