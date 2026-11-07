//  MirageComicImportTests.swift
//  AsterismaV2.5
//
//  2.6 — identity pins for the comic import path. The engine reads the
//  derived text edition, but the ORIGINAL comic stays the identity anchor:
//  editing the comic must still drift/orphan the link, and the receipt must
//  match the derived EPUB's digest, not the comic's.

import Foundation
import Testing

@testable import AsterismaV2_5

@Suite("Mirage Comic Import", .serialized)
@MainActor
struct MirageComicImportTests {
    private struct Fixture {
        let environment: MirageImportEnvironment
        let dir: URL
        let comicURL: URL
        let editionURL: URL
        let source: MirageImportSource
        let comicFingerprint: String
        let editionFingerprint: String

        var flow: MirageImportFlow { MirageImportFlow(environment: environment) }
        var mapFileURL: URL { dir.appendingPathComponent("mirage/identity-map.json") }
    }

    private func makeFixture(
        respond: @escaping @Sendable (URL) -> Data
    ) throws -> Fixture {
        let dir = try makeMirageTestTempDir("comic-import")
        let comicURL = dir.appendingPathComponent("Volume 1.cbz")
        try Data("FAKE CBZ PAGE BYTES — comic identity fixture".utf8).write(to: comicURL)
        let editionURL = dir.appendingPathComponent("derived-edition.epub")
        try Data("DERIVED EPUB TEXT — deterministic OCR edition".utf8).write(to: editionURL)

        let comicFingerprint = try MirageSourceFingerprint.sha256Hex(fileAt: comicURL)
        let editionFingerprint = try MirageSourceFingerprint.sha256Hex(fileAt: editionURL)
        let expectedAnalysisPath = editionURL.resolvingSymlinksInPath().standardizedFileURL.path

        let transport = ScriptedTransport { requestLine in
            let value = (try? JSONDecoder().decode(MirageJSONValue.self, from: requestLine)) ?? .null
            guard case .object(let fields) = value,
                  case .string(let action) = fields["action"] ?? .null
            else {
                Issue.record("request line did not carry an action")
                return Data()
            }
            #expect(action == "import_epub")
            // The engine must receive the derived EPUB, never the CBZ.
            if case .object(let payload)? = fields["payload"],
               case .string(let path)? = payload["path"]
            {
                let received = URL(fileURLWithPath: path)
                    .resolvingSymlinksInPath().standardizedFileURL.path
                #expect(received == expectedAnalysisPath)
            } else {
                Issue.record("import_epub request did not carry a payload path")
            }
            return respond(editionURL)
        }
        let client = MirageClient(transport: transport, idProvider: { "test-id" })
        let environment = MirageImportEnvironment(
            store: MirageIdentityMapStore(
                fileURL: dir.appendingPathComponent("mirage/identity-map.json")),
            acquireClient: { client })
        let source = MirageImportSource(rtBookID: UUID(), kind: .comic) { comicURL }

        return Fixture(
            environment: environment,
            dir: dir,
            comicURL: comicURL,
            editionURL: editionURL,
            source: source,
            comicFingerprint: comicFingerprint,
            editionFingerprint: editionFingerprint)
    }

    @Test func comicLinksThroughTheDerivedEditionAndAnchorsTheComic() async throws {
        let made = try makeFixture { editionURL in
            let fingerprint = try! MirageSourceFingerprint.sha256Hex(fileAt: editionURL)
            return Self.receiptStatic(fp16: String(fingerprint.prefix(16)))
        }
        defer { try? FileManager.default.removeItem(at: made.dir) }

        let outcome = await made.flow.performImport(
            source: made.source,
            preparedComicEdition: made.editionURL)

        guard case .linked(let entry, let reused) = outcome else {
            Issue.record("comic import did not link: \(outcome)")
            return
        }
        #expect(!reused)
        #expect(entry.sourceFingerprint == made.comicFingerprint,
                "the identity anchor must be the comic's digest")
        #expect(entry.mirageEditionID == "edition_\(String(made.editionFingerprint.prefix(16)))")

        // Local re-verification hashes the comic, not the derived edition.
        #expect(made.flow.identityState(for: made.source) == .linked(entry: entry))

