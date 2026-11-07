// PDFReaderView2.swift
// Wraps PDFKit's PDFView in a SwiftUI-compatible component.
// PATCHED:
//   B1 — Replace unreliable PDFViewPageChanged notification with 1 Hz polling.
//   B2 — PDFReaderScreen no longer holds @State var currentPage.
//         coordinator.currentPage is the single source of truth.
// AUDIT:
//   Task 4  — Security-scoped access is held in the Coordinator and released in
//             dismantleNSView, NOT via a defer in makeNSView. This ensures PDFKit's
//             lazy page renderer can read pages after makeNSView returns.
//   Task 6  — Polling timer invalidated in dismantleNSView (correct teardown hook).
//   Task 7  — Confirmed: no @State var currentPage in PDFReaderScreen.
//   Task 19 — PDFReaderScreen surfaces a load error via @State errorMessage.
//   Task 20 — updateNSView already guards nil document; confirmed correct.
//   Task 23 — stopPolling() and stopSecurityAccess() called from dismantleNSView.
// READER POLISH (this pass):
//   Visual — backgroundColor + pageBreakMargins give the page breathing room;
//            PDFKit renders its own native page shadow against the contrast
//            (no custom drawing added).
//   Render — interpolationQuality raised for crisper scroll/zoom rendering.
//   Zoom   — min/maxScaleFactor bound the range so autoScales can't collapse
//            a page to an illegible sliver or blow it up past usefulness.
//   Zoom   — trackManualZoom() piggybacks on the existing 1 Hz polling timer:
//            if scaleFactor moves without a bounds-size change, that's a
//            manual zoom, so autoScales is turned off to preserve it across
//            later window resizes.
//   Nothing in security-scoped access, polling cadence, the onPageChange /
//   onLoadError contracts, document loading, or teardown logic was touched.
// WP-1.3 (this pass):
//   Selection — PDFViewSelectionChanged arrives as a Notification; the
//            PDFViewDelegate protocol has no selection callback, so makeNSView
//            registers the Coordinator for its own view and deinit removes it.
//   Geometry — PDFSelectionGeometry is pure and testable: it normalizes a
//            page-space rect into a NormalizedRect (Book2.swift anchor shape)
//            clamped to 0…1, invariant to zoom, fit mode, and window size.
//   Camera   — PDFReaderScreen holds the latest selection in @State and logs
//            it only under #if DEBUG. WP-1.4 owns the UI; nothing persists yet.
//   Untouched — appearance panel, layout, fit, RTL, page-turn, polling, zoom,
//            security-scoped access, and teardown logic.

import AppKit
import PDFKit
import SwiftUI

// MARK: - PDFTextSelection (WP-1.3)

/// A reader text selection reduced to everything a durable note anchor needs:
/// the 0-based page index, the selected text (truncated), and the selection's
/// bounding rectangle in normalized page coordinates. Zoom, fit mode, and
/// window size never affect these values.
///
/// WP-1.4 owns the note editor and persistence; this value is the hand-off
/// point at the Swift boundary.
struct PDFTextSelection: Equatable {
    /// 0-based PDF page index (`document.index(for: page)`) of the first page
    /// the selection touches.
    let pageIndex: Int
    /// Selected text, truncated to `PDFSelectionGeometry.maxSelectedTextLength`
    /// characters.
    let text: String
    /// Selection bounding rectangle normalized to 0…1 against
    /// `page.bounds(for: .cropBox)`.
    let rect: NormalizedRect
}

// MARK: - PDFSelectionGeometry (WP-1.3)

/// Pure, side-effect-free geometry for PDF selection anchoring. Tests target
/// these functions with `CGRect` fixtures; nothing here touches a live
/// `PDFView`.
enum PDFSelectionGeometry {
    /// WP-1.3: the quote text is truncated to this many characters before it
    /// leaves the selection bridge, so a runaway selection can never blow up
    /// note payloads, persistence, or the UI. Applied with `prefix` on
    /// String, which counts Characters (grapheme clusters), so no partial
    /// emoji/surrogate pair is ever emitted.
    static let maxSelectedTextLength = 4_000

    /// Tolerance (in normalized units) used when checking containment against
    /// page bounds, absorbing PDFKit floating-point drift at page edges.
    private static let containmentTolerance = 0.001

