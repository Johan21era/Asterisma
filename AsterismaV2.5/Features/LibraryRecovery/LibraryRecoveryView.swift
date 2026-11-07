//  LibraryRecoveryView.swift
//  Library Safety — Phase 6
//
//  The owner-facing recovery surface. It reads coordinator state only; every
//  action is explicit, previewed by copy, and confirmed by a typed phrase. No
//  action here deletes the preserved copy or the live file.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryRecoveryView: View {
    @ObservedObject var coordinator: LibraryHealthCoordinator

    @State private var selectedBackupID: String?
    @State private var restorePhrase = ""
    @State private var rebuildPhrase = ""
    @State private var notice: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let incident = coordinator.incident {
                    incidentCard(incident)
                    if let diagnosis = incident.diagnosis {
                        diagnosisCard(diagnosis)
                    }
                    if incident.state == .awaitingDecision {
                        decisionCard(incident)
                    }
                    actionStrip
                } else {
                    healthyCard
                }
                backupsCard
                if let notice {
                    Text(notice)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(4)
        }
    }

    // MARK: - Incident

    private func incidentCard(_ incident: LibraryIncident) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Library needs attention", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(incident.userSummaryKey)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                row("State", incident.state.rawValue)
                row("Cause", incident.kind.rawValue)
                row("Detected", incident.detectedAt.formatted(date: .abbreviated, time: .shortened))
                if let preserved = incident.preserved {
                    row("Preserved copy", "\(preserved.files.count) file(s) · \(preserved.combinedSHA256.prefix(10))…")
                }
                if let chosen = incident.chosenOptionID {
                    row("Chosen option", chosen)
                }
                if let error = incident.lastError {
                    row("Last error", "\(error.code) · \(error.messageKey)")
                }
            }
            .font(.callout)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func diagnosisCard(_ diagnosis: LibraryDiagnosis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What the preserved copy shows").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                row("Opens read-only", diagnosis.canOpenReadOnly ? "yes" : "no")
                row("Rows recovered", "\(diagnosis.tableCounts?.totalRows ?? 0)")
                row("Undecodable books", "\(diagnosis.undecodableBooks)")
                if !diagnosis.missingTables.isEmpty {
                    row("Missing tables", diagnosis.missingTables.joined(separator: ", "))
                }
            }
            .font(.callout)
            Text("The original file has not been modified.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Decisions

    private func decisionCard(_ incident: LibraryIncident) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose one action").font(.headline)

            if verifiedBackups.isEmpty {
                Text("No verified backup is available. Restoring is disabled until a backup passes verification.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Restore a verified backup").font(.subheadline.weight(.medium))
                    Picker("Backup", selection: $selectedBackupID) {
                        Text("Select a backup").tag(String?.none)
                        ForEach(verifiedBackups) { backup in
                            Text(backupLabel(backup)).tag(String?.some(backup.id))
                        }
                    }
                    TextField("Type RESTORE to confirm", text: $restorePhrase)
                        .textFieldStyle(.roundedBorder)
                    Button("Restore backup") {
                        guard let selectedBackupID else { return }
                        Task {
                            await coordinator.restore(
                                backupID: selectedBackupID,
                                confirmation: restorePhrase)
                            restorePhrase = ""
                            notice = restoreOutcome()
                        }
                    }
                    .disabled(restorePhrase != "RESTORE" || selectedBackupID == nil || coordinator.isWorking)
                }
            }

            if incident.diagnosis?.canRebuildFromPayloads == true {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Rebuild from readable rows").font(.subheadline.weight(.medium))
                    Text("Carries books, sessions, page timings, and settings that still decode. Anything unreadable is reported, not invented.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Type REBUILD to confirm", text: $rebuildPhrase)
                        .textFieldStyle(.roundedBorder)
                    Button("Rebuild library") {
                        Task {
                            await coordinator.rebuild(confirmation: rebuildPhrase)
                            rebuildPhrase = ""
                            notice = restoreOutcome()
                        }
                    }
                    .disabled(rebuildPhrase != "REBUILD" || coordinator.isWorking)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    private var actionStrip: some View {
        HStack(spacing: 10) {
            Button("Export a copy…") { exportCopy() }
            Button("Save support summary…") { exportSupportSummary() }
            Spacer()
            if coordinator.incident?.state == .failed {
                Button("Try again") {
                    Task { await coordinator.retry() }
                }
            }
            Button("Leave it for now", role: .destructive) {
                Task { await coordinator.abandon() }
            }
            .disabled(coordinator.isWorking)
        }
    }

    // MARK: - Backups

    private var backupsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Backups").font(.headline)
                Spacer()
                Button("Refresh") { coordinator.refreshBackups() }
            }
            if coordinator.backups.isEmpty {
                Text("No backups yet. A verified backup is required to restore.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(coordinator.backups) { backup in
                    HStack(spacing: 10) {
                        Image(systemName: backup.isVerified ? "checkmark.seal.fill" : "questionmark.seal")
                            .foregroundStyle(backup.isVerified ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(backupLabel(backup)).font(.callout)
                            Text(backup.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(backup.state.rawValue).font(.caption).foregroundStyle(.secondary)
                        Button("Verify") {
                            coordinator.drill(backup.id)
                            notice = coordinator.backups.first { $0.id == backup.id }?.isVerified == true
                                ? "That backup passed verification."
                                : "That backup did not pass verification."
                        }
                    }
                    Divider()
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    private var healthyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Library is healthy", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text("No recovery incident is open. Backups are verified independently of the live file.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Helpers

    private var verifiedBackups: [LibraryBackup] {
        coordinator.backups.filter(\.isVerified)
    }

    private func backupLabel(_ backup: LibraryBackup) -> String {
        let counts = backup.manifest?.counts
        let books = counts?.books ?? 0
        let timings = counts?.pageTimes ?? 0
        return "\(books) book\(books == 1 ? "" : "s") · \(timings) timings · \(backup.isSafetySnapshot ? "safety" : "daily")"
    }

    private func restoreOutcome() -> String {
        if let receipt = coordinator.lastReceipt {
            return "Recovery \(receipt.outcome.rawValue). Incident \(receipt.incidentID)."
        }
        if let key = coordinator.lastErrorKey { return key }
        return "Recovery finished. Reopen the library to check it."
    }

    private func exportCopy() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite3") ?? .data]
        panel.nameFieldStringValue = "Asterisma-library-copy.sqlite3"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                await coordinator.exportCopy(to: url)
                notice = coordinator.lastErrorKey ?? "Exported to \(url.lastPathComponent)."
            }
        }
    }

    private func exportSupportSummary() {
        guard let data = coordinator.supportSummaryData() else {
            notice = "The support summary could not be built."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "asterisma-recovery-summary.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                Task { @MainActor in notice = "Saved \(url.lastPathComponent)." }
            } catch {
                Task { @MainActor in notice = "The summary could not be saved." }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }
}
