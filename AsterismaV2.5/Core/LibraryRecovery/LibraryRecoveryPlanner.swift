//  LibraryRecoveryPlanner.swift
//  Library Safety — Phase 2
//
//  Pure option construction. No option executes here. An option is offered only
//  when its preconditions are already true; the executor re-checks them.

import Foundation

nonisolated enum LibraryRecoveryPlanner {

    static func options(
        diagnosis: LibraryDiagnosis,
        hasPreservedCopy: Bool
    ) -> [RecoveryOption] {
        let counts = diagnosis.tableCounts?.asDictionary ?? [:]
        let recovered = diagnosis.tableCounts?.totalRows
        let estimate = RecoveryEstimate(
            recoveredRows: recovered,
            lostRows: 0,
            unknownRows: !diagnosis.canOpenReadOnly,
            perTable: counts,
            noteKey: diagnosis.canOpenReadOnly ? nil : "recovery.estimate.unreadable")

        var options: [RecoveryOption] = []

        // Export is always available once the preserved copy exists. It does
        // not modify anything, so it asks for no destructive confirmation.
        options.append(RecoveryOption(
            id: "export",
            kind: .exportCopy,
            risk: .readOnly,
            titleKey: "recovery.option.export.title",
            detailKey: "recovery.option.export.detail",
            estimate: estimate,
            preconditions: [.preservedCopyVerified],
            confirmation: .none,
            isEnabled: hasPreservedCopy,
            disabledReasonKey: hasPreservedCopy ? nil : "recovery.option.disabled.noPreservedCopy",
            backupID: nil))

        if diagnosis.canRebuildFromPayloads {
            options.append(RecoveryOption(
                id: "rebuild",
                kind: .rebuildNormalizedTables,
                risk: .fileLevel,
                titleKey: "recovery.option.rebuild.title",
                detailKey: "recovery.option.rebuild.detail",
                estimate: estimate,
                preconditions: [.preservedCopyVerified, .storeFrozen],
                confirmation: .typedPhrase,
                isEnabled: hasPreservedCopy,
                disabledReasonKey: hasPreservedCopy ? nil : "recovery.option.disabled.noPreservedCopy",
                backupID: nil))
        }

        // A read-only incident always has a legitimate non-action. It keeps the
        // original and the preserved copy untouched.
        options.append(RecoveryOption(
            id: "do-nothing",
            kind: .doNothing,
            risk: .readOnly,
            titleKey: "recovery.option.doNothing.title",
            detailKey: "recovery.option.doNothing.detail",
            estimate: RecoveryEstimate(
                recoveredRows: 0,
                lostRows: 0,
                unknownRows: false,
                perTable: [:],
                noteKey: nil),
            preconditions: [.preservedCopyVerified],
            confirmation: .none,
            isEnabled: true,
            disabledReasonKey: nil,
            backupID: nil))

        return options
    }
}