    /// Maps a page-space rect plus the page's bounds to a `NormalizedRect`.
    ///
    /// The result is relative to `pageBounds` (use `page.bounds(for: .cropBox)`),
    /// so a non-zero cropBox origin is subtracted rather than baked into the
    /// output. Every component is clamped to 0…1: a rect extending past the
    /// page is cut at the page edge instead of producing out-of-range values,
    /// and degenerate or non-finite page bounds produce a zero rect.
    static func normalized(rect: CGRect, in pageBounds: CGRect) -> NormalizedRect {
        guard pageBounds.width > 0, pageBounds.height > 0 else {
            return NormalizedRect(x: 0, y: 0, width: 0, height: 0)
        }

        func clamp01(_ value: Double) -> Double {
            guard value.isFinite else { return 0 }
            return min(1.0, max(0.0, value))
        }

        let x = clamp01(Double((rect.minX - pageBounds.minX) / pageBounds.width))
        let y = clamp01(Double((rect.minY - pageBounds.minY) / pageBounds.height))
        let maxX = clamp01(Double((rect.maxX - pageBounds.minX) / pageBounds.width))
        let maxY = clamp01(Double((rect.maxY - pageBounds.minY) / pageBounds.height))

        return NormalizedRect(
            x: x,
            y: y,
            width: maxX - x,
            height: maxY - y
        )
    }

    /// Reports whether a page-space rect is usable as a selection anchor:
    /// finite and non-empty (positive width and height), and contained by the
    /// page bounds within a small tolerance. A rect extending past the page
    /// is unusable; the live path drops those rather than anchoring a note to
    /// geometry outside the page.
    static func isUsable(rect: CGRect, in pageBounds: CGRect) -> Bool {
        guard rect.width.isFinite, rect.height.isFinite, !rect.isEmpty, rect.width > 0, rect.height > 0 else { return false }
        guard pageBounds.width > 0, pageBounds.height > 0 else { return false }

        let tolerance = containmentTolerance
        func contains(_ r: CGRect, _ bounds: CGRect) -> Bool {
            r.minX >= bounds.minX - tolerance
                && r.minY >= bounds.minY - tolerance
                && r.maxX <= bounds.maxX + tolerance
                && r.maxY <= bounds.maxY + tolerance
        }
        return contains(rect, pageBounds)
    }
}

// MARK: - ReaderPDFView

/// PDFKit has no "fit width" switch. This tiny subclass applies the four
/// fit modes after every layout pass, so a window resize keeps the chosen
/// framing instead of snapping back to fit-page.
final class ReaderPDFView: PDFView {
    var fitMode: PDFFitMode = .page {
        didSet { applyFit() }
    }

    private var isApplyingFit = false

    override func layout() {
        super.layout()
        applyFit()
    }

    func applyFit() {
        guard !isApplyingFit, let page = document?.page(at: 0) else { return }
        isApplyingFit = true
        defer { isApplyingFit = false }

        switch fitMode {
        case .page:
            autoScales = true
        case .actual:
            autoScales = false
            scaleFactor = 1.0
        case .width:
            autoScales = false
            let pageWidth = page.bounds(for: .mediaBox).width
            guard pageWidth > 0 else { return }
            let available = max(1, bounds.width - pageBreakMargins.left - pageBreakMargins.right)
            scaleFactor = min(max(available / pageWidth, minScaleFactor), maxScaleFactor)
        case .height:
            autoScales = false
            let pageHeight = page.bounds(for: .mediaBox).height
            guard pageHeight > 0 else { return }
            let available = max(1, bounds.height - pageBreakMargins.top - pageBreakMargins.bottom)
            scaleFactor = min(max(available / pageHeight, minScaleFactor), maxScaleFactor)
        }
    }
}

// MARK: - PDFReaderView

struct PDFReaderView: NSViewRepresentable {
    let book: Book
    /// B2: Plain value — the coordinator is the only writer.
    let currentPage: Int
    let settings: PDFReaderSettings
    let onPageChange: (Int) -> Void
    /// TASK 19: Sentinel value (-1) signals a load failure to PDFReaderScreen.
    /// Normal page indices are ≥ 0; -1 is used exclusively for error signalling.
    let onLoadError: ((String) -> Void)?
    /// LIVE-TEST LT-3b: fired exactly once per successful document open so the
    /// screen can start its reading session on REALITY instead of optimism.
    let onLoadSuccess: (() -> Void)?
    /// WP-1.3: fired when the user changes the text selection. Fires with a
    /// value for a usable, non-whitespace selection and with `nil` when the
    /// selection is cleared, so the screen cannot keep showing a stale anchor.
    let onSelection: ((PDFTextSelection?) -> Void)?