        // Editing the comic — not the derived edition — is the drift signal.
        try Data("CHANGED COMIC BYTES".utf8).write(to: made.comicURL)
        #expect(made.flow.identityState(for: made.source) == .orphaned(.sourceChanged))
    }

    @Test func aComicWithoutAPreparedEditionIsRefusedBeforeAnyHash() async throws {
        let made = try makeFixture { editionURL in
            let fingerprint = try! MirageSourceFingerprint.sha256Hex(fileAt: editionURL)
            return Self.receiptStatic(fp16: String(fingerprint.prefix(16)))
        }
        defer { try? FileManager.default.removeItem(at: made.dir) }

        let outcome = await made.flow.performImport(source: made.source)

        guard case .notApplicableFileType(let reason) = outcome else {
            Issue.record("expected a typed file-type refusal, got \(outcome)")
            return
        }
        #expect(reason.contains("no readable text edition"))
        #expect(!FileManager.default.fileExists(atPath: made.mapFileURL.path))
    }

    @Test func aReceiptForDifferentBytesIsRefused() async throws {
        let made = try makeFixture { _ in
            Self.receiptStatic(fp16: "0000000000000000")
        }
        defer { try? FileManager.default.removeItem(at: made.dir) }

        let outcome = await made.flow.performImport(
            source: made.source,
            preparedComicEdition: made.editionURL)

        guard case .invalidReceipt(let reason) = outcome else {
            Issue.record("expected a receipt digest refusal, got \(outcome)")
            return
        }
        #expect(reason.contains("does not match the source digest"))
        #expect(!FileManager.default.fileExists(atPath: made.mapFileURL.path))
    }

    @Test func unsupportedSourcesKeepTheirTypedRefusal() async {
        let source = MirageImportSource(rtBookID: UUID(), fileTypeIsEpub: false) { nil }
        let dir = try? makeMirageTestTempDir("comic-unsupported")
        defer { if let dir { try? FileManager.default.removeItem(at: dir) } }
        let store = MirageIdentityMapStore(
            fileURL: (dir ?? FileManager.default.temporaryDirectory)
                .appendingPathComponent("mirage/identity-map.json"))
        let flow = MirageImportFlow(environment: MirageImportEnvironment(
            store: store,
            acquireClient: { throw MirageClient.Fault.responseUnparsable(reason: "unused") }))

        let outcome = await flow.performImport(source: source)

        guard case .notApplicableFileType(let reason) = outcome else {
            Issue.record("expected a file-type refusal, got \(outcome)")
            return
        }
        #expect(reason.contains("PDFs"))
    }

    @Test func imageFolderComicsFingerprintTheirContents() throws {
        let dir = try makeMirageTestTempDir("comic-folder-fingerprint")
        defer { try? FileManager.default.removeItem(at: dir) }

        let folder = dir.appendingPathComponent("Webtoon", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("page one".utf8).write(to: folder.appendingPathComponent("001.png"))
        try Data("page two".utf8).write(to: folder.appendingPathComponent("002.png"))

        let first = try MirageSourceFingerprint.sha256Hex(sourceAt: folder)
        let stable = try MirageSourceFingerprint.sha256Hex(sourceAt: folder)
        #expect(first == stable, "an unchanged folder must hash identically")

        try Data("edited page two".utf8).write(to: folder.appendingPathComponent("002.png"))
        let edited = try MirageSourceFingerprint.sha256Hex(sourceAt: folder)
        #expect(edited != first, "editing a page must drift the folder identity")

        try FileManager.default.moveItem(
            at: folder.appendingPathComponent("001.png"),
            to: folder.appendingPathComponent("003.png"))
        let renamed = try MirageSourceFingerprint.sha256Hex(sourceAt: folder)
        #expect(renamed != edited, "renaming a page must drift the folder identity")
    }

    @Test func importSourceMapsContainersToKinds() {
        let epub = Book(
            title: "Book", author: "A",
            fileURL: URL(fileURLWithPath: "/tmp/book.epub"),
            fileType: .epub, totalPages: 1)
        let cbz = Book(
            title: "Manga", author: "A",
            fileURL: URL(fileURLWithPath: "/tmp/manga.cbz"),
            fileType: .cbz, totalPages: 1)
        let folder = Book(
            title: "Webtoon", author: "A",
            fileURL: URL(fileURLWithPath: "/tmp/webtoon", isDirectory: true),
            fileType: .comic, totalPages: 1)
        let pdf = Book(
            title: "PDF", author: "A",
            fileURL: URL(fileURLWithPath: "/tmp/book.pdf"),
            fileType: .pdf, totalPages: 1)

        #expect(MirageAppImportMount.importSource(for: epub).kind == .epub)
        #expect(MirageAppImportMount.importSource(for: cbz).kind == .comic)
        #expect(MirageAppImportMount.importSource(for: folder).kind == .comic)
        #expect(MirageAppImportMount.importSource(for: pdf).kind == .unsupported)
    }

    private nonisolated static func receiptStatic(fp16: String) -> Data {
        let json = """
        {"ok":true,"id":"test-id","result":{"status":"imported","units":7,\
        "book_id":"book_\(fp16)","edition_id":"edition_\(fp16)",\
        "reused":false,"series_hint":null}}
        """
        return Data(json.utf8)
    }
}
