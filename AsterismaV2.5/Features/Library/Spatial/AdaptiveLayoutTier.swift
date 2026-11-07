//  AdaptiveLayoutTier.swift
//  AsterismaV2.5
//
//  Spatial Library — Phase F/G (Part 9.2 of the build spec)
//
//  A binary small/large split was considered and rejected in favor of this
//  three-tier version during the design review Part 9.2 documents — so
//  both thresholds below are load-bearing, not arbitrary.
//

import Foundation

enum AdaptiveLayoutTier: Sendable, Equatable {
    case floatingCluster       // 1-5 books
    case shallowPerspective    // 6-15 books
    case fullSpatialNavigator  // 16+ books

    static let floatingClusterMaxCount = 5
    static let shallowPerspectiveMaxCount = 15

    static func tier(forCount count: Int) -> AdaptiveLayoutTier {
        switch count {
        case ...floatingClusterMaxCount:
            return .floatingCluster
        case (floatingClusterMaxCount + 1)...shallowPerspectiveMaxCount:
            return .shallowPerspective
        default:
            return .fullSpatialNavigator
        }
    }
}
