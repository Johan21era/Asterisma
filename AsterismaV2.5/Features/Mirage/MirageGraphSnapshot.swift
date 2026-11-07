import Foundation

// The graph projection, decoded into a stable, cacheable value. This is a
// projection of Mirage's ledger, never a second source of truth: the snapshot
// keeps the engine's ids, labels, status strings, and positions verbatim.
//
// Claim/evidence detail remains closed. Nodes and edges are the graph surface
// enabled by ADR-7 amendment 1; no excerpt, evidence, or claim payload is
// copied here.

nonisolated struct MirageGraphNode: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let entityID: String
    let label: String
    let nodeType: String
    let epistemicStatus: String
    let confidence: Double
    let sourcePosition: Int
}

nonisolated struct MirageGraphEdge: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let sourceEntityID: String
    let targetEntityID: String
    let predicate: String
    let epistemicStatus: String
    let confidence: Double
    let sourcePosition: Int
}

nonisolated struct MirageGraphSnapshot: Codable, Equatable, Sendable {
    static let schemaIdentifier = "mirage-graph-snapshot@1"

    let schema: String
    let editionID: String
    let cursorUnit: Int
    let mode: String
    let ledgerVersion: Int
    let projectionHash: String?
    let nodes: [MirageGraphNode]
    let edges: [MirageGraphEdge]
    let fetchedAt: Date

    var isEmpty: Bool { nodes.isEmpty && edges.isEmpty }

    /// Strict decode of the engine's `projection` result. Required node and
    /// edge fields are pinned; metadata is read when present. Duplicate ids
    /// and malformed numbers refuse the snapshot rather than producing a
    /// half-graph.
    static func decode(
        _ wire: MirageJSONValue,
        editionID: String,
        cursorUnit: Int,
        now: Date = Date()
    ) -> MirageGraphSnapshot? {
        guard case .object(let fields) = wire,
              case .array(let nodeRows)? = fields["nodes"],
              case .array(let edgeRows)? = fields["edges"]
        else { return nil }
        if case .string(let returnedEdition)? = fields["edition_id"],
           returnedEdition != editionID {
            return nil
        }

        var nodes: [MirageGraphNode] = []
        var nodeIDs: Set<String> = []
        for row in nodeRows {
            guard case .object(let values) = row,
                  case .string(let nodeID)? = values["node_id"],
                  case .string(let entityID)? = values["entity_id"],
                  case .string(let label)? = values["label"],
                  case .string(let nodeType)? = values["node_type"],
                  case .string(let status)? = values["epistemic_status"],
                  let confidence = number(values["confidence"]),
                  case .int(let sourcePosition)? = values["source_position"],
                  !nodeID.isEmpty,
                  !entityID.isEmpty,
                  nodeIDs.insert(nodeID).inserted
            else { return nil }
            nodes.append(MirageGraphNode(
                id: nodeID,
                entityID: entityID,
                label: label,
                nodeType: nodeType,
                epistemicStatus: status,
                confidence: confidence,
                sourcePosition: sourcePosition))
        }

        var edges: [MirageGraphEdge] = []
        var edgeIDs: Set<String> = []
        for row in edgeRows {
            guard case .object(let values) = row,
                  case .string(let edgeID)? = values["edge_id"],
                  case .string(let source)? = values["source_entity_id"],
                  case .string(let target)? = values["target_entity_id"],
                  case .string(let predicate)? = values["predicate"],
                  case .string(let status)? = values["epistemic_status"],
                  let confidence = number(values["confidence"]),
                  case .int(let sourcePosition)? = values["source_position"],
                  !edgeID.isEmpty,
                  !source.isEmpty,
                  !target.isEmpty,
                  edgeIDs.insert(edgeID).inserted
            else { return nil }
            edges.append(MirageGraphEdge(
                id: edgeID,
                sourceEntityID: source,
                targetEntityID: target,
                predicate: predicate,
                epistemicStatus: status,
                confidence: confidence,
                sourcePosition: sourcePosition))
        }

        var mode = "read_so_far"
        var ledgerVersion = 0
        var projectionHash: String?
        if case .object(let metadata)? = fields["metadata"] {
            if case .string(let value)? = metadata["mode"] { mode = value }
            if case .int(let value)? = metadata["ledger_version"] { ledgerVersion = value }
            if case .string(let value)? = metadata["projection_hash"] { projectionHash = value }
        }

        nodes.sort { $0.id < $1.id }
        edges.sort { $0.id < $1.id }
        return MirageGraphSnapshot(
            schema: schemaIdentifier,
            editionID: editionID,
            cursorUnit: cursorUnit,
            mode: mode,
            ledgerVersion: ledgerVersion,
            projectionHash: projectionHash,
            nodes: nodes,
            edges: edges,
            fetchedAt: now)
    }

    private static func number(_ value: MirageJSONValue?) -> Double? {
        switch value {
        case .double(let number): return number
        case .int(let number): return Double(number)
        default: return nil
        }
    }
}
