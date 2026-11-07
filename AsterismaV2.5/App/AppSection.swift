//  AppSection.swift
//  AsterismaV2.5
//
//  The four durable destinations of the main window. Secondary surfaces
//  (discovery, annual reports, recommendations, achievements, session history,
//  environment/context, settings, Sentinel) remain contextual actions; they
//  are not top-level navigation. This is the information architecture the
//  Home/Library overhaul is built on.

import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case home
    case library
    case insights
    case goals

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .library: return "Library"
        case .insights: return "Insights"
        case .goals: return "Goals"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .library: return "books.vertical"
        case .insights: return "chart.line.uptrend.xyaxis"
        case .goals: return "target"
        }
    }

    /// ⌘1–⌘4. The sidebar buttons carry these shortcuts, so the destinations
    /// stay reachable without hunting through the canvas.
    var shortcut: KeyEquivalent {
        switch self {
        case .home: return "1"
        case .library: return "2"
        case .insights: return "3"
        case .goals: return "4"
        }
    }

    var purpose: String {
        switch self {
        case .home: return "Resume reading and see what is next."
        case .library: return "Browse, search, and manage every book."
        case .insights: return "Understand your reading patterns."
        case .goals: return "Set targets and keep an eye on deadlines."
        }
    }
}
