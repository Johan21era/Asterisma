//  SentinelReportCardView.swift
//  AsterismaV2.5
//
//  P6: the "While you were away" card. Shows on launch ONLY when the
//  journal has something from the last 12 hours. All strings are the static
//  userSummary literals defined by probes — nothing user-identifying, ever.
//
//  SECURITY: "Review" opens the Dev Console in Debug only. Release has no
//  console window, so the button is absent rather than a dead end (SENT-026).

import SwiftUI

struct SentinelReportCardView: View {
    let fixed: Int
    let stalled: Int
    let headline: String
    /// Present only where a Developer Console exists (Debug).
    let onReview: (() -> Void)?
    let onDismiss: () -> Void

    init(fixed: Int, stalled: Int, headline: String,
         onReview: (() -> Void)? = nil,
         onDismiss: @escaping () -> Void) {
        self.fixed = fixed
        self.stalled = stalled
        self.headline = headline
        self.onReview = onReview
        self.onDismiss = onDismiss
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: fixed > 0 ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.title3)
                .foregroundColor(fixed > 0 ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Sentinel Report")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(headline)
                    .font(.subheadline.weight(.medium))
            }

            Spacer()

            if let onReview {
                Button("Review") { onReview() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

            Button("Got it") { onDismiss() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(DesignGrid.cardPaddingV + 2)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignGrid.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DesignGrid.cardCornerRadius)
                .strokeBorder((fixed > 0 ? Color.green : Color.orange).opacity(0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