    init(book: Book,
         currentPage: Int,
         settings: PDFReaderSettings = .defaults,
         onPageChange: @escaping (Int) -> Void,
         onLoadError: ((String) -> Void)? = nil,
         onLoadSuccess: (() -> Void)? = nil,
         onSelection: ((PDFTextSelection?) -> Void)? = nil)
    {
        self.book = book
        self.currentPage = currentPage
        self.settings = settings
        self.onPageChange = onPageChange
        self.onLoadError = onLoadError
        self.onLoadSuccess = onLoadSuccess
        self.onSelection = onSelection
    }

    func makeNSView(context: Context) -> ReaderPDFView {
        print("🔍 [PDFReaderView] makeNSView called for book: \(book.title)")
        print("🔍 [PDFReaderView] Original fileURL: \(book.fileURL.path)")
        print("🔍 [PDFReaderView] Has bookmarkData: \(book.bookmarkData != nil)")

        let view = ReaderPDFView()
        view.displayMode = settings.layout.displayMode
        view.displayDirection = .vertical
        view.delegate = context.coordinator
        // WP-1.3: PDFViewDelegate has no selection callback. PDFKit delivers
        // selection changes only as this notification, observed on this view
        // so the Coordinator can never receive another view's selections.
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.selectionDidChange(_:)),
            name: .PDFViewSelectionChanged,
            object: view)

        // READER POLISH: visual presentation.
        // Stock PDFView has no page insets and no contrast against its own
        // background, so the page reads as a flat rectangle wallpapered onto
        // the window. A comfortable inset plus a contrasting system backdrop
        // reproduces the "page floating on a mat" look of Preview.app/Books —
        // PDFKit renders the page's drop shadow natively against that
        // background; nothing here draws anything by hand. Side margins are
        // slightly larger than the page-to-page gap, echoing the proportions
        // of a printed page's own margins.
        view.backgroundColor = settings.background.nsColor
        view.displaysPageBreaks = settings.layout != .single
        view.pageBreakMargins = settings.pageBreakMargins
        view.displaysAsBook = settings.coverAlone
        view.displaysRTL = settings.readingDirection.isRTL

        // READER POLISH: rendering quality.
        // Keeps glyph edges and images crisp while scrolling or zoomed past
        // 100%, instead of the coarser default sampling.
        view.interpolationQuality = .high

        // READER POLISH: zoom range.
        // Unconfigured min/maxScaleFactor leave very little headroom to zoom
        // in for detail or out for an overview, and don't stop autoScales
        // from blowing a small page up into a blurry, oversized fit. These
        // bounds are generous but finite in both directions.
        view.minScaleFactor = 0.25
        view.maxScaleFactor = 6.0
        view.fitMode = settings.fit

        // Security-scoped access: resolve URL and start accessing before reading.
        guard let resolvedURL = book.resolveURL() else {
            let msg = "Could not resolve file URL for \(book.title)"
            print("❌ PDF ERROR: \(msg)")
            DispatchQueue.main.async { self.onLoadError?(msg) }
            return view
        }

        print("🔍 [PDFReaderView] Resolved URL: \(resolvedURL.path)")
        print("🔍 [PDFReaderView] File exists: \(FileManager.default.fileExists(atPath: resolvedURL.path))")

        let didStartAccess = resolvedURL.startAccessingSecurityScopedResource()
        print("🔍 [PDFReaderView] Security scope started: \(didStartAccess)")

        guard didStartAccess else {
            let msg = "Could not access security-scoped resource for \(book.title)"
            print("❌ PDF ERROR: \(msg)")
            DispatchQueue.main.async { self.onLoadError?(msg) }
            return view
        }

        // TASK 4 FIX: DO NOT use `defer` here to stop security access.
        //
        // Rationale: PDFKit with .singlePageContinuous renders pages lazily.
        // The actual file read for individual pages happens AFTER makeNSView
        // returns (on PDFKit's internal render queue), which is AFTER any defer
        // block fires. Stopping access inside makeNSView causes blank pages,
        // rendering gaps, or crashes on large PDFs.
        //
        // Solution: Store resolvedURL in the Coordinator. Call stopSecurityAccess()
        // from dismantleNSView (the correct NSViewRepresentable teardown hook),
        // which is called by SwiftUI when the view is permanently removed from
        // the hierarchy — guaranteeing the scope is held for the full PDF lifetime.
        //
        // Original (WRONG):
        //   defer { resolvedURL.stopAccessingSecurityScopedResource() }
        //
        // Fixed: see dismantleNSView below and Coordinator.stopSecurityAccess().
        context.coordinator.startSecurityAccess(url: resolvedURL)

        print("🔍 [PDFReaderView] Creating PDFDocument from resolved URL")
        guard let doc = PDFDocument(url: resolvedURL) else {
            let msg = "Could not open PDF document for \(book.title)"
            print("❌ PDF ERROR: \(msg)")
            // Release scope immediately — no document was created
            context.coordinator.stopSecurityAccess()
            DispatchQueue.main.async { self.onLoadError?(msg) }
            return view
        }

        print("✅ [PDFReaderView] PDFDocument created successfully, pageCount: \(doc.pageCount)")

        view.document = doc
        view.applyFit()
        if currentPage > 0, let page = doc.page(at: currentPage) {
            print("🔍 [PDFReaderView] Navigating to page: \(currentPage)")
            view.go(to: page)
        }

        // B1 FIX: start deterministic 1 Hz polling instead of relying on
        // PDFViewPageChanged (which only fires on "topmost page" changes in
        // continuous scroll mode, not on every page the user passes through).
        context.coordinator.startPolling(view: view)

        print("✅ [PDFReaderView] makeNSView completed successfully")
        DispatchQueue.main.async { self.onLoadSuccess?() }
        return view
    }

    func updateNSView(_ nsView: ReaderPDFView, context _: Context) {
        // TASK 20 (confirmed): guard nil document — no security access started here.
        guard let doc = nsView.document else { return }

        let layoutChanged = nsView.displayMode != settings.layout.displayMode
        if layoutChanged {
            nsView.displayMode = settings.layout.displayMode
        }
        nsView.displaysPageBreaks = settings.layout != .single
        nsView.backgroundColor = settings.background.nsColor
        nsView.displaysAsBook = settings.coverAlone
        nsView.displaysRTL = settings.readingDirection.isRTL

        let margins = settings.pageBreakMargins
        let marginsChanged = nsView.pageBreakMargins.top != margins.top
            || nsView.pageBreakMargins.left != margins.left
            || nsView.pageBreakMargins.bottom != margins.bottom
            || nsView.pageBreakMargins.right != margins.right
        if marginsChanged {
            nsView.pageBreakMargins = margins
        }

        if nsView.fitMode != settings.fit {
            nsView.fitMode = settings.fit
        } else if marginsChanged || layoutChanged {
            nsView.applyFit()
        }
        // Only jump if the external currentPage differs from what's displayed.
        // This is purely a playback path (e.g. restoring a saved position).
        if let displayed = nsView.currentPage,
           doc.index(for: displayed) != currentPage,
           let target = doc.page(at: currentPage)
        {
            nsView.go(to: target)
        }
    }

    /// TASK 6 / TASK 23: dismantleNSView is the correct NSViewRepresentable teardown
    /// hook. It is called when SwiftUI permanently removes the view from the hierarchy
    /// (not on every re-render). This is where we:
    ///   1. Stop the 1 Hz polling timer (prevents run-loop retain cycles).
    ///   2. Release the security-scoped resource (balances startAccessingSecurityScopedResource
    ///      from makeNSView, allowing PDFKit to finish any in-flight page renders first).
    static func dismantleNSView(_ nsView: ReaderPDFView, coordinator: Coordinator) {
        coordinator.stopPolling() // TASK 6 / TASK 23
        coordinator.stopSelectionObservation() // WP-1.3 / CR-1
        coordinator.stopSecurityAccess() // TASK 4 / TASK 23
        nsView.document = nil // Release PDFDocument before scope ends
        print("🔍 [PDFReaderView] dismantleNSView: timer stopped, security scope released")
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPageChange: onPageChange,
                    onSelection: onSelection)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, PDFViewDelegate {
        let onPageChange: (Int) -> Void
        /// WP-1.3: published with the selection, or `nil` when it is cleared.
        let onSelection: ((PDFTextSelection?) -> Void)?

        // B1: polling state
        private var pollingTimer: Timer?
        private var lastReportedPage: Int = -1

        /// TASK 4: Security-scoped URL held for the lifetime of the PDFView.
        /// Nil when no scope is active (before makeNSView or after dismantleNSView).
        private var securityScopedURL: URL?

        // READER POLISH: zoom-preservation state — see trackManualZoom(on:).
        private var userHasCustomZoom = false
        private var lastKnownBoundsSize: CGSize?
        private var lastKnownScaleFactor: CGFloat?

        init(onPageChange: @escaping (Int) -> Void,
             onSelection: ((PDFTextSelection?) -> Void)? = nil) {
            self.onPageChange = onPageChange
            self.onSelection = onSelection
        }

        deinit {
            // Defensive cleanup — dismantleNSView should have fired first.
            NotificationCenter.default.removeObserver(self)
            pollingTimer?.invalidate()
            securityScopedURL?.stopAccessingSecurityScopedResource()
        }

        /// TASK 4: Called from makeNSView after successfully starting access.
        func startSecurityAccess(url: URL) {
            // If a previous URL is still held, release it first (shouldn't happen
            // in normal usage, but guards against view reuse edge cases).
            stopSecurityAccess()
            securityScopedURL = url
        }

        /// TASK 4 / TASK 23: Called from dismantleNSView to release the scope.
        func stopSecurityAccess() {
            securityScopedURL?.stopAccessingSecurityScopedResource()
            securityScopedURL = nil
        }

        /// CR-1: the selection observer must come off in `dismantleNSView`,
        /// which is the deterministic teardown hook, not only in `deinit`.
        func stopSelectionObservation() {
            NotificationCenter.default.removeObserver(
                self, name: .PDFViewSelectionChanged, object: nil)
        }

        /// B1 FIX: 1 Hz timer; fires onPageChange only when page actually changes.
        func startPolling(view: PDFView) {
            pollingTimer?.invalidate()

            // READER POLISH: fresh zoom-tracking baseline for this PDFView.
            userHasCustomZoom = false
            lastKnownBoundsSize = nil
            lastKnownScaleFactor = nil

            pollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self, weak view] _ in
                guard let self, let view else { return }

                // READER POLISH: independent of page detection below — never
                // changes lastReportedPage and never touches onPageChange.
                self.trackManualZoom(on: view)

                guard let page = view.currentPage,
                      let doc = view.document else { return }
                let idx = doc.index(for: page)
                guard idx != self.lastReportedPage else { return }
                self.lastReportedPage = idx
                self.onPageChange(idx)
            }
        }

        /// TASK 6 / TASK 23: Called from dismantleNSView.
        func stopPolling() {
            pollingTimer?.invalidate()
            pollingTimer = nil
        }

        /// READER POLISH: detects a user-driven zoom (trackpad pinch, ⌘+/⌘-, or
        /// any other path that changes scaleFactor) so it survives window
        /// resizing instead of snapping back to fit-to-page on the next layout
        /// pass.
        ///
        /// autoScales recomputes scaleFactor to match the view's bounds on
        /// every bounds change, so a genuine window resize always moves
        /// scaleFactor and bounds.size together within the same tick. If
        /// scaleFactor moves while bounds.size does not, the only remaining
        /// explanation is a manual zoom — at that point autoScales is turned
        /// off so the chosen zoom level is preserved through future resizes.
        /// A newly opened book gets a fresh Coordinator (see makeCoordinator
        /// and the NavigationLink call sites in NewContentView),
        /// so this state never leaks from one book to the next.
        private func trackManualZoom(on view: PDFView) {
            let boundsSize = view.bounds.size
            let scale = view.scaleFactor

            defer {
                lastKnownBoundsSize = boundsSize
                lastKnownScaleFactor = scale
            }

            guard !userHasCustomZoom,
                  let lastBounds = lastKnownBoundsSize,
                  let lastScale = lastKnownScaleFactor,
                  lastBounds == boundsSize,
                  abs(lastScale - scale) > 0.001
            else { return }

            userHasCustomZoom = true
            view.autoScales = false
        }

        // MARK: PDFViewDelegate — selection (WP-1.3)

        /// WP-1.3: `PDFViewDelegate` declares no selection callback, so this is
        /// reached through the `.PDFViewSelectionChanged` observer that
        /// `makeNSView` registers for this Coordinator's own view. nil and
        /// whitespace-only selections are ignored; a usable selection is
        /// reduced to a PDFTextSelection and published.
        @objc func selectionDidChange(_ notification: Notification) {
            guard let view = notification.object as? PDFView else { return }

            // A deselected view must clear the cursor; leaving the previous
            // value standing would present a stale anchor as if still selected.
            guard let selection = view.currentSelection,
                  let doc = view.document,
                  let page = selection.pages.first
            else {
                onSelection?(nil)
                return
            }

            // Empty / whitespace-only selections are not anchors.
            let rawText = selection.string ?? ""
            guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                onSelection?(nil)
                return
            }

            let pageBounds = page.bounds(for: .cropBox)
            let selectionRect = selection.bounds(for: page)
            guard PDFSelectionGeometry.isUsable(rect: selectionRect, in: pageBounds) else { return }

            // CR-1 defect fixed here: `selection.string` spans every page the
            // selection touches, but the anchor names only the first page's
            // rect. Take that page's own text so the quote and the rect always
            // describe the same text.
            let firstPageText: String
            if selection.pages.count > 1 {
                firstPageText = page.selection(for: selection.bounds(for: page))?.string ?? rawText
            } else {
                firstPageText = rawText
            }
            let truncated = String(firstPageText.prefix(PDFSelectionGeometry.maxSelectedTextLength))
            let value = PDFTextSelection(
                pageIndex: doc.index(for: page),
                text: truncated,
                rect: PDFSelectionGeometry.normalized(rect: selectionRect, in: pageBounds)
            )
            // PDFKit posts this on the main thread today; hop defensively so a
            // future off-main post cannot write SwiftUI state off-main.
            if Thread.isMainThread {
                onSelection?(value)
            } else {
                DispatchQueue.main.async { [onSelection] in onSelection?(value) }
            }
        }
    }
}

