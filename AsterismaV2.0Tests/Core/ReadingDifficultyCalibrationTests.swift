//  ReadingDifficultyCalibrationTests.swift
//  AsterismaV2.0Tests
//
//  Calibration pins for the real-book phase.
//    • Ordinary prose (the declared baseline profile) is exactly 1.0.
//    • The old college-level ceiling must not come back: a grade-8, 4.5-char,
//      14-word profile is neutral, not "easy".
//    • Harder prose increases the multiplier; lighter prose decreases it.
//    • The multiplier is bounded, so a pathological sample cannot explode pages.

import Foundation
import Testing

@testable import AsterismaV2_0

@Suite("Reading difficulty — baseline calibration")
struct ReadingDifficultyCalibrationTests {

    @Test("the declared baseline is neutral")
    func baselineIsOne() {
        let multiplier = ReadingDifficultyProfile.baseline.difficultyMultiplier
        #expect(abs(multiplier - 1.0) < 0.001)
        #expect(ReadingDifficultyProfile.baseline.difficultyLabel == "Moderate")
    }

    @Test("college-level prose is harder than baseline, not neutral")
    func collegeProseIsHarder() {
        let college = ReadingDifficultyProfile(
            gradeLevel: 14.0,
            averageWordLength: 5.2,
            averageSentenceLength: 20.0,
            rareLexiconRatio: 0.10
        )
        #expect(college.difficultyMultiplier > 1.0)
        #expect(college.difficultyLabel == "Challenging" || college.difficultyLabel == "Dense")
    }

    @Test("simple prose is lighter than baseline")
    func simpleProseIsLighter() {
        let simple = ReadingDifficultyProfile(
            gradeLevel: 4.0,
            averageWordLength: 3.9,
            averageSentenceLength: 9.0,
            rareLexiconRatio: 0.02
        )
        #expect(simple.difficultyMultiplier < 1.0)
    }

    @Test("difficulty is monotonic in grade level and bounded")
    func monotonicAndBounded() {
        func profile(_ grade: Double) -> ReadingDifficultyProfile {
            ReadingDifficultyProfile(gradeLevel: grade, averageWordLength: 4.5,
                                     averageSentenceLength: 14, rareLexiconRatio: 0.05)
        }
        #expect(profile(12).difficultyMultiplier > profile(8).difficultyMultiplier)
        #expect(profile(500).difficultyMultiplier <= 2.0)
        #expect(profile(0).difficultyMultiplier >= 0.5)
    }
}
