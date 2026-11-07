import SwiftUI

// PR-5 minimal UI surface (owner-approved 2026-10-18): the "Analyze with
// Mirage" entry lives on the book's detail page — RT's info popover on the
// EPUB reader screen and the comic reader's chrome both present this sheet.
// 2.6: comics are eligible through the on-device OCR text edition. NEVER auto-runs: the flow starts
// only from this sheet's explicit user gesture (S10-ES-1(a)). The cancel
// affordance stays live until the end of the flow's commit path (S10-ES-1(e))
// and the resulting copy states honestly which world the cancel happened in
// (Mirage stored its work and it stays / nothing was run).
//
// This view holds NO engine machinery of its own: `MirageEngineService` owns
// the warm lifecycle (ADR-13); this sheet translates `MirageImportOutcome`
// into the owner-approved plain-language copy (`MirageOutcomeCopy`).

@MainActor
struct MirageAnalysisSheet: View {
    let book: Book

    @Environment(\.dismiss) private var dismiss
    @State private var status: Status = .idle
    @State private var cancelledRequested = false
    @StateObject private var statusController: MirageStatusController

    init(book: Book) {
        self.book = book
        _statusController = StateObject(wrappedValue: MirageStatusController(book: book))
    }

    private enum Status: Equatable {
        case idle
        case running
        case done(MirageImportOutcome)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Analyze with Mirage")
                .font(.title3.bold())
            Text("\"\(book.title)\"")
                .font(.headline)
                .foregroundColor(.secondary)
                .lineLimit(1)

            Divider()

