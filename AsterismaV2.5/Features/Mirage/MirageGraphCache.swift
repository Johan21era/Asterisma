import Foundation

nonisolated struct MirageGraphCacheEntry: Codable, Equatable, Sendable {
    static let schemaIdentifier = "mirage-graph-cache@1"

    let schema: String
    let editionID: String
    let rtChapterIndex: Int
    let cursorUnit: Int
    let snapshot: MirageGraphSnapshot
    let cachedAt: Date
}

/// A small on-disk cache of spoiler-safe graph snapshots. The cache is the
/// reason a second summon is immediate: opening the sheet consults this before
/// the engine gate. It is derived data — deleting it loses no analysis.
@MainActor
final class MirageGraphCache {
    static let shared = MirageGraphCache(
        directory: MirageSupportPaths.mirageDirectory()
            .appendingPathComponent("graph-cache", isDirectory: true))

    static let maximumEntries = 64

    private let directory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var memory: [String: MirageGraphCacheEntry] = [:]

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        loadDiskEntries()
    }

    var count: Int { memory.count }

    func entry(editionID: String, chapterIndex: Int) -> MirageGraphCacheEntry? {
        let key = Self.key(editionID: editionID, chapterIndex: chapterIndex)
        if let hit = memory[key], valid(hit, editionID: editionID, chapterIndex: chapterIndex) {
            return hit
        }
        guard let data = try? Data(contentsOf: fileURL(for: key)),
              let entry = try? decoder.decode(MirageGraphCacheEntry.self, from: data),
              valid(entry, editionID: editionID, chapterIndex: chapterIndex)
        else { return nil }
        memory[key] = entry
        return entry
    }

    func store(_ entry: MirageGraphCacheEntry) {
        guard entry.schema == MirageGraphCacheEntry.schemaIdentifier,
              !entry.editionID.isEmpty,
              entry.rtChapterIndex > 0
        else { return }
        let key = Self.key(editionID: entry.editionID, chapterIndex: entry.rtChapterIndex)
        memory[key] = entry
        do {
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(entry)
            try data.write(to: fileURL(for: key), options: .atomic)
        } catch {
            // The in-memory hit still works for this session. A cache write is
            // never allowed to fail the graph itself.
        }
        trimToLimit()
    }

    /// Clears one edition (after its analysis changes) or every edition.
    func clear(editionID: String? = nil) {
        if let editionID {
            let keys = memory
                .filter { $0.value.editionID == editionID }
                .map(\.key)
            for key in keys {
                memory.removeValue(forKey: key)
                try? fileManager.removeItem(at: fileURL(for: key))
            }
            return
        }
        memory.removeAll()
        try? fileManager.removeItem(at: directory)
    }

    // MARK: - Disk

    private func loadDiskEntries() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let entry = try? decoder.decode(MirageGraphCacheEntry.self, from: data),
                  valid(entry, editionID: entry.editionID, chapterIndex: entry.rtChapterIndex)
            else { continue }
            memory[Self.key(editionID: entry.editionID, chapterIndex: entry.rtChapterIndex)] = entry
        }
        trimToLimit()
    }

    private func trimToLimit() {
        guard memory.count > Self.maximumEntries else { return }
        let ordered = memory.sorted { $0.value.cachedAt < $1.value.cachedAt }
        for (key, _) in ordered.prefix(memory.count - Self.maximumEntries) {
            memory.removeValue(forKey: key)
            try? fileManager.removeItem(at: fileURL(for: key))
        }
    }

    private func valid(
        _ entry: MirageGraphCacheEntry,
        editionID: String,
        chapterIndex: Int
    ) -> Bool {
        entry.schema == MirageGraphCacheEntry.schemaIdentifier
            && entry.editionID == editionID
            && entry.rtChapterIndex == chapterIndex
            && entry.cursorUnit >= 0
            && entry.snapshot.schema == MirageGraphSnapshot.schemaIdentifier
            && entry.snapshot.editionID == editionID
            && entry.snapshot.cursorUnit == entry.cursorUnit
    }

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent(key + ".json")
    }

    private static func key(editionID: String, chapterIndex: Int) -> String {
        "\(sanitize(editionID))-ch\(chapterIndex)"
    }

    private static func sanitize(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return String(value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" })
    }
}
