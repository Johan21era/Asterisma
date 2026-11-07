//  ShootingStarView.swift
//  Environment Engine — Phase D (Part 7 of the build spec)
//
//  Renders the currently-active shooting star, if any, as a comet-style
//  head-and-tail streak that actually travels from `start` to `end` over
//  its randomized `duration` (driven by real elapsed time via
//  `spawnDate`), fading in briefly, holding, then fading out over the back
//  portion of the transit at a rate set by `fadeRate`.
//

import SwiftUI

struct ShootingStarView: View {
    let shootingStar: ShootingStar?

    var body: some View {
        Group {
            if let shootingStar {
                TimelineView(.animation) { timeline in
                    Canvas { context, size in
                        draw(shootingStar, now: timeline.date, into: &context, size: size)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(_ star: ShootingStar, now: Date, into context: inout GraphicsContext, size: CGSize) {
        let elapsed = now.timeIntervalSince(star.spawnDate)
        let progress = EnvironmentMath.clampUnit(elapsed / star.duration)
        guard progress > 0, progress < 1 else { return }

        let startPoint = CGPoint(x: star.start.x * size.width, y: star.start.y * size.height)
        let endPoint = CGPoint(x: star.end.x * size.width, y: star.end.y * size.height)

        // The head races from start to end over the full duration; the tail
        // trails a fixed fraction of the path behind it, giving a comet
        // shape rather than a static line.
        let headProgress = progress
        let tailProgress = max(0, progress - 0.22)
        let head = CGPoint(
            x: startPoint.x + (endPoint.x - startPoint.x) * headProgress,
            y: startPoint.y + (endPoint.y - startPoint.y) * headProgress
        )
        let tail = CGPoint(
            x: startPoint.x + (endPoint.x - startPoint.x) * tailProgress,
            y: startPoint.y + (endPoint.y - startPoint.y) * tailProgress
        )

        // Fades in briefly, holds, then fades out over the back portion of
        // the transit — the portion consumed by the fade-out is set by
        // `fadeRate` (higher = longer fade tail).
        let fadeInEnd = 0.12
        let fadeOutStart = 1.0 - star.fadeRate
        let envelope: Double
        if progress < fadeInEnd {
            envelope = EnvironmentMath.smoothstep(progress / fadeInEnd)
        } else if progress > fadeOutStart {
            let t = (progress - fadeOutStart) / max(0.001, 1 - fadeOutStart)
            envelope = 1 - EnvironmentMath.smoothstep(t)
        } else {
            envelope = 1
        }

        var path = Path()
        path.move(to: tail)
        path.addLine(to: head)

        context.opacity = star.brightness * envelope
        context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))

        let headRadius: CGFloat = 2.2
        let headRect = CGRect(
            x: head.x - headRadius, y: head.y - headRadius,
            width: headRadius * 2, height: headRadius * 2
        )
        context.fill(Path(ellipseIn: headRect), with: .color(.white))
        context.opacity = 1
    }
}
