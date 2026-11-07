import Foundation
import Testing
@testable import AsterismaV2_5

// ADR-13 pins: one warm session, one request at a time, explicit stop, idle
// warm-down, and the disabled-feature gate. Fake session + fake transport only
// — no Python process is spawned by this suite.

@Suite("Mirage Engine Service (ADR-13)", .serialized)
@MainActor
struct MirageEngineServiceTests {
    private func makeRuntime() -> MirageRuntime {
        MirageRuntime(
            channel: .dev,
            interpreterURL: nil,
            engineRoot: URL(fileURLWithPath: "/tmp/mirage-service-test"),
            manifest: nil)
    }

    private func makeService(
        session: FakeEngineSession,
        idleInterval: TimeInterval = 60,
        factoryCalls: (@MainActor () -> Void)? = nil
    ) -> MirageEngineService {
        let runtime = makeRuntime()
        return MirageEngineService(
            runtimeProvider: { runtime },
            sessionFactory: { _ in
                factoryCalls?()
                return session
            },
            indexStore: MirageLibraryIndexStore(
                fileURL: session.directory.appendingPathComponent("library-index.json")),
            idleInterval: idleInterval)
    }

    private func enable() {
        UserDefaults.standard.set(true, forKey: MirageSettings.enabledKey)
    }

    private func clearPreference() {
        UserDefaults.standard.removeObject(forKey: MirageSettings.enabledKey)
    }

    @Test func explicitStartReusesOneSessionAndSerializesRequests() async throws {
        enable()
        defer { clearPreference() }

        let dir = try makeMirageTestTempDir("engine-service")
        defer { try? FileManager.default.removeItem(at: dir) }
        let transport = RecordingEngineTransport(delay: 0.08)
        let session = FakeEngineSession(directory: dir, transport: transport)
        let service = makeService(session: session)

        await service.start()
        #expect(service.state == .ready)
        #expect(session.acquireCount == 1)

        async let first: Void = service.withEngine { client, _ in
            _ = try await client.perform(.health)
        }
        async let second: Void = service.withEngine { client, _ in
            _ = try await client.perform(.health)
        }
        _ = try await first
        _ = try await second

        #expect(session.acquireCount == 3, "start + two requests reuse the same session")
        #expect(transport.maxConcurrent == 1, "the service gate must keep the pipe single-lane")
        #expect(service.state == .ready)
        #expect(service.requestCount == 3)

        await service.stop()
        #expect(service.state == .stopped)
        #expect(session.shutdownCount == 1)
        #expect(!service.stopPending)
    }

    @Test func idleWarmDownStopsTheSession() async throws {
        enable()
        defer { clearPreference() }

        let dir = try makeMirageTestTempDir("engine-idle")
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = FakeEngineSession(
            directory: dir, transport: RecordingEngineTransport(delay: 0))
        let service = makeService(session: session, idleInterval: 0.2)

        await service.start()
        #expect(service.state == .ready)

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline && service.state != .stopped {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(service.state == .stopped, "a warm session must not outlive its idle horizon")
        #expect(session.shutdownCount == 1)
    }

    @Test func disabledFeatureNeverBuildsASession() async {
        UserDefaults.standard.set(false, forKey: MirageSettings.enabledKey)
        defer { clearPreference() }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirage-engine-disabled-\(UUID().uuidString)")
        let transport = RecordingEngineTransport(delay: 0)
        let session = FakeEngineSession(directory: dir, transport: transport)
        var factoryCalls = 0
        let runtime = makeRuntime()
        let service = MirageEngineService(
            runtimeProvider: { runtime },
            sessionFactory: { _ in
                factoryCalls += 1
                return session
            },
            indexStore: MirageLibraryIndexStore(
                fileURL: dir.appendingPathComponent("library-index.json")),
            idleInterval: 60)

        await service.start()
        #expect(factoryCalls == 0)
        #expect(service.state == .disabled)
        #expect(session.acquireCount == 0)
    }

    @Test func stopWhileBusyWaitsForTheRequestThenShutsDown() async throws {
        enable()
        defer { clearPreference() }

        let dir = try makeMirageTestTempDir("engine-stop-busy")
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = FakeEngineSession(
            directory: dir, transport: RecordingEngineTransport(delay: 0.15))
        let service = makeService(session: session)

        let request = Task { @MainActor in
            try? await service.withEngine { client, _ in
                _ = try await client.perform(.health)
            }
        }
        try await Task.sleep(nanoseconds: 40_000_000)
        await service.stop()
        #expect(service.stopPending || service.state == .stopped)
        _ = try await request.value

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline && service.state != .stopped {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(service.state == .stopped)
        #expect(session.shutdownCount == 1)
    }
}

// MARK: - Fakes

@MainActor
private final class FakeEngineSession: MirageEngineSessionProtocol {
    let directory: URL
    let identityStore: MirageIdentityMapStore
    let transport: RecordingEngineTransport
    private(set) var acquireCount = 0
    private(set) var shutdownCount = 0
    private(set) var clearCount = 0

    init(directory: URL, transport: RecordingEngineTransport) {
        self.directory = directory
        self.transport = transport
        identityStore = MirageIdentityMapStore(
            fileURL: directory.appendingPathComponent("identity-map.json"))
    }

    var isChildAlive: Bool { true }

    func acquireClient() async throws -> MirageClient {
        acquireCount += 1
        return MirageClient(transport: transport, idProvider: { UUID().uuidString })
    }

    func clearTerminalState() {
        clearCount += 1
    }

    func shutdown() async {
        shutdownCount += 1
    }
}

/// Echoes the request id and records whether exchanges overlapped. The service
/// must never let two operations enter `exchange` at the same time.
private final class RecordingEngineTransport: MirageTransport, @unchecked Sendable {
    private let delay: TimeInterval
    private let lock = NSLock()
    private var actions: [String] = []
    private var active = 0
    private var peak = 0

    init(delay: TimeInterval) {
        self.delay = delay
    }

    var maxConcurrent: Int {
        lock.lock(); defer { lock.unlock() }
        return peak
    }

    func exchange(_ requestLine: Data) async throws -> Data {
        let value = (try? JSONDecoder().decode(MirageJSONValue.self, from: requestLine)) ?? .null
        let id = stringField(value, "id") ?? "missing-id"
        let action = stringField(value, "action") ?? "unknown"

        lock.lock()
        actions.append(action)
        active += 1
        peak = max(peak, active)
        lock.unlock()

        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        lock.lock()
        active -= 1
        lock.unlock()

        return Data(#"{"ok":true,"id":"\#(id)","result":{"api_version":"1.0.0"}}"#.utf8)
    }

    private func stringField(_ value: MirageJSONValue, _ key: String) -> String? {
        guard let field = value.field(key), case .string(let text) = field else { return nil }
        return text
    }
}
