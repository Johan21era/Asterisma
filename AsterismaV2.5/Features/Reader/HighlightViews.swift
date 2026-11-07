//  HighlightViews.swift
//  AsterismaV2.5
//
//  WP-1.4: the extracted annotation UI shared by EPUB, PDF, and
//  BookDetailsView. One editor, one row, one reader action bar, one editor
//  popover — there is deliberately no reader-local copy of any of these
//  (extraction rule: BookDetailsView must no longer define its own editor).
//
//  Every view here is a pure consumer of the model and callbacks. None of
//  them touches DataStore: persistence happens only through
//  `DataStore.upsertNote(_:inBook:)` / `deleteNote(id:inBook:)` in the
//  owning callers (the single mutation path, WP-1.4 requirement 2).

import AppKit
import SwiftUI

// MARK: - AnnotationColor presentation

extension AnnotationColor {
    /// SwiftUI swatch color for the highlight color controls. Rough hex
    /// approximations of the stored color names; also mirrored in the
    /// EPUB highlight script's JS color table so both renderers agree.
    var swatchColor: Color {
        switch self {
        case .yellow: return Color(red: 1.00, green: 0.85, blue: 0.35)
        case .green: return Color(red: 0.72, green: 0.89, blue: 0.69)
        case .blue: return Color(red: 0.66, green: 0.78, blue: 0.96)
        case .pink: return Color(red: 0.96, green: 0.72, blue: 0.82)
        case .purple: return Color(red: 0.83, green: 0.72, blue: 0.96)
        }
    }

    /// WP-1.4: AppKit counterpart for PDF highlight annotations. Kept in
    /// step with `swatchColor` so the reader and the library rows agree;
    /// the alpha lets the page text read through the mark.
    var nsColor: NSColor {
        switch self {
        case .yellow: return NSColor(red: 1.00, green: 0.85, blue: 0.35, alpha: 0.45)
        case .green: return NSColor(red: 0.72, green: 0.89, blue: 0.69, alpha: 0.45)
        case .blue: return NSColor(red: 0.66, green: 0.78, blue: 0.96, alpha: 0.45)
        case .pink: return NSColor(red: 0.96, green: 0.72, blue: 0.82, alpha: 0.45)
        case .purple: return NSColor(red: 0.83, green: 0.72, blue: 0.96, alpha: 0.45)
        }
    }

    var displayName: String {
        switch self {
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .pink: return "Pink"
        case .purple: return "Purple"
        }
    }
}

// MARK: - ColorSwatchRow

/// WP-1.4: the five highlight-color swatches, used identically by the
/// reader action bar (to set the DEFAULT color) and the editor popover
/// (to set THIS note's color).
struct ColorSwatchRow: View {
    let selection: AnnotationColor
    let onSelect: (AnnotationColor) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AnnotationColor.allCases, id: \.self) { color in
                Button {
                    onSelect(color)
                } label: {
                    Circle()
                        .fill(color.swatchColor)
                        .overlay(
                            Circle().strokeBorder(
                                selection == color ? Color.accentColor : Color.primary.opacity(0.15),
                                lineWidth: selection == color ? 2 : 1
                            )
                        )
                        .frame(width: 18, height: 18)
                        .padding(2)
                }
                .buttonStyle(.plain)
                .help("\(color.displayName) highlight")
                .accessibilityLabel("\(color.displayName) highlight color")
                .accessibilityValue(selection == color ? "Selected" : "")
            }
        }
    }
}

// MARK: - BookNoteEditorView

/// WP-1.4: THE shared note editor. EPUB, PDF, and BookDetailsView all use
/// this type; no surface defines its own editor anymore.
///
/// `showsEditorialFields` keeps the tag picker and page field on the
/// library's editorial-note path and hides them inside highlight popovers
/// (the brief's non-goal: no tag-picker changes and no tags on highlights).
/// `allowEmptyBody` distinguishes the two paths: an editorial note needs
/// text, while a saved highlight may legitimately have an empty body — the
/// highlight row exists independently of its note text (create-then-attach).
struct BookNoteEditorView: View {
    /// Heading above the editor; nil when the containing view supplies one.
    var title: String?
    @Binding var noteText: String
    @Binding var noteTag: BookNote.NoteTag
    @Binding var notePage: String
    var showsEditorialFields: Bool = true
    var allowEmptyBody: Bool = false
    var actionTitle: String = "Add Note"
    var onCommit: () -> Void
    var onCancel: (() -> Void)? = nil

