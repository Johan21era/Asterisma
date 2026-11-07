//  CoverStore.swift
//  AsterismaV2.5
//
//  FINAL TRACES / UPGRADE #2 (Phase A): covers become content-addressed
//  FILES instead of raw Data embedded in the library payload.
//
//  WHY
//  Book.coverImageData embedded megabytes of JPEG inside library.json:
//  every save encoded them as text, every load parsed them back, every
//  @Published emission kept every decoded image resident. Covers are only
//  ever LOOKED at in ~34pt thumbnails.
//
//  DESIGN
//  • Files at <dataDir>/covers/<uuid>.jpg (uuid = stable per book id).
//  • NSCache<NSString, NSImage> for decoded reuse; evicts under pressure.
//  • Thread-safe via a private serial queue; image decode happens on the
//    caller's thread but is cached so main-thread repeats are free.
//  • Migration: DataStore load extracts any embedded coverImageData to a
//    file and nils the field (one-time, per book). Embedded data remains
//    supported as fallback for archives/pre-migration files.
//
//  SECURITY: writes confined to covers/ subdir; filenames derived from
//  UUIDs only; no user text ever becomes a path component.

import AppKit
import Foundation

final class CoverStore {
    static let shared = CoverStore()

    #if DEBUG
    /// Test-only redirect. Production always resolves to `shared`.
    static var testOverride: CoverStore?
    #endif

    /// The store every app path should use. In Debug, tests may point this at
    /// a temp directory so a full test run never mutates real app-support data.
    static var active: CoverStore {
        #if DEBUG
        testOverride ?? shared
        #else
        shared
        #endif
    }

    private let directory: URL
    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "coverstore.serial")

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            #if DEBUG
            if let testRoot = RuntimeEnvironment.isolatedStoreDirectory {
                self.directory = testRoot.appendingPathComponent("covers", isDirectory: true)
            } else {
                self.directory = Self.defaultDirectory()
            }
            #else
            self.directory = Self.defaultDirectory()
            #endif
        }
        try? FileManager.default.createDirectory(at: self.directory,
                                                 withIntermediateDirectories: true)
        cache.countLimit = 300 // decoded images are small after thumbnail use
    }

    private static func defaultDirectory() -> URL {
        if let root = AppIdentity.dataRootURL() {
            return root.appendingPathComponent("covers", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Asterisma/covers", isDirectory: true)
    }

    // MARK: - Path scheme

    nonisolated private static func fileName(forBookID id: UUID) -> String {
        "\(id.uuidString).jpg"
    }

    nonisolated func url(forBookID id: UUID) -> URL {
        directory.appendingPathComponent(Self.fileName(forBookID: id))
    }

    // MARK: - Write

    /// Stores JPEG data for a book. Overwrites silently (idempotent).
    func store(_ data: Data, forBookID id: UUID) {
        queue.sync {
            let url = url(forBookID: id)
            do {
                try data.write(to: url, options: .atomic)
                cache.removeObject(forKey: id.uuidString as NSString)
            } catch {
                print("[CoverStore] write failed for \(id.uuidString.prefix(8)): \(error)")
            }
        }
    }

    /// Convenience: rasterize + store from an NSImage.
    func store(image: NSImage, forBookID id: UUID, maxDimension: CGFloat = 600) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else { return }
        _ = maxDimension // BookCoverCapture already downscales before calling
        store(jpeg, forBookID: id)
    }

    // MARK: - Read

    /// Decoded cover for a book id, cached. Nil when none stored on disk.
    func image(forBookID id: UUID) -> NSImage? {
        if let hit = cache.object(forKey: id.uuidString as NSString) {
            return hit
        }
        let url = url(forBookID: id)
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: id.uuidString as NSString)
        return image
    }

    func hasCover(forBookID id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: url(forBookID: id).path)
    }

    // MARK: - Delete / migrate

    func remove(forBookID id: UUID) {
        queue.sync {
            try? FileManager.default.removeItem(at: url(forBookID: id))
            cache.removeObject(forKey: id.uuidString as NSString)
        }
    }

    /// Full erase: drops the decoded-image cache and every cover file, then
    /// leaves an empty covers directory ready for the next library.
    func removeAll() {
        queue.sync {
            cache.removeAllObjects()
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
    }

    /// One-time migration helper: moves embedded payload to disk.
    /// Returns true if a file was written.
    @discardableResult
    func migrateEmbedded(_ data: Data, forBookID id: UUID) -> Bool {
        guard !hasCover(forBookID: id) else { return false }
        store(data, forBookID: id)
        return true
    }
}
