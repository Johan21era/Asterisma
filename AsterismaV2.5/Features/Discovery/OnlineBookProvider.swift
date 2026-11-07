//  OnlineBookProvider.swift
//  Online Book Discovery System
//
//  Provider contract for all online book sources.
//  Providers must never throw and must always return
//  a valid array.
//

import Foundation

nonisolated protocol BookProvider: Sendable {
    func searchBooks(query: String) async -> [OnlineBook]
}