// MARK: - PDFReaderScreen

/// B2 FIX: @State var currentPage removed entirely.
/// coordinator.currentPage is the single authoritative source; this view
/// observes it via @ObservedObject and passes it read-only to PDFReaderView.
///
/// TASK 19: errorMessage state added so PDF load failures surface to the user.
struct PDFReaderScreen: View {
    let book: Book
    @ObservedObject var coordinator: SessionCoordinator
    @Environment(\.dismiss) private var dismiss

    /// TASK 19: Populated when PDFReaderView signals a load failure.
    @State private var errorMessage: String?

    /// WP-1.3: the latest usable text selection from the PDF view. The packet
    /// ends here — no persistence, no note editor; WP-1.4 owns the UI.
    /// Cleared whenever the page changes so a stale anchor is never shown.
    @State private var latestSelection: PDFTextSelection?

    @AppStorage("reader.pdf.layout") private var pdfLayout: String = PDFPageLayout.continuous.rawValue
    @AppStorage("reader.pdf.fit") private var pdfFit: String = PDFFitMode.page.rawValue
    @AppStorage("reader.pdf.background") private var pdfBackground: String = PDFReaderBackground.system.rawValue
    @AppStorage("reader.pdf.pageGap") private var pdfPageGap: Double = PDFReaderSettings.defaults.pageGap
    @AppStorage("reader.pdf.coverAlone") private var pdfCoverAlone = PDFReaderSettings.defaults.coverAlone
    @AppStorage("reader.pdf.readingDirection") private var pdfReadingDirection: String = PDFReadingDirection.leftToRight.rawValue
    @AppStorage("reader.brightness") private var readerBrightness: Double = 1.0
    @State private var showingPDFAppearance = false

