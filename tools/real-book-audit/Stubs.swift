//  Stubs.swift — compile-time scaffolding for the audit driver only.
//
//  `Book2.swift` also declares `LibraryState`, which references goal types that
//  live in the app's goal manager. The driver never reads or writes library
//  state, so these minimal Codable shells satisfy the type checker without
//  pulling the goal subsystem (or its persistence) into the tool.

import Foundation

struct SchemaVersion: Codable, Hashable {
    var major: Int = 1
    var minor: Int = 0
    var patch: Int = 0

    static let current = SchemaVersion()
}

struct ReadingGoalSet: Codable, Hashable {
    static let empty = ReadingGoalSet()
}

struct BookDeadline: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
}

struct EarnedAchievement: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
}
