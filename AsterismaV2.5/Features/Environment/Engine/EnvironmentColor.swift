//  EnvironmentColor.swift
//  AsterismaV2.5
//
//  Environment Engine — Phase B (Part 5 of the build spec)
//
//  SwiftUI's `Color` doesn't expose its RGBA components in a form that's
//  safe to linearly interpolate across arbitrary color spaces, so the
//  Environment Engine stores and blends its own RGBA components and only
//  converts to `Color` at the point of rendering.
//

import SwiftUI

struct EnvironmentColor: Sendable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Parses a "#RRGGBB" or "#RRGGBBAA" literal. Every call site in this
    /// feature passes a hardcoded literal transcribed from Part 5.4 of the
    /// build spec, so a malformed string is a programmer error worth
    /// catching immediately at the call site rather than routing around at
    /// runtime with a silent fallback color.
    init(hex: String) {
        let hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        guard let value = UInt64(hexString, radix: 16) else {
            preconditionFailure("EnvironmentColor: malformed hex literal '\(hex)'")
        }

        switch hexString.count {
        case 6:
            self.red = Double((value & 0xFF0000) >> 16) / 255.0
            self.green = Double((value & 0x00FF00) >> 8) / 255.0
            self.blue = Double(value & 0x0000FF) / 255.0
            self.alpha = 1.0
        case 8:
            self.red = Double((value & 0xFF000000) >> 24) / 255.0
            self.green = Double((value & 0x00FF0000) >> 16) / 255.0
            self.blue = Double((value & 0x0000FF00) >> 8) / 255.0
            self.alpha = Double(value & 0x000000FF) / 255.0
        default:
            preconditionFailure("EnvironmentColor: hex literal '\(hex)' must be 6 or 8 hex digits")
        }
    }

    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    /// Linear component-wise blend. `fraction` is expected to already be
    /// eased (smoothstepped) by the caller — this does no easing of its own,
    /// per the separation Part 5.3 describes between the eased time fraction
    /// and the (plain linear) per-property blend that uses it.
    func lerp(to other: EnvironmentColor, fraction: Double) -> EnvironmentColor {
        let t = EnvironmentMath.clampUnit(fraction)
        return EnvironmentColor(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t,
            alpha: alpha + (other.alpha - alpha) * t
        )
    }

    /// Blends this color toward its own perceptual gray equivalent. Used by
    /// the weather modifier's small desaturation nudge (Part 8).
    func desaturated(by amount: Double) -> EnvironmentColor {
        let gray = red * 0.299 + green * 0.587 + blue * 0.114
        let grayColor = EnvironmentColor(red: gray, green: gray, blue: gray, alpha: alpha)
        return lerp(to: grayColor, fraction: EnvironmentMath.clampUnit(amount))
    }
}

/// A single color+position pair in `EnvironmentState.backgroundGradient`.
/// Every named palette snapshot in `EnvironmentPalette` uses the same fixed
/// stop count at the same fixed positions (see that file's header comment),
/// which is what makes cross-snapshot interpolation well-defined: stop N in
/// one snapshot always blends with stop N in the other.
struct EnvironmentGradientStop: Sendable, Equatable {
    var color: EnvironmentColor
    var location: Double // 0...1 — matches SwiftUI's Gradient.Stop(location:) semantics
}
