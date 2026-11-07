//  ComicReaderModel.swift
//  AsterismaV2.5
//
//  2.5 — pure pagination rules for the comic reader. Kept free of SwiftUI and
//  AppKit so the direction semantics can be tested directly: in a
//  right-to-left manga the left arrow advances, while page indices still
//  increase in reading order.

import Foundation

enum ComicNavigationCommand: Sendable {
    case left
    case right
    case up
    case down
}

enum ComicPagination {
    static func clamped(_ index: Int, pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        return min(max(index, 0), pageCount - 1)
    }

    static func next(after index: Int, pageCount: Int) -> Int? {
        guard pageCount > 0 else { return nil }
        let next = index + 1
        return next < pageCount ? next : nil
    }

    static func previous(before index: Int, pageCount: Int) -> Int? {
        guard pageCount > 0 else { return nil }
        let previous = index - 1
        return previous >= 0 ? previous : nil
    }

    static func label(index: Int, pageCount: Int) -> String {
        guard pageCount > 0 else { return "No pages" }
        return "Page \(clamped(index, pageCount: pageCount) + 1) of \(pageCount)"
    }

    /// 1-based progress, clamped so the last page reads as 100%.
    static func progress(index: Int, pageCount: Int) -> Double {
        guard pageCount > 0 else { return 0 }
        return Double(clamped(index, pageCount: pageCount) + 1) / Double(pageCount)
    }

    /// The visual left-to-right order used by the native paging ScrollView.
    /// Story order is always 0...n; RTL reverses only the presentation.
    static func visualOrder(pageCount: Int, mode: ComicReadingMode) -> [Int] {
        guard pageCount > 0 else { return [] }
        let order = Array(0 ..< pageCount)
        return mode == .rightToLeft ? order.reversed() : order
    }

    static func visualIndex(forPage page: Int, pageCount: Int, mode: ComicReadingMode) -> Int {
        guard pageCount > 0 else { return 0 }
        let page = clamped(page, pageCount: pageCount)
        return mode == .rightToLeft ? pageCount - 1 - page : page
    }

    static func pageIndex(forVisual visual: Int, pageCount: Int, mode: ComicReadingMode) -> Int {
        guard pageCount > 0 else { return 0 }
        let visual = clamped(visual, pageCount: pageCount)
        return mode == .rightToLeft ? pageCount - 1 - visual : visual
    }
}

extension ComicReadingMode {
    /// Maps a physical arrow key to "advance" or "go back". Reading order is
    /// always increasing page index; only the key that advances changes.
    func isForward(_ command: ComicNavigationCommand) -> Bool {
        switch self {
        case .leftToRight:
            switch command {
            case .right, .down: return true
            case .left, .up: return false
            }
        case .rightToLeft:
            switch command {
            case .left, .down: return true
            case .right, .up: return false
            }
        case .vertical:
            switch command {
            case .down, .right: return true
            case .up, .left: return false
            }
        }
    }
}
