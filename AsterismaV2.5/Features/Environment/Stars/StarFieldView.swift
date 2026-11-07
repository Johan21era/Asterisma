//  StarFieldView.swift
//  AsterismaV2.5
//
//  Created by Johan Rembeci on 7/12/26.
//


//
//  StarFieldView.swift
//  AsterismaV2.5
//
//  Environment Engine — Phase C (Part 6.3 of the build spec)
//
//  Renders a StarField using Canvas, animated by TimelineView. Only
//  subscribes to per-frame updates while starVisibility > 0 — during full
//  daylight this view does effectively no work, per Part 6.3 / Part 13.
//  When reducedMotion is set, twinkle is skipped entirely and every star is
//  drawn once at its base brightness (Part 11).
//

import SwiftUI

struct StarFieldView: View {
    let starField: StarField
    let starVisibility: Double
    let reducedMotion: Bool

    var body: some View {
        Group {
            if starVisibility > 0.001 {
                if reducedMotion {
                    Canvas { context, size in
                        draw(starField.stars, at: 0, animated: false, into: &context, size: size)
                    }
                } else {
                    TimelineView(.animation) { timeline in
                        Canvas { context, size in
                            let elapsed = timeline.date.timeIntervalSinceReferenceDate
                            draw(starField.stars, at: elapsed, animated: true, into: &context, size: size)
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(
        _ stars: [Star],
        at elapsed: Double,
        animated: Bool,
        into context: inout GraphicsContext,
        size: CGSize
    ) {
        for star in stars {
            let brightness = animated ? star.brightness(at: elapsed) : star.baseBrightness
            let effectiveOpacity = brightness * starVisibility
            guard effectiveOpacity > 0.01 else { continue }

            let point = CGPoint(
                x: star.relativePosition.x * size.width,
                y: star.relativePosition.y * size.height
            )
            let rect = CGRect(
                x: point.x - star.radius,
                y: point.y - star.radius,
                width: star.radius * 2,
                height: star.radius * 2
            )
            context.opacity = effectiveOpacity
            context.fill(Path(ellipseIn: rect), with: .color(star.color.swiftUIColor))
        }
        context.opacity = 1
    }
}
