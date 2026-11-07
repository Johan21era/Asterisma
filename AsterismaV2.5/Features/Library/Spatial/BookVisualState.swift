//  BookVisualState.swift
//  AsterismaV2.5
//  Spatial Library — Phase F (Part 9.3 of the build spec)
//
//  The Navigation Model's hard rule: every visible book has a set of VISUAL
//  properties only — position, rotation, depth, scale, opacity, focus state
//  — held separately from the underlying Book data. Navigating modifies
//  ONLY this struct. Book itself (Book 2.swift) is never touched by
//  anything in this feature — every tier view only ever reads `book.*`
//  properties, never assigns to them.
//

import SwiftUI

struct BookVisualState: Sendable, Equatable {

    /// Which rotation each tier wants isn't the same shape: Floating
    /// Cluster's "gently fanned hand of cards" is a flat, in-plane rotation;
    /// the Full Navigator's carousel is a 3D turn-away-from-center rotation.
    /// One shared `applying(_:)` handles both correctly rather than each
    /// tier re-implementing its own version of "turn this into a rotation
    /// modifier."
    enum RotationStyle: Sendable, Equatable {
        case flat
        case threeDimensional
    }

    var offset: CGSize
    var rotationDegrees: Double
    var rotationStyle: RotationStyle
    var scale: Double
    var opacity: Double
    var isFocused: Bool
    var zIndex: Double

    static let identity = BookVisualState(
        offset: .zero, rotationDegrees: 0, rotationStyle: .flat,
        scale: 1, opacity: 1, isFocused: false, zIndex: 0
    )
}

extension View {
    /// The one place a BookVisualState turns into actual rendering —
    /// shared by all three Adaptive Layout tiers, so there is exactly one
    /// implementation of "how does visual state become a transform," not
    /// three slightly-different ones.
    @ViewBuilder
    func applying(_ state: BookVisualState) -> some View {
        switch state.rotationStyle {
        case .flat:
            self
                .rotationEffect(.degrees(state.rotationDegrees))
                .scaleEffect(state.scale)
                .opacity(state.opacity)
                .offset(state.offset)
                .zIndex(state.zIndex)
        case .threeDimensional:
            self
                .rotation3DEffect(.degrees(state.rotationDegrees), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
                .scaleEffect(state.scale)
                .opacity(state.opacity)
                .offset(state.offset)
                .zIndex(state.zIndex)
        }
    }
}
