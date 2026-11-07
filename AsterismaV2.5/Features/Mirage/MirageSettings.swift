import Foundation

// PR-7 (§16 PR-7 gate + §11): Mirage as an OPTIONAL RT feature.
//
// Governance is one plain switch: `mirage.enabled` (Settings ▸ Mirage).
//   • ON  — the reader's "Analyze with Mirage" ingress works (never auto-run;
//           one gesture = one clean engine lifecycle, as established).
//   • OFF — the sheet reports honestly and starts nothing; the status section
//           is replaced by the disabled-state copy. NO engine, NO spawn.
//   • ALWAYS — disable deletes nothing: the identity stratum, the ledger, and
//           Mirage's own stored analyses stay exactly on disk (disable is a
//           UI gate, not a data operation — verified by
//           MirageFeatureLifecycleTests; there is no delete path in this file,
//           and none is planned under the playbook's ownership rules).
//
// Default is ON: the engine gate itself (dev checkout / future ADR-3 bundle)
// governs real availability, and the unavailable-state copy explains itself
// honestly when the engine is absent.

nonisolated enum MirageSettings {
    static let enabledKey = "mirage.enabled"

    /// True unless the persisted preference explicitly says otherwise.
    static var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: enabledKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: enabledKey)
    }
}

// Plain-language copy for the disabled state (owner-honesty rules: never
// claim an undo, never claim deletions, always name the settings surface).
nonisolated enum MirageSettingsCopy {
    static let disabledHeadline = "Mirage analysis is turned off"
    static let disabledDetail =
        "Turn it on in Settings ▸ Mirage. Nothing was deleted when you turned it off: "
        + "Mirage's stored analyses and RT's link records remain exactly as they are."
}