    private var bodyIsEmpty: Bool {
        noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.headline)
            }
            TextEditor(text: $noteText)
                .font(.body)
                .frame(minHeight: 90)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25))
                )
            if showsEditorialFields {
                HStack {
                    Picker("Tag", selection: $noteTag) {
                        ForEach(BookNote.NoteTag.allCases, id: \.self) { tag in
                            Text(tag.rawValue).tag(tag)
                        }
                    }
                    .frame(width: 180)
                    TextField("Page (optional)", text: $notePage)
                        .frame(width: 130)
                    Spacer()
                }
            }
            HStack {
                if let onCancel {
                    Button("Cancel") { onCancel() }
                }
                Button(actionTitle) { onCommit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!allowEmptyBody && bodyIsEmpty)
            }
            if showsEditorialFields {
                Text("Markdown is supported in the note body.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - BookNoteRowView

/// WP-1.4: the note/highlight list row shared by BookDetailsView (and the
/// library surface generally). Quotes render from ONE formatter
/// (`QuoteFormatter`), so a row's caption can never drift from the copied
/// string's caption. Editorial notes without a quote render exactly the
/// pre-extraction look (tag capsule, legacy page number, markdown body).
struct BookNoteRowView: View {
    let note: BookNote
    var onEdit: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let quote = QuoteFormatter.quotedText(of: note) {
                Text(quote)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        (note.color ?? .yellow).swatchColor.opacity(0.32),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                if let caption = QuoteFormatter.locationCaption(note) {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Text(note.tag.rawValue)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                // Legacy page label only for notes that carry a page but no
                // anchored quote (editorial page notes); anchored notes
                // already show the formatter caption above.
                if QuoteFormatter.locationCaption(note) == nil, let page = note.pageNumber {
                    Text("p. \(page + 1)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if let fullQuote = QuoteFormatter.copyQuote(note) {
                    Button {
                        AnnotationClipboard.copy(fullQuote)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .help("Copy quote")
                    .accessibilityLabel("Copy quote")
                }
                if let onEdit {
                    Button {
                        onEdit()
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.plain)
                    .help("Edit note")
                    .accessibilityLabel("Edit note")
                }
                if let onDelete {
                    Button {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .help("Delete note")
                    .accessibilityLabel("Delete note")
                }
            }
            Text(.init(note.text))
                .font(.callout)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - HighlightEditorView

/// WP-1.4: the reader-side editor popover for one highlight note — quoted
/// selection, color swatches, note body, and the three actions
/// (Save / Copy quote / Delete, no Jump in this packet). Shared by EPUB and
/// PDF readers; both pass the note through the SAME DataStore helpers.
///
/// Requirements honored here:
///  - Save mutates ONLY body and color. The note id, anchor, and
///    `selectedText` are passed through untouched (the callers upsert the
///    same id).
///  - Delete is a two-tap inline confirm (no modal alert anywhere in the
///    annotation UI, requirement 7).
///  - `statusMessage` is the inline "anchor stale" warning slot; a nil
///    message means the note resolved normally. No alert is ever raised.
struct HighlightEditorView: View {
    let note: BookNote
    /// Inline status (e.g. "Couldn't find this highlight in the text.");
    /// nil = resolved.
    var statusMessage: String?
    let onSave: (String, AnnotationColor) -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void

    @State private var draftBody: String = ""
    @State private var draftColor: AnnotationColor = .yellow
    @State private var deleteArmed = false

    private let deleteConfirmResetInterval: TimeInterval = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit highlight")
                .font(.headline)

            if let statusMessage {
                Label(statusMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let quote = QuoteFormatter.quotedText(of: note) {
                Text(quote)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        draftColor.swatchColor.opacity(0.32),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                if let caption = QuoteFormatter.locationCaption(note) {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            ColorSwatchRow(selection: draftColor) { color in
                draftColor = color
            }

            NoteBodyField(text: $draftBody)

            HStack(spacing: 12) {
                Button {
                    onCopy()
                } label: {
                    Label("Copy quote", systemImage: "doc.on.doc")
                }

                Spacer()

                Button {
                    if deleteArmed {
                        onDelete()
                    } else {
                        armDelete()
                    }
                } label: {
                    Text(deleteArmed
                        ? "Delete highlight? Tap again to confirm"
                        : "Delete")
                }
                .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Save") {
                    onSave(draftBody, draftColor)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 330)
        .onAppear {
            draftBody = note.text
            draftColor = note.color ?? .yellow
            deleteArmed = false
        }
    }

    /// Two-tap inline confirm: the first tap arms the button and the arming
    /// expires after 3 seconds, so a stray tap cannot delete a highlight
    /// and no alert ever interrupts create/delete cycles.
    private func armDelete() {
        deleteArmed = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(deleteConfirmResetInterval))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                deleteArmed = false
            }
        }
    }
}

/// The editor's text field, shared by the highlight popover and the plain
/// editorial path so both look identical.
private struct NoteBodyField: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .frame(minHeight: 64)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.25))
            )
    }
}

// MARK: - HighlightActionBar

/// WP-1.4: the in-reader action bar. Owner decision (2026-11-07): the brief's
/// custom selection-menu item was dropped — AppKit's WKWebView and PDFView
/// selection menus are not reliably extensible from this code — so WP-1.4
/// ships this bar instead. It appears while a selection is live and offers
/// exactly two actions (Highlight with a default color, Copy quote); no
/// floating toolbar owns selection geometry, the bridges still do.
struct HighlightActionBar: View {
    let defaultColor: AnnotationColor
    let onDefaultColor: (AnnotationColor) -> Void
    let onHighlight: () -> Void
    let onCopy: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ColorSwatchRow(selection: defaultColor, onSelect: onDefaultColor)
            Divider()
                .frame(height: 18)
            Button {
                onHighlight()
            } label: {
                Label("Highlight", systemImage: "highlighter")
            }
            .help("Highlight the selection")
            .accessibilityLabel("Highlight the selection")

            Button {
                onCopy()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .help("Copy quote with its location")
            .accessibilityLabel("Copy quote with its location")
        }
        .font(.system(size: 13, weight: .semibold))
        .buttonStyle(.plain)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .padding(14)
    }
}
