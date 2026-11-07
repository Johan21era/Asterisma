//  ReaderAppearanceTests.swift
//  AsterismaV2.5
//
//  Pins for the Apple Books-style Appearance panel. The important invariants
//  are that every theme remains readable (WCAG AA), legacy theme values still
//  resolve, and every customization reaches the injected pagination settings.

import Foundation
import PDFKit
import Testing

@testable import AsterismaV2_5

@Suite("Reader appearance")
struct ReaderAppearanceTests {
    @Test("All six themes meet WCAG AA contrast")
    func themesMeetContrast() {
        for theme in ReaderThemePreset.allCases {
            let ratio = contrastRatio(
                foregroundHex: theme.foregroundHex,
                backgroundHex: theme.backgroundHex
            )
            #expect(
                ratio >= 4.5,
                "\(theme.displayName) contrast \(String(format: "%.2f", ratio)):1 is below AA"
            )
        }
    }

    @Test("Legacy light, sepia, and dark values migrate")
    func legacyThemesMigrate() {
        #expect(ReaderThemePreset.resolve("light") == .original)
        #expect(ReaderThemePreset.resolve("sepia") == .paper)
        #expect(ReaderThemePreset.resolve("dark") == .focus)
        #expect(ReaderThemePreset.resolve("quiet") == .quiet)
        #expect(ReaderThemePreset.resolve("not-a-theme") == .original)
    }

    @Test("Each theme carries a coherent typography starting point")
    func themeDefaults() {
        for theme in ReaderThemePreset.allCases {
            let defaults = ReaderAppearance.defaults(for: theme)
            #expect(defaults.theme == theme)
            #expect(defaults.font == theme.defaultFont)
            #expect(defaults.isBold == theme.defaultBold)
            #expect(defaults.textScale == 1.0)
            #expect(defaults.lineHeight == theme.defaultLineHeight)
            #expect(defaults.margin == theme.defaultMargin)
            #expect(defaults.columns == .automatic)
            #expect(defaults.hyphenation)
            #expect(defaults.readingMode == .paged)
            #expect(defaults.showPageNumbers)
        }

        #expect(ReaderAppearance.defaults(for: .bold).isBold)
        #expect(ReaderAppearance.defaults(for: .paper).font == .georgia)
        #expect(ReaderAppearance.defaults(for: .focus).theme.isDark)
    }

    @Test("Every customization is injected into the pagination settings")
    func settingsCarryCustomizations() throws {
        let appearance = ReaderAppearance(
            theme: .paper,
            font: .georgia,
            isBold: true,
            textScale: 1.2,
            lineHeight: 1.7,
            characterSpacing: 0.02,
            wordSpacing: 0.10,
            margin: 56,
            alignment: "justify",
            columns: .single,
            hyphenation: false,
            pageTurn: .fade,
            readingMode: .scroll,
            showPageNumbers: false,
            brightness: 0.7,
            bothMarginsAdvance: true
        )

        let data = try #require(appearance.settingsJSON.data(using: .utf8))
        let settings = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(settings["scale"] as? Double == 1.2)
        #expect(settings["lineHeight"] as? Double == 1.7)
        #expect(settings["align"] as? String == "justify")
        #expect(settings["bold"] as? Bool == true)
        #expect(settings["letterSpacing"] as? Double == 0.02)
        #expect(settings["wordSpacing"] as? Double == 0.10)
        #expect(settings["margin"] as? Double == 56)
        #expect(settings["columns"] as? String == "single")
        #expect(settings["hyphenation"] as? Bool == false)
        #expect(settings["pageTurn"] as? String == "fade")
        #expect(settings["readingMode"] as? String == "scroll")
        #expect(settings["bg"] as? String == "#F4ECD8")
        #expect(settings["fg"] as? String == "#3B2F2F")
        #expect(settings["brightness"] as? Double == 0.7)
        #expect(settings["bothMarginsAdvance"] as? Bool == true)
        #expect((settings["fontFamily"] as? String)?.contains("Georgia") == true)
    }

    @Test("Comfort brightness is clamped and dims only the page")
    func comfortBrightness() {
        #expect(ReaderComfort.clampedBrightness(0.1) == 0.35)
        #expect(ReaderComfort.clampedBrightness(1.4) == 1.0)
        #expect(ReaderComfort.dimOpacity(for: 1.0) == 0)
        #expect(ReaderComfort.dimOpacity(for: 0.35) > 0.3)
        #expect(ReaderComfort.dimOpacity(for: 0.35) < ReaderComfort.maximumDimOpacity)
    }

    @Test("PDF layout and fit options map to PDFKit")
    func pdfSettingsMap() {
        #expect(PDFPageLayout.single.displayMode == .singlePage)
        #expect(PDFPageLayout.continuous.displayMode == .singlePageContinuous)
        #expect(PDFPageLayout.facing.displayMode == .twoUp)
        #expect(PDFPageLayout.facingContinuous.displayMode == .twoUpContinuous)
        #expect(PDFReaderSettings.defaults.layout == .continuous)
        #expect(PDFReaderSettings.defaults.fit == .page)
        #expect(PDFReaderSettings.defaults.background == .system)
        #expect(PDFReaderSettings.defaults.pageGap == 44)
        #expect(PDFReaderSettings.defaults.coverAlone)
        #expect(PDFReaderSettings.defaults.readingDirection == .leftToRight)
    }

    @Test("PDF page gap is clamped and maps to page-break margins")
    func pdfPageGap() {
        #expect(PDFReaderSettings.clampedPageGap(-10) == 0)
        #expect(PDFReaderSettings.clampedPageGap(120) == 80)
        #expect(PDFReaderSettings.clampedPageGap(44) == 44)

        let wide = PDFReaderSettings(
            layout: .continuous,
            fit: .height,
            background: .slate,
            pageGap: 60,
            coverAlone: false,
            readingDirection: .rightToLeft
        ).pageBreakMargins
        #expect(wide.top == 52)
        #expect(wide.left == 60)
        #expect(wide.bottom == 52)
        #expect(wide.right == 60)
    }

    @Test("Right-to-left is a real PDFKit presentation, not a label")
    func pdfReadingDirection() {
        #expect(PDFReadingDirection.leftToRight.isRTL == false)
        #expect(PDFReadingDirection.rightToLeft.isRTL)
        #expect(PDFFitMode.allCases.count == 4)
        #expect(PDFFitMode.height.displayName == "Fit Height")
    }

    @Test("Original font leaves the EPUB font untouched")
    func originalFontDoesNotOverrideEpub() throws {
        let appearance = ReaderAppearance.defaults(for: .original)
        let data = try #require(appearance.settingsJSON.data(using: .utf8))
        let settings = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(settings["fontFamily"] == nil)
        #expect(settings["bold"] as? Bool == false)
        #expect(settings["bg"] as? String == "#FFFFFF")
    }
}

// MARK: - Contrast helper

private func contrastRatio(foregroundHex: String, backgroundHex: String) -> Double {
    let foreground = relativeLuminance(hex: foregroundHex)
    let background = relativeLuminance(hex: backgroundHex)
    let lighter = max(foreground, background)
    let darker = min(foreground, background)
    return (lighter + 0.05) / (darker + 0.05)
}

private func relativeLuminance(hex: String) -> Double {
    let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    var value: UInt64 = 0
    Scanner(string: cleaned).scanHexInt64(&value)
    let red = linearChannel(Double((value >> 16) & 0xFF) / 255)
    let green = linearChannel(Double((value >> 8) & 0xFF) / 255)
    let blue = linearChannel(Double(value & 0xFF) / 255)
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue
}

private func linearChannel(_ value: Double) -> Double {
    value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
}