            switch status {
            case .idle:
                if MirageSettings.isEnabled {
                    // PR-6 (ADR-7): the read-only status section — local map
                    // state renders immediately; engine verification is an
                    // explicit gesture; read-state renders from RT's own
                    // record only.
                    MirageStatusSection(controller: statusController)
                    Divider()
                    ContentUnavailableView {
                        Label("Ready to analyze", systemImage: "sparkles.rectangle.stack")
                    } description: {
                        Text(readyCopy)
                    } actions: {
                        Button("Start analysis") {
                            Task { await begin() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canAnalyze)
                        if !canAnalyze {
                            Text("Only EPUB books and comic archives can be analyzed with Mirage.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    // PR-7 disabled state (§11): honest, discoverable, and it
                    // starts nothing — and it deletes nothing either (the copy
                    // says so; there is no delete path to begin with).
                    ContentUnavailableView {
                        Label(MirageSettingsCopy.disabledHeadline,
                              systemImage: "sparkles.rectangle.stack.slash")
                    } description: {
                        Text(MirageSettingsCopy.disabledDetail)
                    }
                }
            case .running:
                HStack(spacing: 12) {
                    ProgressView()
                    Text(book.fileType.isComic
                        ? "Mirage is recognizing this comic's text…"
                        : "Mirage is reading the book…")
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Cancel") {
                        cancelledRequested = true
                    }
                }
                .padding(.vertical, 12)
            case .done(let outcome):
                Image(systemName: icon(outcome))
                    .font(.largeTitle)
                    .foregroundColor(iconColor(outcome))
                    .frame(maxWidth: .infinity, alignment: .center)
                VStack(alignment: .leading, spacing: 6) {
                    Text(MirageOutcomeCopy.headline(outcome))
                        .font(.headline)
                    Text(MirageOutcomeCopy.detail(outcome))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 440, minHeight: 300)
        .onDisappear {
            // Closing the sheet must not kill a warm engine (ADR-13), and it
            // must not silently abandon an in-flight request either. The
            // cancel flag is the only signal sent; the service stops the
            // process at idle or when Settings/app lifecycle asks.
            if status == .running { cancelledRequested = true }
        }
    }

    /// 2.6: comics are eligible through the on-device OCR text edition.
    private var canAnalyze: Bool {
        book.fileType == .epub || book.fileType.isComic
    }

    private var readyCopy: String {
        if book.fileType.isComic {
            return "Mirage will recognize this comic's text on this Mac, build a temporary text edition, and store its own analysis. RT's library, pages, and your goals are never touched."
        }
        return "Mirage will read this book's EPUB file and store its own analysis on this Mac. RT's library and your goals are never touched."
    }

    private func begin() async {
        guard status == .idle else { return }
        // PR-7: the settings toggle gates the flow itself (defense in depth —
        // the disabled state's UI already replaces the start button).
        guard MirageSettings.isEnabled else { return }
        let bookSnapshot = book
        let source = MirageAppImportMount.importSource(for: bookSnapshot)
        status = .running
        // ADR-13: one explicit gesture, one warm-service request. The service
        // resolves the runtime ladder and returns the same typed outcomes the
        // former one-shot session produced.
        let outcome = await MirageEngineService.shared.analyze(
            source: source,
            checkCancelled: { await MainActor.run { cancelledRequested } })
        status = .done(outcome)
    }

    private func icon(_ outcome: MirageImportOutcome) -> String {
        switch outcome {
        case .linked, .cancelled: return "checkmark.circle"
        case .degradedImport, .invalidReceipt, .sourceUnavailable,
             .notApplicableFileType, .analysisPreparationFailed, .mapUnreadable,
             .mapWriteFailed, .engineError, .sidecarUnavailable:
            return "exclamationmark.triangle"
        }
    }

    private func iconColor(_ outcome: MirageImportOutcome) -> Color {
        switch outcome {
        case .linked(_, true): return .orange
        case .linked: return .green
        case .cancelled: return .gray
        default: return .yellow
        }
    }
}

// MARK: - PR-6 status section (ADR-7 — read-only, never auto-running)

/// The read-only status block. Local rows come from the identity map alone;
/// the "Check with Mirage" button is the ONLY gesture that touches the engine
/// (one serialized read-only request on the warm session, ADR-13), mirroring
/// the never-auto-run doctrine the analyze flow already obeys.
@MainActor
private struct MirageStatusSection: View {
    @ObservedObject var controller: MirageStatusController
    @State private var checkRequested = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mirage status")
                .font(.subheadline.weight(.semibold))

            let local = controller.localStatus
            Text(MirageStatusCopy.headline(local))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if case .linked(let entry, let counts) = local.linkState {
                Text("Linked edition: \(entry.mirageEditionID)")
                    .font(.footnote.monospaced())
                    .foregroundColor(.secondary)
                if counts == nil, !checkRequested {
                    Text("Counts appear when you check with Mirage.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } else if case .unverifiable(let reason) = local.linkState {
                Text(reason)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else if case .mapUnreadable(let reason) = local.linkState {
                Text(reason)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            if controller.checking {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Asking Mirage (read-only check)…")
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Cancel") { controller.cancelRequested() }
                }
            } else {
                Button("Check with Mirage") {
                    checkRequested = true
                    Task { await controller.refreshEngineStatus() }
                }
                .buttonStyle(.bordered)
            }

            if let engine = controller.engineStatus {
                VStack(alignment: .leading, spacing: 4) {
                    Text(MirageStatusCopy.headline(engine))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    if case .linked(_, let counts) = engine.linkState,
                       let line = MirageStatusCopy.countsLine(counts) {
                        Text(line)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if case .unverifiable(let reason) = engine.linkState {
                        Text(reason)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if case .mapUnreadable(let reason) = engine.linkState {
                        Text(reason)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 2)
            }

            Text(MirageStatusCopy.readStateLine(
                isCompleted: controller.book.isCompleted,
                isInProgress: controller.book.isInProgress,
                currentPage: controller.book.currentPage,
                totalPages: controller.book.totalPages))
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(MirageStatusCopy.detailDisabledNote)
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await controller.refreshLocalStatus() }
    }
}
