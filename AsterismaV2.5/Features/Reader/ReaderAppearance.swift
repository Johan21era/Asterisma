//  ReaderAppearance.swift
//  AsterismaV2.5
//
//  Shared model for the reader's Apple Books-style Appearance panel.
//
//  The panel deliberately separates *theme* from *typography*:
//  - a theme supplies a page palette and a coherent starting point;
//  - font, size, weight, spacing, margins, alignment, columns, and page-turn
//    style are independent controls the reader can tune afterwards.
//
//  Persisted keys are plain strings/doubles/bools so older reader settings
//  keep working. `ReaderThemePreset.resolve` migrates the original
//  light/sepia/dark values.

import Foundation
import SwiftUI

// MARK: - Theme presets

/// Six page themes inspired by Apple Books' Original / Quiet / Paper / Bold /
/// Calm / Focus set. The values are Asterisma's own palette, not sampled Apple
/// assets; every pair is checked against WCAG AA in ReaderAppearanceTests.
enum ReaderThemePreset: String, CaseIterable, Identifiable {
    case original
    case quiet
    case paper
    case bold
    case calm
    case focus

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original: return "Original"
        case .quiet: return "Quiet"
        case .paper: return "Paper"
        case .bold: return "Bold"
        case .calm: return "Calm"
        case .focus: return "Focus"
        }
    }

    var backgroundHex: String {
        switch self {
        case .original: return "#FFFFFF"
        case .quiet: return "#F5F3EE"
        case .paper: return "#F4ECD8"
        case .bold: return "#FFFFFF"
        case .calm: return "#E7EDE8"
        case .focus: return "#141414"
        }
    }

    var foregroundHex: String {
        switch self {
        case .original: return "#1A1A1A"
        case .quiet: return "#2B2A27"
        case .paper: return "#3B2F2F"
        case .bold: return "#000000"
        case .calm: return "#2C3832"
        case .focus: return "#E6E6E6"
        }
    }

    var isDark: Bool {
        self == .focus
    }

    var backgroundColor: Color {
        Color(readerHex: backgroundHex)
    }

    var foregroundColor: Color {
        Color(readerHex: foregroundHex)
    }

    /// Reader chrome follows the page rather than fighting it: light pages get
    /// a quiet dark-on-white capsule, dark pages get the inverse.
    var chromeForeground: Color {
        isDark ? Color.white.opacity(0.94) : Color.black.opacity(0.76)
    }

    var chromeBackground: Color {
        isDark ? Color.black.opacity(0.64) : Color.white.opacity(0.84)
    }

    var chromeStroke: Color {
        isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.08)
    }

    var defaultFont: ReaderFontFamily {
        switch self {
        case .original: return .original
        case .quiet: return .newYork
        case .paper: return .georgia
        case .bold: return .avenirNext
        case .calm: return .athelas
        case .focus: return .sanFrancisco
        }
    }

    var defaultBold: Bool {
        self == .bold
    }

    var defaultLineHeight: Double {
        switch self {
        case .original: return 1.55
        case .quiet: return 1.70
        case .paper: return 1.65
        case .bold: return 1.50
        case .calm: return 1.70
        case .focus: return 1.60
        }
    }

    var defaultMargin: Double {
        switch self {
        case .original: return 46
        case .quiet: return 54
        case .paper: return 52
        case .bold: return 40
        case .calm: return 56
        case .focus: return 44
        }
    }

    var previewDesign: Font.Design {
        switch defaultFont {
        case .newYork, .georgia, .palatino, .charter, .iowan, .athelas, .timesNewRoman:
            return .serif
        case .avenirNext, .seravek, .sanFrancisco:
            return .default
        case .original:
            return .serif
        }
    }

    /// Legacy settings used "light"/"sepia"/"dark". Never discard those
    /// values on disk; map them when the reader asks for a preset.
    static func resolve(_ raw: String) -> ReaderThemePreset {
        if let preset = ReaderThemePreset(rawValue: raw) {
            return preset
        }
        switch raw {
        case "sepia":
            return .paper
        case "dark":
            return .focus
        case "light", "":
            return .original
        default:
            return .original
        }
    }
}

// MARK: - Fonts

/// A curated macOS font list matching the spirit of Books' Font menu.
/// "Original" deliberately leaves the EPUB's own embedded font alone.
enum ReaderFontFamily: String, CaseIterable, Identifiable {
    case original
    case newYork
    case georgia
    case palatino
    case charter
    case iowan
    case athelas
    case avenirNext
    case seravek
    case sanFrancisco
    case timesNewRoman

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original: return "Original"
        case .newYork: return "New York"
        case .georgia: return "Georgia"
        case .palatino: return "Palatino"
        case .charter: return "Charter"
        case .iowan: return "Iowan Old Style"
        case .athelas: return "Athelas"
        case .avenirNext: return "Avenir Next"
        case .seravek: return "Seravek"
        case .sanFrancisco: return "San Francisco"
        case .timesNewRoman: return "Times New Roman"
        }
    }

    /// CSS family stack. `nil` means "do not override the book's font."
    var cssFamily: String? {
        switch self {
        case .original: return nil
        case .newYork: return "\"New York\", ui-serif, Georgia, serif"
        case .georgia: return "Georgia, \"Times New Roman\", serif"
        case .palatino: return "Palatino, \"Palatino Linotype\", \"Book Antiqua\", serif"
        case .charter: return "Charter, \"Bitstream Charter\", Georgia, serif"
        case .iowan: return "\"Iowan Old Style\", Palatino, Georgia, serif"
        case .athelas: return "Athelas, Georgia, serif"
        case .avenirNext: return "\"Avenir Next\", Avenir, \"Helvetica Neue\", sans-serif"
        case .seravek: return "Seravek, \"Avenir Next\", \"Helvetica Neue\", sans-serif"
        case .sanFrancisco: return "-apple-system, BlinkMacSystemFont, \"SF Pro Text\", \"Helvetica Neue\", sans-serif"
        case .timesNewRoman: return "\"Times New Roman\", Times, serif"
        }
    }
}

