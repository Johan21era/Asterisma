//  ComicMetadata.swift
//  AsterismaV2.0
//
//  2.6 — ComicInfo.xml support.
//
//  ComicInfo.xml is the de-facto metadata standard for CBZ/CBR comic
//  containers. It carries what a filename cannot: series, issue number,
//  writer, publisher, summary, genre, language, and — critically for manga,
//  manhua, and manhwa — the intended reading direction.
//
//  Metadata is an enhancement, never a gate. A missing or malformed file is a
//  metadata miss: the importer falls back to the filename title and Unknown
//  author, exactly as it did before this file existed. The pages are still
//  perfectly readable, and an unreadable metadata file must never block them.

import Foundation

// MARK: - ComicMetadata

nonisolated struct ComicMetadata: Codable, Hashable, Sendable {
    /// Series name (`<Series>`). Also written to Book.series at import.
    var series: String?
    /// Issue or chapter number, kept as text because real files use "1.5",
    /// "Annual 2", and similar non-integer values.
    var number: String?
    /// Collected volume number (`<Volume>`), when the file declares one.
    var volume: Int?
    /// Issue title (`<Title>`). ComicInfo allows this to be empty for
    /// unnumbered issues.
    var title: String?
    /// Primary author (`<Writer>`). Falls back to the penciller for art books.
    var writer: String?
    var penciller: String?
    var publisher: String?
    var summary: String?
    /// Comma-separated genre list, mapped through ReadingGenre.mapped(from:).
    var genre: String?
    /// ISO language code, typically "en" or "ja".
    var languageISO: String?
    /// Raw `<Manga>` value: "YesAndRightToLeft", "YesAndLeftToRight",
    /// "No", "Unknown", or absent.
    var manga: String?
    /// Declared total page count. The archive is authoritative; this is a hint.
    var pageCount: Int?
    /// Zero-based index of the page marked `Type="FrontCover"`.
    var coverPageIndex: Int?

    var subjects: [String] {
        guard let genre else { return [] }
        return genre
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var author: String? {
        for candidate in [writer, penciller] {
            if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty
            {
                return value
            }
        }
        return nil
    }

    /// A human title for the library row. `<Title>` wins; otherwise the series
    /// identity is composed so an issue does not land as "Unknown Title".
    var displayTitle: String? {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        guard let series = series?.trimmingCharacters(in: .whitespacesAndNewlines),
              !series.isEmpty
        else { return nil }
        if let number = number?.trimmingCharacters(in: .whitespacesAndNewlines), !number.isEmpty {
            return "\(series) #\(number)"
        }
        if let volume {
            return "\(series) Vol. \(volume)"
        }
        return series
    }

    /// Series + issue/volume identity for the details inspector.
    var seriesLabel: String? {
        guard let series = series?.trimmingCharacters(in: .whitespacesAndNewlines),
              !series.isEmpty
        else { return nil }
        if let number = number?.trimmingCharacters(in: .whitespacesAndNewlines), !number.isEmpty {
            return "\(series) #\(number)"
        }
        if let volume {
            return "\(series) Vol. \(volume)"
        }
        return series
    }

    /// The reading direction the file itself declares. nil means "not stated",
    /// which lets the importer fall back to its title heuristics rather than
    /// forcing a wrong direction on an unlabelled western comic.
    var readingMode: ComicReadingMode? {
        guard let manga = manga?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !manga.isEmpty
        else { return nil }
        switch manga {
        case "yesandrighttoleft", "yes":
            return .rightToLeft
        case "yesandlefttoright", "no":
            return .leftToRight
        default:
            // "Unknown" and unrecognised values carry no direction claim.
            return nil
        }
    }

    // MARK: - Parsing

    /// Parses ComicInfo.xml bytes. Returns nil for empty, malformed, or
    /// metadata-free documents — never throws, because metadata can never be
    /// allowed to block an import.
    static func parse(data: Data) -> ComicMetadata? {
        guard !data.isEmpty,
              let xml = try? XMLDocument(data: data, options: [])
        else { return nil }

        var metadata = ComicMetadata()
        metadata.series = text("Series", in: xml)
        metadata.number = text("Number", in: xml)
        metadata.volume = text("Volume", in: xml).flatMap { Int($0) }
        metadata.title = text("Title", in: xml)
        metadata.writer = text("Writer", in: xml)
        metadata.penciller = text("Penciller", in: xml)
        metadata.publisher = text("Publisher", in: xml)
        metadata.summary = text("Summary", in: xml)
        metadata.genre = text("Genre", in: xml)
        metadata.languageISO = text("LanguageISO", in: xml)
        metadata.manga = text("Manga", in: xml)
        metadata.pageCount = text("PageCount", in: xml).flatMap { Int($0) }
        metadata.coverPageIndex = coverPageIndex(in: xml)

        // An XML document with none of the fields we understand is not worth
        // persisting; treat it exactly like a missing ComicInfo.xml.
        return metadata == ComicMetadata() ? nil : metadata
    }

    private static func text(_ localName: String, in xml: XMLDocument) -> String? {
        guard let node = try? xml.nodes(
            forXPath: "//*[local-name()='\(localName)']"
        ).first,
              let value = node.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    /// `<Pages><Page Image="0" Type="FrontCover"/></Pages>`. ComicInfo page
    /// indices are zero-based; some tools write `Type="Cover"` instead.
    private static func coverPageIndex(in xml: XMLDocument) -> Int? {
        for type in ["FrontCover", "Cover"] {
            let xpath = "//*[local-name()='Page'][@Type='\(type)']/@Image"
            guard let value = try? xml.nodes(forXPath: xpath).first?.stringValue,
                  let index = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)),
                  index >= 0
            else { continue }
            return index
        }
        return nil
    }
}
