//  LibraryIncidentTests.swift
//  Library Safety — Phase 1 gate pins.

import Foundation
import Testing
@testable import AsterismaV2_5

@Suite("Library Safety · Phase 1 incidents", .serialized)
@MainActor
final class LibraryIncidentTests {

    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func incident(state: LibraryIncidentState = .detected) -> LibraryIncident {
        LibraryIncident(
            kind: .databaseUnreadable,
            state: state,
            trigger: .loadFailure(code: "LR-101"))
    }

    @Test("The only success path ends at resolved after verification")
    func happyPath() throws {
        var state = LibraryIncidentState.detected
        state = try LibraryIncidentStateMachine.transition(
            from: state, event: .beginFreeze)
        state = try LibraryIncidentStateMachine.transition(
            from: state, event: .frozen,
            context: LibraryIncidentTransitionContext(storeFrozen: true))
        state = try LibraryIncidentStateMachine.transition(
            from: state, event: .beginDiagnosis,
            context: LibraryIncidentTransitionContext(preservedVerified: true))
        state = try LibraryIncidentStateMachine.transition(
            from: state, event: .optionsReady,
            context: LibraryIncidentTransitionContext(diagnosisComplete: true))
        state = try LibraryIncidentStateMachine.transition(
            from: state, event: .execute,
            context: LibraryIncidentTransitionContext(confirmationValid: true))
        state = try LibraryIncidentStateMachine.transition(
            from: state, event: .verify,
            context: LibraryIncidentTransitionContext(newStoreExists: true))
        state = try LibraryIncidentStateMachine.transition(
            from: state, event: .resolved,
            context: LibraryIncidentTransitionContext(verificationPassed: true))

        #expect(state == .resolved)
        #expect(state.isTerminal)
    }

    @Test("Verification is mandatory and terminal states do not retry")
    func guards() {
        #expect(throws: LibraryIncidentTransitionError.self) {
            _ = try LibraryIncidentStateMachine.transition(
                from: .executing, event: .resolved,
                context: LibraryIncidentTransitionContext(verificationPassed: true))
        }
        #expect(throws: LibraryIncidentTransitionError.self) {
            _ = try LibraryIncidentStateMachine.transition(
                from: .verifying, event: .resolved,
                context: LibraryIncidentTransitionContext(verificationPassed: false))
        }
        #expect(throws: LibraryIncidentTransitionError.self) {
            _ = try LibraryIncidentStateMachine.transition(
                from: .resolved, event: .retry,
                context: LibraryIncidentTransitionContext(preservedIntact: true))
        }
        #expect(throws: LibraryIncidentTransitionError.self) {
            _ = try LibraryIncidentStateMachine.transition(
                from: .failed, event: .retry,
                context: LibraryIncidentTransitionContext(preservedIntact: false))
        }
    }

    @Test("Incident files round-trip atomically with private permissions")
    func storeRoundTrip() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryIncidentStore(root: root)
        var record = incident(state: .frozen)
        record.evidence = [
            LibraryEvidence(code: "sql.integrity", count: 2, bytes: 4096,
                            hash: "abc123", table: "books", enumValue: "critical")
        ]
        record = try await store.create(record)
        #expect(record.id.hasPrefix("inc_"))

        let read = try await store.read(id: record.id)
        #expect(read.id == record.id)
        #expect(read.state == .frozen)
        #expect(read.evidence.first?.code == "sql.integrity")

        let json = root.appendingPathComponent("incidents/\(record.id)/incident.json")
        let fileAttrs = try FileManager.default.attributesOfItem(atPath: json.path)
        #expect((fileAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(
            atPath: json.deletingLastPathComponent().path)
        #expect((dirAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        let scan = try await store.scan()
        #expect(scan.incidents.count == 1)
        #expect(scan.corruptIncidentIDs.isEmpty)
    }

    @Test("An unknown future enum value decodes without deleting the incident")
    func tolerantDecode() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryIncidentStore(root: root)
        let original = try await store.create(incident(state: .frozen))

        let url = root.appendingPathComponent(
            "incidents/\(original.id)/incident.json")
        var object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["state"] = "aStateFromTheFuture"
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url)

        let read = try await store.read(id: original.id)
        let scan = try await store.scan()
        #expect(read.state == .unknown)
        #expect(scan.incidents.count == 1)
    }

    @Test("A corrupt incident is reported and never deleted")
    func corruptIncidentIsPreserved() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryIncidentStore(root: root)
        let badID = "inc_corrupt"
        let dir = root.appendingPathComponent("incidents/\(badID)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload = Data("not json".utf8)
        try payload.write(to: dir.appendingPathComponent("incident.json"))

        let scan = try await store.scan()
        #expect(scan.corruptIncidentIDs == [badID])
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("incident.json").path))
        #expect(try Data(contentsOf: dir.appendingPathComponent("incident.json")) == payload)
    }

    @Test("Startup converts an interrupted recovery to failed, not resolved")
    func startupReconciliation() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryIncidentStore(root: root)
        let record = try await store.create(incident(state: .executing))

        let coordinator = LibraryHealthCoordinator(store: store)
        await coordinator.start()

        #expect(coordinator.incident?.id == record.id)
        #expect(coordinator.incident?.state == .failed)
        #expect(coordinator.incident?.kind == .recoveryInterrupted)
        #expect(coordinator.incident?.lastError?.code == "LR-007")
        let reread = try await store.read(id: record.id)
        #expect(reread.state == .failed)
    }

    @Test("A read-only storage condition opens exactly one incident")
    func readOnlyOpensIncident() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryIncidentStore(root: root)
        let coordinator = LibraryHealthCoordinator(store: store)

        await coordinator.handleStorageCondition(
            .readOnly(engine: .sqlite, code: "LR-101", message: "unreadable"))
        #expect(coordinator.incident?.readOnly == true)
        #expect(coordinator.incident?.state == .detected)

        await coordinator.handleStorageCondition(
            .readOnly(engine: .sqlite, code: "LR-102", message: "unreadable again"))
        let scan = try await store.scan()
        #expect(scan.incidents.count == 1)
    }
}
