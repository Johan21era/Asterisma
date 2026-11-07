//  PDFSelectionTests.swift
//  AsterismaV2.5
//
//  WP-1.3: pins the pure selection geometry used by the PDF selection bridge.
//  These tests target `PDFSelectionGeometry` only, with `CGRect` fixtures —
//  no live `PDFView` is instantiated. The invariants under test are the ones
//  the `BookNoteAnchor.pdf(pageIndex:rect:)` anchor depends on: values in
//  0…1, relative to the page's cropBox bounds (so a non-zero cropBox origin
//  never leaks into the output), and a usable-rect predicate that rejects
//  empty geometry.
//
//  Fixtures use US Letter (612 × 792 pt) with a non-zero cropBox origin
//  (24, 36) precisely to catch code that normalizes against the world origin.

import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import AsterismaV2_5

@Suite("PDF selection geometry")
struct PDFSelectionGeometryTests {
    private let pageBounds = CGRect(x: 24, y: 36, width: 612, height: 792)

    // MARK: Requirement 1 — page-origin rect with half width/height → (0, 0, 0.5, 0.5)

    @Test("A rect at the page origin with half width/height normalizes to (0, 0, 0.5, 0.5)")
    func originRectNormalizes() {
        let rect = CGRect(
            x: pageBounds.minX,
            y: pageBounds.minY,
            width: pageBounds.width / 2,
            height: pageBounds.height / 2
        )

        let normalized = PDFSelectionGeometry.normalized(rect: rect, in: pageBounds)

        #expect(normalized.x == 0)
        #expect(normalized.y == 0)
        #expect(normalized.width == 0.5)
        #expect(normalized.height == 0.5)
    }

    // MARK: Requirement 2 — lower-right quadrant normalizes above 0.5, at most 1

    @Test("A rect in the lower-right quadrant normalizes to values above 0.5 and at most 1")
    func lowerRightQuadrantNormalizes() {
        // A 200 × 200 pt rect sitting well inside the lower-right quadrant,
        // away from the exact 0.5 boundaries so "above 0.5" is decisive.
        let rect = CGRect(x: 24 + 400, y: 36 + 500, width: 150, height: 150)

        let normalized = PDFSelectionGeometry.normalized(rect: rect, in: pageBounds)

        #expect(normalized.x > 0.5)
        #expect(normalized.y > 0.5)
        #expect(normalized.x + normalized.width > 0.5)
        #expect(normalized.y + normalized.height > 0.5)
        #expect(normalized.x + normalized.width <= 1.0)
        #expect(normalized.y + normalized.height <= 1.0)
        #expect(normalized.x <= 1.0 && normalized.y <= 1.0)
        #expect(normalized.width <= 1.0 && normalized.height <= 1.0)
    }

    // MARK: Requirement 3 — a rect past the page clamps into 0…1

    @Test("A rect that extends past the page clamps into 0…1 instead of exceeding it")
    func overflowingRectClamps() {
        // Starts in the lower-right area and extends 250 pt past the right
        // and bottom page edges.
        let rect = CGRect(x: 24 + 500, y: 36 + 650, width: 400, height: 400)

        let normalized = PDFSelectionGeometry.normalized(rect: rect, in: pageBounds)

        #expect(normalized.x >= 0 && normalized.x <= 1)
        #expect(normalized.y >= 0 && normalized.y <= 1)
        #expect(normalized.x + normalized.width <= 1.0)
        #expect(normalized.y + normalized.height <= 1.0)
        // The right/bottom edges are cut exactly at the page bounds, not
        // merely clamped inside 0…1 per component.
        #expect(normalized.x + normalized.width == 1.0)
        #expect(normalized.y + normalized.height == 1.0)
    }

    // MARK: Requirement 4 — zero-area / empty rects are unusable