    /// P5 Feature 3: RSVP speed-reading over the extracted document text.
    @AppStorage("rsvp.enabled") private var rsvpEnabled = true
    @State private var rsvpText: String?
    @State private var showingRSVP = false
    /// G1: held so dismissal can actually cancel the whole-document extraction.
    @State private var rsvpTask: Task<Void, Never>?

    init(book: Book, coordinator: SessionCoordinator) {
        self.book = book
        self.coordinator = coordinator
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if let error = errorMessage {
                // TASK 19: Show an error overlay instead of a blank screen.
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.red)
                    Text("Could Not Open PDF")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text(error)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PDFReaderView(
                    book: book,
                    currentPage: coordinator.currentPage, // read-only; coordinator is the writer
                    settings: pdfSettings,
                    onPageChange: { newPage in
                        // WP-1.3: a changed page invalidates the selection —
                        // clear before the coordinator turns, so a stale
                        // normalized rect can never outlive its page.
                        latestSelection = nil
                        // onPageChange callback → coordinator is the only entity that
                        // writes currentPage, which in turn updates DataStore.
                        coordinator.turnToPage(newPage)
                    },
                    onLoadError: { message in
                        // TASK 19: Surface the error to the user.
                        errorMessage = message
                    },
                    // LIVE-TEST LT-3b: the reading session begins when the
                    // document EXISTS — never while an error screen is showing.
                    onLoadSuccess: {
                        coordinator.startReading(bookID: book.id, page: coordinator.currentPage)
                    },
                    // WP-1.3: hold the latest selection; nil clears it. DEBUG
                    // logging only — no UI consumes the value yet.
                    onSelection: { selection in
                        latestSelection = selection
                        #if DEBUG
                        if let selection {
                            let r = selection.rect
                            print("📝 [PDFReaderScreen] selection captured — page \(selection.pageIndex + 1), \(selection.text.count) chars (cap \(PDFSelectionGeometry.maxSelectedTextLength)), rect (\(r.x), \(r.y), \(r.width), \(r.height))")
                        } else {
                            print("📝 [PDFReaderScreen] selection cleared")
                        }
                        #endif
                    }
                )
                .overlay {
                    ReaderBrightnessOverlay(brightness: readerBrightness)
                }

                pdfBottomControls
                    .padding(.bottom, 14)
            }
        }
        .background(
            KeyNavigationConfigurator(isEnabled: errorMessage == nil, onCommand: handlePDFKey)
        )
        .popover(isPresented: $showingPDFAppearance) {
            pdfAppearancePanel
        }
        .sheet(isPresented: $showingRSVP) {
            if let text = rsvpText {
                RSVPReaderView(text: text) { showingRSVP = false }
                    .frame(minWidth: 720, minHeight: 520)
            }
        }
        .onDisappear {
            rsvpTask?.cancel()
            rsvpTask = nil
            coordinator.endCurrentSession()
        }
    }

    private var pdfSettings: PDFReaderSettings {
        PDFReaderSettings(
            layout: PDFPageLayout(rawValue: pdfLayout) ?? .continuous,
            fit: PDFFitMode(rawValue: pdfFit) ?? .page,
            background: PDFReaderBackground(rawValue: pdfBackground) ?? .system,
            pageGap: pdfPageGap,
            coverAlone: pdfCoverAlone,
            readingDirection: PDFReadingDirection(rawValue: pdfReadingDirection) ?? .leftToRight
        )
    }

    private var pdfPageCount: Int {
        max(book.totalPages, 1)
    }

    private var pdfBottomControls: some View {
        HStack(spacing: 12) {
            Button {
                turnPDFPage(-1)
            } label: {
                Image(systemName: pdfSettings.readingDirection.isRTL ? "chevron.right" : "chevron.left")
            }
            .accessibilityLabel("Previous page")
            .disabled(coordinator.currentPage <= 0)

            Text("\(coordinator.currentPage + 1) / \(pdfPageCount)")
                .monospacedDigit()
                .frame(minWidth: 64)

            ProgressView(value: Double(coordinator.currentPage + 1) / Double(pdfPageCount))
                .progressViewStyle(.linear)
                .frame(width: 76)

            Button {
                turnPDFPage(1)
            } label: {
                Image(systemName: pdfSettings.readingDirection.isRTL ? "chevron.left" : "chevron.right")
            }
            .accessibilityLabel("Next page")
            .disabled(coordinator.currentPage + 1 >= pdfPageCount)

            Divider().frame(height: 20)

            Button {
                showingPDFAppearance = true
            } label: {
                Label("Appearance", systemImage: "textformat.size")
            }
            .help("PDF layout, fit, background, and brightness")

            if rsvpEnabled {
                Button {
                    loadRSVPText()
                } label: {
                    Label("Speed Read", systemImage: "hare")
                }
                .help("Speed-read this document (RSVP)")
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }

    private var pdfAppearancePanel: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PDF Appearance")
                        .font(.headline)
                    Text("Frame the page; the PDF keeps its own typography.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { showingPDFAppearance = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    pdfSection("Comfort") {
                        HStack {
                            Text("Brightness")
                                .font(.callout)
                            Spacer()
                            Text("\(Int(readerBrightness * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: $readerBrightness,
                            in: ReaderComfort.brightnessRange,
                            step: 0.01
                        )
                        Text("Dims the page only; the controls stay at full brightness.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    pdfSection("Page Layout") {
                        HStack {
                            Text("Layout")
                                .font(.callout)
                            Spacer()
                            Picker("Layout", selection: $pdfLayout) {
                                ForEach(PDFPageLayout.allCases) { option in
                                    Text(option.displayName).tag(option.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(width: 190)
                            .help(pdfSettings.layout.helpText)
                        }

                        HStack {
                            Text("Fit")
                                .font(.callout)
                            Spacer()
                            Picker("Fit", selection: $pdfFit) {
                                ForEach(PDFFitMode.allCases) { option in
                                    Text(option.displayName).tag(option.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(width: 190)
                            .help(pdfSettings.fit.helpText)
                        }

                        Toggle("Cover Alone", isOn: $pdfCoverAlone)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .font(.callout)
                            .disabled(pdfLayout != PDFPageLayout.facing.rawValue
                                && pdfLayout != PDFPageLayout.facingContinuous.rawValue)
                            .help("In facing layouts, show page one by itself like a book cover")
                    }

                    Divider()

                    pdfSection("Reading") {
                        HStack {
                            Text("Direction")
                                .font(.callout)
                            Spacer()
                            Picker("Direction", selection: $pdfReadingDirection) {
                                ForEach(PDFReadingDirection.allCases) { direction in
                                    Text(direction.displayName).tag(direction.rawValue)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 210)
                        }

                        HStack {
                            Text("Page Gap")
                                .font(.callout)
                            Spacer()
                            Text("\(Int(pdfPageGap)) pt")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: $pdfPageGap,
                            in: PDFReaderSettings.pageGapRange,
                            step: 1
                        )
                        .disabled(pdfLayout == PDFPageLayout.single.rawValue)
                        .opacity(pdfLayout == PDFPageLayout.single.rawValue ? 0.5 : 1)

                        Text("Right to left flips the page order for manga; page numbers and resume positions stay unchanged. Page gap adds breathing room around each page in scrolling layouts.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    pdfSection("Page Background") {
                        Picker("Background", selection: $pdfBackground) {
                            ForEach(PDFReaderBackground.allCases) { option in
                                Text(option.displayName).tag(option.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        Text("PDFs keep the publisher's font, size, and spacing. Use an EPUB for reflowable typography controls.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(18)
            }

            Divider()

            HStack {
                Button("Reset PDF Appearance") { resetPDFAppearance() }
                    .buttonStyle(.link)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: 400, height: 500)
    }

    private func pdfSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.8)
            content()
        }
    }

    private func resetPDFAppearance() {
        pdfLayout = PDFReaderSettings.defaults.layout.rawValue
        pdfFit = PDFReaderSettings.defaults.fit.rawValue
        pdfBackground = PDFReaderSettings.defaults.background.rawValue
        pdfPageGap = PDFReaderSettings.defaults.pageGap
        pdfCoverAlone = PDFReaderSettings.defaults.coverAlone
        pdfReadingDirection = PDFReaderSettings.defaults.readingDirection.rawValue
        readerBrightness = 1.0
    }

    private func turnPDFPage(_ delta: Int) {
        let target = min(max(coordinator.currentPage + delta, 0), pdfPageCount - 1)
        guard target != coordinator.currentPage else { return }
        coordinator.turnToPage(target)
    }

    private func handlePDFKey(_ command: KeyNavigationCommand) -> Bool {
        let rtl = pdfSettings.readingDirection.isRTL
        switch command {
        case .left:
            turnPDFPage(rtl ? 1 : -1)
            return true
        case .right:
            turnPDFPage(rtl ? -1 : 1)
            return true
        case .up:
            turnPDFPage(-1)
            return true
        case .down:
            turnPDFPage(1)
            return true
        case .escape:
            dismiss()
            return true
        case .returnKey:
            return false
        }
    }

    /// Extracts the document's full text for RSVP streaming.
    /// HOTFIX (stall report): whole-document text extraction is O(pages) and
    /// previously ran on main — a large PDF froze the app solid. Now detached;
    /// the security scope travels with the task and is released inside it.
    private func loadRSVPText() {
        guard let resolvedURL = book.resolveURL() else { return }

        // G1 FIX: cancel any previous extraction, and keep the handle so
        // onDisappear can cancel this one. Previously Task.isCancelled could
        // never become true because nothing held or cancelled the task.
        rsvpTask?.cancel()
        rsvpTask = Task.detached(priority: .userInitiated) {
            let didStart = resolvedURL.startAccessingSecurityScopedResource()
            defer { if didStart { resolvedURL.stopAccessingSecurityScopedResource() } }

            guard let doc = PDFDocument(url: resolvedURL) else { return }
            var extracted: [String] = []
            extracted.reserveCapacity(doc.pageCount)
            for i in 0 ..< doc.pageCount {
                if Task.isCancelled { return }
                if let pageText = doc.page(at: i)?.string {
                    extracted.append(pageText)
                }
            }
            guard !Task.isCancelled else { return }
            let joined = extracted.joined(separator: "\n\n")
            guard !joined.isEmpty else { return }

            await MainActor.run {
                guard !Task.isCancelled else { return }
                rsvpText = joined
                showingRSVP = true
            }
        }
    }
}