// MARK: - Layout / navigation

enum ReaderColumnLayout: String, CaseIterable, Identifiable {
    case automatic
    case single
    case double

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Auto"
        case .single: return "One"
        case .double: return "Two"
        }
    }

    var helpText: String {
        switch self {
        case .automatic: return "Two pages when the window is wide enough"
        case .single: return "One page at any window width"
        case .double: return "Two pages when the window can fit them"
        }
    }
}

enum ReaderPageTurnStyle: String, CaseIterable, Identifiable {
    case slide
    case fade
    case instant

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .slide: return "Slide"
        case .fade: return "Fade"
        case .instant: return "Instant"
        }
    }
}

/// Apple Books offers a paged reading surface and a vertical scrolling one.
/// Both use the same typography settings; only the movement model changes.
enum ReaderReadingMode: String, CaseIterable, Identifiable {
    case paged
    case scroll

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .paged: return "Paged"
        case .scroll: return "Scrolling"
        }
    }
}

// MARK: - Appearance value

struct ReaderAppearance {
    var theme: ReaderThemePreset
    var font: ReaderFontFamily
    var isBold: Bool
    var textScale: Double
    var lineHeight: Double
    var characterSpacing: Double
    var wordSpacing: Double
    var margin: Double
    var alignment: String
    var columns: ReaderColumnLayout
    var hyphenation: Bool
    var pageTurn: ReaderPageTurnStyle
    var readingMode: ReaderReadingMode
    var showPageNumbers: Bool
    /// 1.0 is the page at normal brightness. Lower values dim only the reading
    /// surface with a non-interactive black veil; controls stay legible.
    var brightness: Double
    /// Apple Books' "Both Margins Advance": either edge goes forward instead
    /// of the left edge going back.
    var bothMarginsAdvance: Bool

    static func defaults(for theme: ReaderThemePreset) -> ReaderAppearance {
        ReaderAppearance(
            theme: theme,
            font: theme.defaultFont,
            isBold: theme.defaultBold,
            textScale: 1.0,
            lineHeight: theme.defaultLineHeight,
            characterSpacing: 0,
            wordSpacing: 0,
            margin: theme.defaultMargin,
            alignment: "left",
            columns: .automatic,
            hyphenation: true,
            pageTurn: .slide,
            readingMode: .paged,
            showPageNumbers: true,
            brightness: 1.0,
            bothMarginsAdvance: false
        )
    }

    var settingsDictionary: [String: Any] {
        var settings: [String: Any] = [
            "scale": textScale,
            "lineHeight": lineHeight,
            "align": alignment == "justify" ? "justify" : "left",
            "bold": isBold,
            "letterSpacing": characterSpacing,
            "wordSpacing": wordSpacing,
            "margin": margin,
            "columns": columns.rawValue,
            "hyphenation": hyphenation,
            "pageTurn": pageTurn.rawValue,
            "readingMode": readingMode.rawValue,
            "bg": theme.backgroundHex,
            "fg": theme.foregroundHex,
            "brightness": ReaderComfort.clampedBrightness(brightness),
            "bothMarginsAdvance": bothMarginsAdvance,
        ]
        if let family = font.cssFamily {
            settings["fontFamily"] = family
        }
        return settings
    }

    var settingsJSON: String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: settingsDictionary,
            options: [.sortedKeys]
        ) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// MARK: - Comfort

/// Shared brightness math for both readers. This intentionally dims only the
/// page surface: a black veil over the content, never over the controls, so the
/// reader can still find the slider in a dark room.
enum ReaderComfort {
    static let brightnessRange = 0.35 ... 1.0
    static let maximumDimOpacity = 0.55

    static func clampedBrightness(_ value: Double) -> Double {
        min(brightnessRange.upperBound, max(brightnessRange.lowerBound, value))
    }

    static func dimOpacity(for brightness: Double) -> Double {
        (1.0 - clampedBrightness(brightness)) * maximumDimOpacity
    }
}

struct ReaderBrightnessOverlay: View {
    let brightness: Double

    var body: some View {
        Color.black
            .opacity(ReaderComfort.dimOpacity(for: brightness))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Hex color helper

private extension Color {
    init(readerHex hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}
