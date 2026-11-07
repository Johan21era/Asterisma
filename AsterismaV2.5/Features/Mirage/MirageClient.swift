import Foundation

// Typed façade over the Mirage NDJSON wire (ADR-2, integration PR-3).
//
// Responsibilities kept deliberately narrow:
//   • encode request lines (id + action + optional payload);
//   • correlate responses by echoed `id` (proven engine behavior, serve.py:38-40);
//   • map envelopes onto two outcomes: success (verbatim result) or engine error
//     (verbatim {type, code, status, message} — counter-interpretation doctrine:
//     the registry never rewrites engine codes);
//   • raise TYPED client faults for RT-side structural failures (S9-ES-5 registry):
//     unparsable lines, correlation mismatch, envelope-shape violations.
//
// Transport-level failures (spawn/EOF/timeout) are rethrown unchanged — they are
// the transport's contract, not the client's. Zero RT persistence dependencies;
// zero process spawns at this layer (the pipe transport itself arrives in PR-4).

final nonisolated class MirageClient: Sendable {
    private let transport: any MirageTransport
    private let idProvider: @Sendable () -> String

    init(
        transport: any MirageTransport,
        idProvider: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.transport = transport
        self.idProvider = idProvider
    }

    /// Outcome taxonomy per ADR-2 §3 (S9-ES-5): engine verdicts are data, not
    /// thrown errors — callers decide failure-surfacing policy per PR (mirrors
    /// RT's banner/show doctrine: never print(), always typed state).
    enum Outcome: Sendable {
        case success(MirageJSONValue)
        case engineError(MirageWireErrorPayload)
    }

    enum Fault: Error, Sendable, Equatable {
        case responseUnparsable(reason: String)
        case correlationFailure(expected: String, received: String?)
        case envelopeShapeInvalid(String)
    }

    /// Sends one wire action with an RT-generated id and awaits its correlated
    /// envelope. `payload` is omitted from the line when nil (engine treats
    /// absent/`{}` identically: `request.get("payload") or {}`).
    func perform(
        _ action: MirageWireAction,
        payload: MirageJSONValue? = nil
    ) async throws -> Outcome {
        let id = idProvider()
        let request = MirageWireRequestLine(action: action, payload: payload, id: id)
        let line = try JSONEncoder().encode(request)
        let responseLine = try await transport.exchange(line)
        let envelope: MirageWireEnvelope
        do {
            envelope = try JSONDecoder().decode(MirageWireEnvelope.self, from: responseLine)
        } catch {
            throw Fault.responseUnparsable(reason: String(describing: error))
        }
        guard envelope.id == id else {
            throw Fault.correlationFailure(expected: id, received: envelope.id)
        }
        if envelope.ok {
            guard let result = envelope.result else {
                throw Fault.envelopeShapeInvalid("ok=true envelope missing result")
            }
            return .success(result)
        } else {
            guard let engineError = envelope.error else {
                throw Fault.envelopeShapeInvalid("ok=false envelope missing error object")
            }
            return .engineError(engineError)
        }
    }
}
