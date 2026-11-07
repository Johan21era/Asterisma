import Foundation
import Testing
@testable import AsterismaV2_5

// PR-5 OPT-IN real-engine identity proof (same gate doctrine as the PR-4
// smoke): MIRAGE_REAL_ENGINE_DIR must point at the MirageV1.0 checkout. The
// committed census never depends on the engine — the suite is .enabled gated
// and vanishes from runs otherwise.
//
// MACHINERY BOUNDARY discovered tonight and honored here: one test-process can
// host exactly ONE real sidecar spawn; a SECOND sequential spawn never reaches
// its banner (permanentDown after the full [2,4,8] ladder — see M-024). All
// proofs therefore converge on ONE supervisor lifecycle inside ONE test:
//   1. `import_epub` payload {"path": …} → pinned receipt; the identity map is
//      born from it (ADR-5 Decision 3's only birth path);
//   2. identical bytes re-import → reused:true (§36.1) and the flow's
//      idempotent short-circuit leaves the map file BYTE-IDENTICAL;
//   3. read-only books_list carries the (book, edition) pair — wire export
//      wrapped as {"books": [...]} (probe-verified; ADR-5 Decision 5);
//   4. a spine document that fails decode → degraded_import, refused as
//      mapping input (ADR-5 Decision 6, P-028a) — no new entry for that book.
// Disposable ledger only (never the real one); /usr/bin/zip builds the EPUB
// fixtures (macOS system binary, same Process doctrine as the sidecar spawn).

nonisolated func mirageZipFixtureDirectory(_ staging: URL, into archive: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.arguments = ["-q", "-X", "-r", archive.path, "."]
    process.currentDirectoryURL = staging
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw MirageImportFault("zip fixture build failed with \(process.terminationStatus)")
    }
}

nonisolated struct MirageImportFault: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