    @Test("A zero-area or empty rect is reported unusable")
    func degenerateRectsAreUnusable() {
        // Zero width, zero height, CGRect.zero, and CGRect.null (NaN geometry)
        // must all be rejected.
        #expect(!PDFSelectionGeometry.isUsable(rect: .zero, in: pageBounds))
        #expect(
            !PDFSelectionGeometry.isUsable(
                rect: CGRect(x: 100, y: 100, width: 0, height: 50),
                in: pageBounds
            )
        )
        #expect(
            !PDFSelectionGeometry.isUsable(
                rect: CGRect(x: 100, y: 100, width: 50, height: 0),
                in: pageBounds
            )
        )
        #expect(!PDFSelectionGeometry.isUsable(rect: .null, in: pageBounds))

        // A healthy in-page rect is usable, so the rejections above reflect
        // the fixtures, not a broken predicate.
        let healthy = CGRect(x: 24 + 100, y: 36 + 100, width: 200, height: 40)
        #expect(PDFSelectionGeometry.isUsable(rect: healthy, in: pageBounds))
    }

    // MARK: Requirement 5 — multi-line bounding rect contains both lines, stays in page

    @Test("A multi-line bounding rect contains both line rects and stays within the page")
    func multiLineBoundingContainsLines() {
        // Two thin line rects on consecutive text lines; PDFSelection unions
        // its constituent rects the same way (envelope, not intersection).
        let line1 = CGRect(x: 24 + 100, y: 36 + 480, width: 400, height: 20)
        let line2 = CGRect(x: 24 + 80, y: 36 + 505, width: 420, height: 20)
        let bounding = line1.union(line2)

        let top = PDFSelectionGeometry.normalized(rect: line1, in: pageBounds)
        let bottom = PDFSelectionGeometry.normalized(rect: line2, in: pageBounds)
        let union = PDFSelectionGeometry.normalized(rect: bounding, in: pageBounds)

        // Normalization is affine, so containment in page space survives.
        // A tiny epsilon absorbs floating-point round-trip drift.
        let eps = 1e-9
        #expect(union.x <= top.x + eps)
        #expect(union.x <= bottom.x + eps)
        #expect(union.y <= top.y + eps)
        #expect(union.y <= bottom.y + eps)
        #expect(union.x + union.width + eps >= top.x + top.width)
        #expect(union.x + union.width + eps >= bottom.x + bottom.width)
        #expect(union.y + union.height + eps >= top.y + top.height)
        #expect(union.y + union.height + eps >= bottom.y + bottom.height)

        // And the union stays inside the page: usable, and every value in 0…1.
        #expect(PDFSelectionGeometry.isUsable(rect: bounding, in: pageBounds))
        #expect(union.x >= 0 && union.y >= 0)
        #expect(union.x + union.width <= 1.0)
        #expect(union.y + union.height <= 1.0)
    }

    // MARK: Requirement 6 — the notification path really reaches the hook

    /// Regression pin for the defect Buffy found in review: `PDFViewDelegate`
    /// declares no selection callback, so a method of that name compiles and is
    /// never called. Selection changes arrive only as
    /// `.PDFViewSelectionChanged`, and `makeNSView` registers the Coordinator
    /// for its own view. This test posts that notification and requires the
    /// hook to fire with a usable anchor.
    @Test("PDFViewSelectionChanged notification reaches the selection hook")
    @MainActor
    func selectionNotificationReachesHook() throws {
        let document = try #require(Self.textDocument())
        let view = PDFView()
        view.document = document

        let match = try #require(
            document.findString("Selection", withOptions: []).first,
            "generated PDF text was not searchable")
        view.currentSelection = match

        var captured: PDFTextSelection?
        let coordinator = PDFReaderView.Coordinator(
            onPageChange: { _ in },
            onSelection: { captured = $0 })
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(PDFReaderView.Coordinator.selectionDidChange(_:)),
            name: .PDFViewSelectionChanged,
            object: view)
        defer { NotificationCenter.default.removeObserver(coordinator) }

        NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: view)

        let value = try #require(captured, "selection hook never fired")
        #expect(value.pageIndex == 0)
        #expect(!value.text.isEmpty)
        #expect(value.rect.width > 0 && value.rect.height > 0)
    }

    /// A one-page PDF carrying real, extractable text, built headlessly.
    private static func textDocument() -> PDFDocument? {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { return nil }
        context.beginPDFPage(nil)
        let attributed = NSAttributedString(
            string: "Selection bridge anchor text",
            attributes: [.font: NSFont.systemFont(ofSize: 24)])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 40, y: 600)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        return PDFDocument(data: data as Data)
    }

}
