//  BookDetailsView.swift
//  Bedrock G5 — metadata, notes, and collection management.
//
//  The library rows previously had no way to edit the fields the Explorer
//  filters on. This inspector is the single place where a book's genre,
//  series, favorite flag, notes, and collection memberships are managed.

import SwiftUI

struct BookDetailsView: View {
    @EnvironmentObject private var dataStore: DataStore
    @Environment(\.dismiss) private var dismiss
    let bookID: UUID

    @State private var genre: ReadingGenre = .unknown
    @State private var series = ""
    @State private var isFavorite = false

    @State private var noteText = ""
    @State private var noteTag: BookNote.NoteTag = .general
    @State private var notePage = ""
    @State private var editingNoteID: UUID?

    @State private var newCollectionName = ""
    @State private var renamingCollectionID: UUID?
    @State private var renameDraft = ""
    @State private var relinkError: String?

    private var book: Book? { dataStore.book(id: bookID) }

    var body: some View {
        TabView {
            detailsTab
                .tabItem { Label("Details", systemImage: "info.circle") }
            notesTab
                .tabItem { Label("Notes", systemImage: "note.text") }
            collectionsTab
                .tabItem { Label("Collections", systemImage: "square.stack.3d.up") }
        }
        .frame(minWidth: 620, minHeight: 560)
        .padding(16)
        .onAppear(perform: load)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .alert("Rename Collection", isPresented: renamePresented) {
            TextField("Collection name", text: $renameDraft)
            Button("Cancel", role: .cancel) { renamingCollectionID = nil }
            Button("Save") {
                if let id = renamingCollectionID {
                    dataStore.renameCollection(id: id, to: renameDraft)
                }
                renamingCollectionID = nil
            }
            .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renamingCollectionID != nil },
            set: { if !$0 { renamingCollectionID = nil } }
        )
    }

    // MARK: - Details

    private var detailsTab: some View {
        Form {
            if let book {
                Section("Book") {
                    LabeledContent("Title", value: book.title)
                    LabeledContent("Author", value: book.author)
                    LabeledContent("Format", value: book.fileType.displayName)
                    LabeledContent("Progress", value: "\(book.currentPage + 1) of \(book.totalPages) pages")
                }

                Section("Source File") {
                    LabeledContent("File") {
                        Text(book.fileURL.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Button("Locate File…") { locateFile(book) }
                    Text("If this book's file was moved, renamed, or deleted, choose it again here. " +
                        "Progress, notes, and collections are kept.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let relinkError {
                        Text(relinkError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("Classification") {
                    Picker("Genre", selection: $genre) {
                        ForEach(ReadingGenre.allCases, id: \.self) { genre in
                            Text(genre.displayName).tag(genre)
                        }
                    }
                    TextField("Series", text: $series)
                    Toggle("Favorite", isOn: $isFavorite)
                }

                Section {
                    Button("Save Details") { saveDetails() }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                ContentUnavailableView(
                    "Book Not Found",
                    systemImage: "book.closed",
                    description: Text("This book was removed from the library."))
            }
        }
        .formStyle(.grouped)
    }

    private func load() {
        guard let book else { return }
        genre = book.genre
        series = book.series ?? ""
        isFavorite = book.isFavorite
        relinkError = nil
    }

    private func locateFile(_ book: Book) {
        BookFilePicker.chooseReplacement(for: book) { url in
            guard let url else { return }
            do {
                try dataStore.relinkBookFile(id: book.id, to: url)
                relinkError = nil
            } catch {
                relinkError = error.localizedDescription
            }
        }
    }

    private func saveDetails() {
        guard var book else { return }
        book.genre = genre
        let trimmed = series.trimmingCharacters(in: .whitespacesAndNewlines)
        book.series = trimmed.isEmpty ? nil : trimmed
        book.isFavorite = isFavorite
        dataStore.updateBook(book)
    }

    // MARK: - Notes

    // WP-1.4: the note editor and row are the shared extracted views in
    // HighlightViews.swift; this surface owns only the list container, the
    // editorial bindings, and wiring. Mutations go exclusively through
    // DataStore.upsertNote / deleteNote — the single book.notes path — so
    // this view no longer mutates notes via updateBook.

    private var notesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let book, !book.notes.isEmpty {
                List {
                    ForEach(book.notes.sorted { $0.createdAt > $1.createdAt }) { note in
                        BookNoteRowView(
                            note: note,
                            onEdit: { edit(note) },
                            onDelete: { delete(note) }
                        )
                    }
                }
                .frame(minHeight: 220)
            } else {
                ContentUnavailableView(
                    "No Notes Yet",
                    systemImage: "note.text",
                    description: Text("Add a thought, quote, or page note below."))
                    .frame(minHeight: 180)
            }

            Divider()

            BookNoteEditorView(
                title: editingNoteID == nil ? "Add Note" : "Edit Note",
                noteText: $noteText,
                noteTag: $noteTag,
                notePage: $notePage,
                showsEditorialFields: true,
                allowEmptyBody: false,
                actionTitle: editingNoteID == nil ? "Add Note" : "Save Note",
                onCommit: { commitNote() },
                onCancel: editingNoteID == nil ? nil : { resetNoteEditor() }
            )
        }
        .padding(.top, 8)
    }

    private func edit(_ note: BookNote) {
        editingNoteID = note.id
        noteText = note.text
        noteTag = note.tag
        notePage = note.pageNumber.map { String($0 + 1) } ?? ""
    }

    private func resetNoteEditor() {
        editingNoteID = nil
        noteText = ""
        noteTag = .general
        notePage = ""
    }

    private func commitNote() {
        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let page = Int(notePage).map { max(0, $0 - 1) }
        if let editingNoteID,
           var existing = dataStore.book(id: bookID)?.notes
            .first(where: { $0.id == editingNoteID })
        {
            // Edits rewrite only the editorial fields on the SAME id; id,
            // anchor, selectedText, and color are never touched here.
            existing.text = trimmed
            existing.tag = noteTag
            existing.pageNumber = page
            existing.modifiedAt = Date()
            dataStore.upsertNote(existing, inBook: bookID)
        } else {
            dataStore.upsertNote(
                BookNote(
                    bookID: bookID,
                    pageNumber: page,
                    text: trimmed,
                    tag: noteTag),
                inBook: bookID)
        }
        resetNoteEditor()
    }

    private func delete(_ note: BookNote) {
        // WP-1.4: remove exactly that note id; no other row is touched.
        dataStore.deleteNote(id: note.id, inBook: bookID)
        if editingNoteID == note.id { resetNoteEditor() }
    }

    // MARK: - Collections

    private var collectionsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let book {
                List {
                    ForEach(dataStore.libraryState.collections) { collection in
                        HStack {
                            Toggle(isOn: Binding(
                                get: { book.collectionIDs.contains(collection.id) },
                                set: { dataStore.setBook(
                                    book.id,
                                    membershipIn: collection.id,
                                    isMember: $0) }
                            )) {
                                Text(collection.name)
                            }
                            Spacer()
                            Button {
                                renamingCollectionID = collection.id
                                renameDraft = collection.name
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.plain)
                            .help("Rename collection")
                            .accessibilityLabel("Rename \(collection.name)")
                            Button {
                                dataStore.removeCollection(id: collection.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .help("Delete collection")
                            .accessibilityLabel("Delete \(collection.name)")
                        }
                    }
                }
                .frame(minHeight: 260)
            }

            Divider()

            HStack {
                TextField("New collection name", text: $newCollectionName)
                Button("Create") {
                    let name = newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    _ = dataStore.addCollection(name: name)
                    newCollectionName = ""
                }
                .disabled(newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.top, 8)
    }
}
