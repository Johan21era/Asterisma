//  PDFReaderSettings.swift
//  AsterismaV2.5
//
//  PDFs cannot be reflowed, but the reader can still control how the page is
//  framed: one page, continuous scroll, facing pages, fit page/width/actual,
//  the mat color, and page brightness. These are the image-reader controls
//  that transfer from MangaDex/Kavita-style readers; font and spacing controls
//  remain EPUB-only because a PDF carries its own typography.

import AppKit
import Foundation
import PDFKit

enum PDFPageLayout: String, CaseIterable, Identifiable {
    case single
    case continuous
    case facing
    case facingContinuous

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .single: return "Single"
        case .continuous: return "Continuous"
        case .facing: return "Facing"
        case .facingContinuous: return "Facing + Scroll"
        }
    }

    var helpText: String {
        switch self {
        case .single: return "One page at a time"
        case .continuous: return "One page wide, scrolling down"
        case .facing: return "Two pages side by side"
        case .facingContinuous: return "Two pages side by side, scrolling down"
        }
    }

    var displayMode: PDFDisplayMode {
        switch self {
        case .single: return .singlePage
        case .continuous: return .singlePageContinuous
        case .facing: return .twoUp
        case .facingContinuous: return .twoUpContinuous
        }
    }
}

enum PDFFitMode: String, CaseIterable, Identifiable {
    case page
    case width
    case height
    case actual

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .page: return "Fit Page"
        case .width: return "Fit Width"
        case .height: return "Fit Height"
        case .actual: return "Actual Size"
        }
    }

    var helpText: String {
        switch self {
        case .page: return "Fit the whole page inside the window"
        case .width: return "Fill the window's width and scroll"
        case .height: return "Fill the window's height and scroll sideways"
        case .actual: return "Draw at 100% of the PDF's own size"
        }
    }
}

/// PDFKit has first-class right-to-left presentation. Exposing it here makes
/// manga and Arabic/Hebrew PDFs read in the intended page order without
/// reordering the document or lying about page indices.
enum PDFReadingDirection: String, CaseIterable, Identifiable {
    case leftToRight
    case rightToLeft

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .leftToRight: return "Left to Right"
        case .rightToLeft: return "Right to Left"
        }
    }

    var isRTL: Bool { self == .rightToLeft }
}

enum PDFReaderBackground: String, CaseIterable, Identifiable {
    case system
    case paper
    case slate

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .paper: return "Paper"
        case .slate: return "Slate"
        }
    }

    var nsColor: NSColor {
        switch self {
        case .system:
            return .underPageBackgroundColor
        case .paper:
            return NSColor(srgbRed: 0.93, green: 0.90, blue: 0.82, alpha: 1)
        case .slate:
            return NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1)
        }
    }
}

struct PDFReaderSettings: Equatable {
    var layout: PDFPageLayout
    var fit: PDFFitMode
    var background: PDFReaderBackground
    var pageGap: Double
    var coverAlone: Bool
    var readingDirection: PDFReadingDirection

    static let pageGapRange = 0.0 ... 80.0

    static let defaults = PDFReaderSettings(
        layout: .continuous,
        fit: .page,
        background: .system,
        pageGap: 44,
        coverAlone: true,
        readingDirection: .leftToRight
    )

    static func clampedPageGap(_ value: Double) -> Double {
        min(pageGapRange.upperBound, max(pageGapRange.lowerBound, value))
    }

    var pageBreakMargins: NSEdgeInsets {
        let gap = Self.clampedPageGap(pageGap)
        return NSEdgeInsets(
            top: max(8, gap - 8),
            left: gap,
            bottom: max(8, gap - 8),
            right: gap
        )
    }
}
