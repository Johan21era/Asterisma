//  SentinelProbeCatalog.swift
//  AsterismaV2.5
//
//  SG2 — the registry. The console's probe count, the coverage report, and the
//  Health Center all read this list; none of them hardcode a number.

import Foundation

nonisolated enum SentinelProbeCatalog {
    /// Ordered by domain family for readable matrices. Order never affects
    /// fingerprints, coverage, or diagnosis.
    static func all() -> [any SentinelProbeV2] {
        SentinelLibraryProbes.all
            + SentinelGoalProbes.all
            + SentinelStorageProbes.all
            + SentinelFileProbes.all
            +        SentinelSubsystemProbes.all
            + SentinelSelfProbes.all
            + SentinelSurfaceProbes.all
    }

    static var descriptors: [SentinelProbeDescriptor] {
        all().map(\.descriptor)
    }

    static var ruleMetadata: [SentinelRuleID: SentinelRuleMetadata] {
        SentinelCopyRegistry.registry(for: descriptors)
    }

    static var domainCount: Int {
        Set(descriptors.map(\.domain)).count
    }

    static var requiredCount: Int {
        descriptors.filter(\.isRequired).count
    }
}
