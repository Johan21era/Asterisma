import CoreGraphics
import Foundation
import SwiftUI

// The reader-facing graph. It is deliberately a projection of the cached
// snapshot, not a live query in `body`: the sheet opens from cache when one
// exists, and the only engine work happens in the controller's explicit load.

@MainActor
struct MirageGraphSheet: View {
    let book: Book
    let chapterIndex: Int
    let chapterTitle: String

    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: MirageGraphController

    init(
        book: Book,
        chapterIndex: Int,
        chapterTitle: String,
        controller: MirageGraphController? = nil
    ) {
        self.book = book
        self.chapterIndex = chapterIndex
        self.chapterTitle = chapterTitle
        _controller = StateObject(wrappedValue: controller ?? MirageGraphController(
            book: book,
            chapterIndex: chapterIndex,
            chapterTitle: chapterTitle))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(22)
        .frame(minWidth: 760, minHeight: 560)
        .task { await controller.load() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "circle.hexagongrid")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("Mirage graph")
                    .font(.title3.bold())
                Text("\(book.title) · Chapter \(chapterIndex + 1) — \(chapterTitle)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if case .ready(let ready) = controller.state {
                sourceBadge(ready)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .idle, .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("Preparing the graph at the chapter boundary…")
                    .foregroundStyle(.secondary)
                Text("The first load may take a moment; later summons come from the local cache.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 360)

        case .ready(let ready):
            if ready.entry.snapshot.isEmpty {
                ContentUnavailableView {
                    Label("No eligible graph at this boundary", systemImage: "circle.dashed")
                } description: {
                    Text("Mirage has a stored analysis, but no accepted claims are visible through the end of the previous chapter.")
                }
                .frame(maxWidth: .infinity, minHeight: 360)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    MirageGraphCanvas(snapshot: ready.entry.snapshot)
                        .frame(maxWidth: .infinity, minHeight: 380)
                    MirageGraphLegend()
                    if ready.entry.snapshot.nodes.count > 80 {
                        Text("Showing the 80 most connected nodes of \(ready.entry.snapshot.nodes.count).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

        case .firstChapter:
            ContentUnavailableView {
                Label("The graph starts after Chapter 1", systemImage: "book.closed")
            } description: {
                Text("This graph anchors at the end of the previous chapter. Chapter 1 has no earlier boundary, so there is nothing safe to draw yet.")
            }
            .frame(maxWidth: .infinity, minHeight: 360)

        case .engineUnsupported:
            ContentUnavailableView {
                Label("The engine needs the chapter-boundary read", systemImage: "gearshape.2")
            } description: {
                Text("This Mirage build does not expose `edition_chapters` yet. The RT graph is ready; nothing was read from the ledger and no projection was sent.")
            }
            .frame(maxWidth: .infinity, minHeight: 360)

        case .unavailable(let message):
            ContentUnavailableView {
                Label("The graph is not available", systemImage: "sparkles.rectangle.stack.slash")
            } description: {
                Text(message)
            }
            .frame(maxWidth: .infinity, minHeight: 360)

        case .failed(let message):
            ContentUnavailableView {
                Label("The graph could not be prepared", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
            .frame(maxWidth: .infinity, minHeight: 360)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button("Close") { dismiss() }
                Button("Refresh") {
                    Task { await controller.load(force: true) }
                }
                .disabled(controller.state == .loading)
                Spacer()
                if case .ready(let ready) = controller.state, ready.source == .engine {
                    Text("Loaded in \(ready.milliseconds) ms")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text("Includes content through the end of Chapter \(max(chapterIndex, 1)). The current chapter is not included. "
                + "Graph nodes and edges only; claim and evidence detail remain disabled. (ADR-7 amendment 1)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sourceBadge(_ ready: MirageGraphController.Ready) -> some View {
        Text(ready.source == .cache ? "Cached" : "Engine")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }
}

// MARK: - Canvas

private struct MirageGraphCanvas: View {
    let snapshot: MirageGraphSnapshot

    var body: some View {
        GeometryReader { geometry in
            let layout = MirageGraphLayoutEngine.layout(
                snapshot: snapshot, size: geometry.size)
            Canvas { context, size in
                let positions = layout.positions
                for edge in snapshot.edges {
                    guard let source = layout.entityPositions[edge.sourceEntityID],
                          let target = layout.entityPositions[edge.targetEntityID],
                          source != target
                    else { continue }
                    var path = Path()
                    path.move(to: source)
                    path.addLine(to: target)
                    context.stroke(
                        path,
                        with: .color(.secondary.opacity(0.22)),
                        lineWidth: 1)
                }

                for node in snapshot.nodes {
                    guard let point = positions[node.id] else { continue }
                    let radius = nodeRadius(node: node, snapshot: snapshot, layout: layout)
                    let rect = CGRect(
                        x: point.x - radius, y: point.y - radius,
                        width: radius * 2, height: radius * 2)
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(color(for: node.epistemicStatus)))
                    context.stroke(
                        Path(ellipseIn: rect),
                        with: .color(.primary.opacity(0.35)),
                        lineWidth: 0.8)
                    let label = Text(shortLabel(node.label))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.primary)
                    context.draw(label, at: CGPoint(
                        x: point.x, y: point.y + radius + 8))
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary.opacity(0.18)))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.separator, lineWidth: 1))
        }
    }

    private func nodeRadius(
        node: MirageGraphNode,
        snapshot: MirageGraphSnapshot,
        layout: MirageGraphLayout
    ) -> CGFloat {
        let degree = layout.degrees[node.entityID] ?? 0
        return min(14, 6 + CGFloat(degree) * 0.6)
    }

    private func shortLabel(_ label: String) -> String {
        label.count <= 22 ? label : String(label.prefix(21)) + "…"
    }

    private func color(for status: String) -> Color {
        switch status.lowercased() {
        case "explicit_fact": return .green
        case "inference": return .blue
        case "rumor": return .orange
        case "allegation": return .red
        default: return .gray
        }
    }
}

nonisolated struct MirageGraphLayout: Equatable, Sendable {
    /// Node id → position. Multiple claim nodes may share one entity; each
    /// node still gets its own stable position.
    let positions: [String: CGPoint]
    /// Entity id → representative position, used to draw edges.
    let entityPositions: [String: CGPoint]
    let degrees: [String: Int]
    let visibleNodeIDs: Set<String>
    let hiddenNodeCount: Int
}

nonisolated enum MirageGraphLayoutEngine {
    /// Deterministic radial layout. It is intentionally not a force simulation:
    /// one pass, no convergence loop, and stable output for the same snapshot.
    static func layout(
        snapshot: MirageGraphSnapshot,
        size: CGSize,
        maxNodes: Int = 80
    ) -> MirageGraphLayout {
        var degrees: [String: Int] = [:]
        for node in snapshot.nodes { degrees[node.entityID] = 0 }
        for edge in snapshot.edges {
            if degrees[edge.sourceEntityID] != nil {
                degrees[edge.sourceEntityID, default: 0] += 1
            }
            if degrees[edge.targetEntityID] != nil {
                degrees[edge.targetEntityID, default: 0] += 1
            }
        }
        let ordered = snapshot.nodes.sorted {
            let left = degrees[$0.entityID] ?? 0
            let right = degrees[$1.entityID] ?? 0
            if left != right { return left > right }
            return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
        let visible = Array(ordered.prefix(maxNodes))
        let hidden = max(0, ordered.count - visible.count)
        guard !visible.isEmpty else {
            return MirageGraphLayout(
                positions: [:], entityPositions: [:], degrees: degrees,
                visibleNodeIDs: [], hiddenNodeCount: hidden)
        }

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxRadius = max(40, min(size.width, size.height) / 2 - 36)
        var positions: [String: CGPoint] = [:]
        var entityPositions: [String: CGPoint] = [:]
        if visible.count == 1 {
            positions[visible[0].id] = center
            entityPositions[visible[0].entityID] = center
        } else {
            var placed = 0
            var ring = 1
            while placed < visible.count {
                let count = min(ring * 6, visible.count - placed)
                let radius = min(maxRadius, CGFloat(ring) * 54)
                for offset in 0..<count {
                    let angle = (Double(offset) / Double(count)) * 2 * .pi - .pi / 2
                    let point = CGPoint(
                        x: center.x + CGFloat(cos(angle)) * radius,
                        y: center.y + CGFloat(sin(angle)) * radius)
                    let node = visible[placed + offset]
                    positions[node.id] = point
                    if entityPositions[node.entityID] == nil {
                        entityPositions[node.entityID] = point
                    }
                }
                placed += count
                ring += 1
            }
        }
        return MirageGraphLayout(
            positions: positions,
            entityPositions: entityPositions,
            degrees: degrees,
            visibleNodeIDs: Set(visible.map(\.id)),
            hiddenNodeCount: hidden)
    }
}

private struct MirageGraphLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            legend(.green, "Fact")
            legend(.orange, "Rumor")
            legend(.red, "Allegation")
            legend(.blue, "Inference")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
        }
    }
}