nonisolated func writeMinimalRealEpubFixture(
    workDir: URL, secondSpinePageMalformed: Bool = false
) throws -> URL {
    let staging = workDir.appendingPathComponent("staging-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: staging.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
    try """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="book.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """.write(to: staging.appendingPathComponent("META-INF/container.xml"), atomically: true,
                  encoding: .utf8)
    let spinePage2 = secondSpinePageMalformed ? "<itemref idref=\"page2\"/>" : ""
    let item2 = secondSpinePageMalformed
        ? "<item id=\"page2\" href=\"page2.xhtml\" media-type=\"application/xhtml+xml\"/>"
        : ""
    try """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>Real-Engine Fixture</dc:title>
            <dc:identifier id="uid">urn:fixture:identity-real-engine</dc:identifier>
          </metadata>
          <manifest>
            <item id="page1" href="page1.xhtml" media-type="application/xhtml+xml"/>\(item2)
          </manifest>
          <spine>
            <itemref idref="page1"/>\(spinePage2)
          </spine>
        </package>
        """.write(to: staging.appendingPathComponent("book.opf"), atomically: true, encoding: .utf8)
    // NOTE: `mimetype` is intentionally absent — this engine's ingestor never
    // requires it (MirageV1.0 ingestion/epub.py opens the zip directly); the
    // fixture documents the engine-not-EPUB-spec boundary honestly.
    try """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>p1</title></head><body>
        <p>First paragraph of the real-engine identity fixture.</p>
        <p>Second paragraph keeps the unit count plural for the receipt.</p>
        </body></html>
        """.write(to: staging.appendingPathComponent("page1.xhtml"), atomically: true, encoding: .utf8)
    if secondSpinePageMalformed {
        // Unknown named reference: _decode_named_entities passes unknown names
        // through unchanged by design (P-028a); ElementTree then refuses the
        // document — the exact degraded_import production path (never guessed).
        try """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>p2</title></head><body>
            <p>A page whose &zetaunknownentity; is not in the XML five.</p>
            </body></html>
            """.write(to: staging.appendingPathComponent("page2.xhtml"), atomically: true,
                      encoding: .utf8)
    }
    let archive = workDir.appendingPathComponent("fixture-\(UUID().uuidString).epub")
    try mirageZipFixtureDirectory(staging, into: archive)
    try? FileManager.default.removeItem(at: staging)
    return archive
}

@Suite("Mirage Real Engine Identity Import (opt-in)", .enabled(if: mirageRealEngineEnabled), .serialized)
@MainActor
struct MirageIdentityRealEngineImportTests {
    @Test func realIdentityStratumConvergesOnOneSidecarLifecycle() async throws {
        let root = try makeMirageTestTempDir("realidentity")
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("disposable-ledger.sqlite3")

        var config = MirageProcessTransportConfig()
        config.bannerTimeout = 25 // cold-start import bill on a real engine
        config.responseTimeout = 25
        let supervisor = MirageSidecarSupervisor(
            configuration: .init(
                launcher: MirageProcessLauncher(
                    executableURL: try MiragePythonLocator.shared.executableURL(),
                    arguments: [mirageRealEngineDir + "/examples/mirage_sidecar.py", dbURL.path]),
                pidFileURL: root.appendingPathComponent("guard.pid"),
                transportConfig: config))
        let transport = try await supervisor.acquireTransport()
        guard supervisor.state == .ready else {
            Issue.record("supervisor did not reach ready: \(supervisor.state)")
            await supervisor.shutdown()
            return
        }
        do {
            let client = MirageClient(transport: transport, idProvider: { UUID().uuidString })
            let environment = MirageImportEnvironment(
                store: MirageIdentityMapStore(
                    fileURL: root.appendingPathComponent("mirage/identity-map.json")),
                acquireClient: { client })
            let flow = MirageImportFlow(environment: environment)
            let mapFileURL = root.appendingPathComponent("mirage/identity-map.json")

            // ---- Proofs 1–3: linked path ---------------------------------
            let epubURL = try writeMinimalRealEpubFixture(workDir: root)
            let source = MirageImportSource(rtBookID: UUID(), fileTypeIsEpub: true) { epubURL }
            let localFingerprint = try MirageSourceFingerprint.sha256Hex(fileAt: epubURL)

            // 1 · Fresh import through the REAL wire: receipt IDs derive from
            // the digest the engine computed over these bytes.
            var linkedEntry: MirageIdentityMapEntry?
            if case .linked(let entry, let reused) = await flow.performImport(source: source) {
                #expect(reused == false)
                #expect(entry.rtBookID == source.rtBookID)
                #expect(entry.mirageBookID == "book_\(String(localFingerprint.prefix(16)))")
                #expect(entry.mirageEditionID == "edition_\(String(localFingerprint.prefix(16)))")
                #expect(entry.sourceFingerprint == localFingerprint) // full 64-hex digest
                linkedEntry = entry
            } else {
                Issue.record("fresh real-engine import did not return .linked")
            }
            let bytesBefore = linkedEntry != nil ? try Data(contentsOf: mapFileURL) : Data()

            // 2 · Same bytes again: the REAL engine answers reused:true (§36.1)
            // and the flow must not write a second entry — byte-identical map.
            if let entry = linkedEntry {
                if case .linked(let second, let reusedAgain) = await flow.performImport(source: source) {
                    #expect(reusedAgain == true)
                    #expect(second == entry)
                    #expect(try Data(contentsOf: mapFileURL) == bytesBefore)
                } else {
                    Issue.record("real-engine re-import did not return .linked")
                }
            }

            // 3 · Real books_list carries the pair — the presence rule reads it.
            if let entry = linkedEntry {
                do {
                    let state = try await flow.engineVerifiedIdentityState(for: source, client: client)
                    if case .linked(let verified) = state {
                        #expect(verified.mirageEditionID == entry.mirageEditionID)
                    } else {
                        Issue.record("expected engine-verified linked, got \(state)")
                    }
                } catch {
                    Issue.record("books_list verification threw: \(error)")
                }
            }

            // 5 · PR-6 (ADR-7): engine-verified status, DETAIL-FREE — identity
            // refresh and counts row arrive from the ONE books_list response;
            // no projection/search request is ever composed; and the cursor
            // gate refuses its own cursors against the engine's real maxCursor.
            if let entry = linkedEntry {
                do {
                    let pair = try await flow.engineVerifiedIdentityAndInventory(
                        for: source, client: client)
                    guard case .linked(let verified) = pair.identity else {
                        Issue.record("expected linked status, got \(pair.identity)"); return
                    }
                    #expect(verified == entry)
                    #expect(pair.counts?.editionID == entry.mirageEditionID)
                    #expect((pair.counts?.units ?? 0) >= 1)
                    do {
                        _ = try MirageCursorGate.validatedDisclosureUnits(
                            for: .unit(pair.counts?.maxCursor ?? 1),
                            mappedEditionID: entry.mirageEditionID)
                        Issue.record("cursor gate accepted a unit cursor under the doctrine — ADR-7 violation")
                    } catch let gate as MirageCursorGateError {
                        #expect(gate.pinnedCode == "SPOILER-CURSOR-UNVERIFIED")
                    }
                } catch {
                    Issue.record("engine-verified status threw: \(error)")
                }
            }

            // ---- Proof 4: degraded receipt refuses to map (same lifecycle) --
            let degradedEpub = try writeMinimalRealEpubFixture(
                workDir: root, secondSpinePageMalformed: true)
            let degradedSource = MirageImportSource(rtBookID: UUID(), fileTypeIsEpub: true) { degradedEpub }
            if case .degradedImport(let skipped) = await flow.performImport(source: degradedSource) {
                #expect(skipped >= 1)
            } else {
                Issue.record("real-engine malformed-spine import did not degrade")
            }
            // ADR-5 Decision 6: the degraded book has NO entry — the stratum
            // still holds exactly the linked book's single active mapping.
            if let entry = linkedEntry,
               case .loaded(let map) = environment.store.load() {
                #expect(map.activeEntry(for: degradedSource.rtBookID) == nil)
                #expect(map.entries.count == 1)
                #expect(map.activeEntry(for: entry.rtBookID) != nil)
            }
        } catch {
            Issue.record("unexpected error in real-engine proofs: \(error)")
        }
        await supervisor.shutdown()
        #expect(!transport.isChildAlive())
    }
}
