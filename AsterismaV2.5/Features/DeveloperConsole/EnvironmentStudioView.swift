//  EnvironmentStudioView.swift
//  AsterismaV2.5 — DEVELOPER CONSOLE
//
//  The visual proving ground for the environment system. It renders a REAL
//  `EnvironmentBackgroundView` — same engine, same layers, same weather
//  effects — in a fixed preview frame, and drives that engine through
//  `EnvironmentOverrideStore`, the same store the app's own engine reads.
//
//  Three inspection modes, added 2026-11-08 for direct look calibration:
//    • Authority — force any hour, season, or weather kind and read the exact
//      composed state that produced the frame.
//    • Location — pin a coordinate and its solar offset to see how the real
//      solar day recalibrates the palette without travelling.
//    • Transition — capture two states and scrub the cross-fade frame by
//      frame, then copy a plain-text look report (with notes) for feedback.
//
//  Overrides are cleared when this pane disappears, so closing the studio
//  always returns the app to the real clock, season, weather, and location.

#if DEBUG

import AppKit
import SwiftUI

struct EnvironmentStudioView: View {
    @StateObject private var engine = EnvironmentEngine(
        liveWeatherEnabled: true,
        coordinateProvider: { WeatherKitService.shared.cachedCoordinate },
        // Studio controls are inspection tools; keep their feedback quick.
        // The production background uses the full 10 s continuous cross-fade.
        transitionDuration: EnvironmentPresentation.studioOverrideTransitionDuration
    )

    private let store = EnvironmentOverrideStore.standard

    @State private var useLiveTime = true
    @State private var minute: Double = 600
    @State private var clockEntry = ""
    @State private var clockEntryInvalid = false
    @State private var useLiveWeather = true
    @State private var forcedKind: WeatherVisualKind = .rain
    @State private var forcedIntensity: Double = 0.65
    @State private var useLiveSeason = true
    @State private var forcedSeason: SeasonalPeriod = .autumn
    @State private var forcedPhase: PhaseSelection = .auto
    @State private var didLoad = false

    // Location lab. Kept local to the Studio: a pinned coordinate must not
    // survive a pane close and repaint the app somewhere else.
    @State private var useLiveLocation = true
    @State private var latitudeText = "37.7749"
    @State private var longitudeText = "-122.4194"
    @State private var appliedCoordinate: SolarCoordinate?
    @State private var coordinateError: String?

    // Transition lab.
    @State private var transitionA: EnvironmentState?
    @State private var transitionB: EnvironmentState?
    @State private var scrubProgress: Double = 1.0

    // Feedback loop.
    @State private var notes = ""
    @State private var lastCopiedAt: Date?

    @State private var expandedPreview = false

    // Precipitation envelope. Scrubbing the event age makes a two-hour pass
    // inspectable in seconds; the app's own engine keeps the real clock.
    @State private var scrubEventAge = false
    @State private var eventAgeMinutes: Double = 30

    // Accessibility preview. The environment reads macOS on every tick; these
    // let the owner see the reduced path without changing a system setting.
    @State private var useSystemAccessibility = true
    @State private var previewReducedMotion = false
    @State private var previewReducedTransparency = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                preview
                scenarios
                controls
                weatherEnvelope
                locationLab
                transitionLab
                accessibilityLab
                authority
                readout
                feedback
            }
            .padding(20)
        }
        .background(ConsolePalette.background)
        .onAppear(perform: loadExistingOverrides)
        .onDisappear {
            store.clearAll()
            engine.previewCoordinateOverride = nil
            engine.previewTimeZoneOverride = nil
            engine.previewReducedMotionOverride = nil
            engine.previewReducedTransparencyOverride = nil
            engine.previewSeasonPhaseOverride = nil
            engine.previewWeatherEventAgeOverride = nil
            engine.refreshNow()
        }
        .onChange(of: useLiveTime) { _, _ in applyOverrides() }
        .onChange(of: minute) { _, _ in applyOverrides() }
        .onChange(of: useLiveWeather) { _, _ in applyOverrides() }
        .onChange(of: forcedKind) { _, _ in applyOverrides() }
        .onChange(of: forcedIntensity) { _, _ in applyOverrides() }
        .onChange(of: useLiveSeason) { _, _ in applyOverrides() }
        .onChange(of: forcedSeason) { _, _ in applyOverrides() }
        .onChange(of: forcedPhase) { _, _ in applyPhaseOverride() }
        .onChange(of: scrubEventAge) { _, _ in applyWeatherEventAge() }
        .onChange(of: eventAgeMinutes) { _, _ in applyWeatherEventAge() }
        .onChange(of: useSystemAccessibility) { _, _ in applyAccessibilityPreview() }
        .onChange(of: previewReducedMotion) { _, _ in applyAccessibilityPreview() }
        .onChange(of: previewReducedTransparency) { _, _ in applyAccessibilityPreview() }
        .onChange(of: useLiveLocation) { _, isLive in
            if isLive {
                clearCoordinateOverride()
            } else {
                applyManualCoordinate()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sun.horizon.fill")
                .font(.system(size: 26))
                .foregroundStyle(ConsolePalette.statusColor(.running))
            VStack(alignment: .leading, spacing: 3) {
                Text("Environment Studio")
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(ConsolePalette.textPrimary)
                Text("Renders the real background layers. Force an hour, season, weather kind, or coordinate; scrub a cross-fade; copy a look report. Closing the pane returns the app to live values.")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(ConsolePalette.textSecondary)
            }
            Spacer()
            Button("Reset to live") { resetToLive() }
                .font(.system(.caption, design: .monospaced))
        }
    }

    // MARK: - Preview

    private var preview: some View {
        ZStack(alignment: .bottomLeading) {
            EnvironmentBackgroundView(engine: engine, presentationOverride: scrubOverride)
        }
        .frame(height: expandedPreview ? 620 : 400)
        .animation(AsterismaMotion.standard, value: expandedPreview)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(ConsolePalette.border, lineWidth: 1))
        .overlay(alignment: .topLeading) { previewBadges }
        .overlay(alignment: .bottomTrailing) {
            Button(expandedPreview ? "Compact" : "Expand") {
                expandedPreview.toggle()
            }
            .font(.system(.caption2, design: .monospaced))
            .buttonStyle(.bordered)
            .padding(10)
        }
    }

    private var previewBadges: some View {
        HStack(spacing: 8) {
            Text(clockText)
                .font(.system(.callout, design: .monospaced).weight(.semibold))
            Text(useLiveTime ? "LIVE CLOCK" : "FORCED TIME")
                .font(.system(.caption2, design: .monospaced).weight(.black))
                .tracking(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(.black.opacity(0.35)))
            Text(inspected.season.rawValue.uppercased())
                .font(.system(.caption2, design: .monospaced).weight(.black))
                .tracking(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(.black.opacity(0.35)))
            Text(inspected.weatherVisual.kind.displayName.uppercased())
                .font(.system(.caption2, design: .monospaced).weight(.black))
                .tracking(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(.black.opacity(0.35)))
            if let from = transitionA, let to = transitionB {
                Text("A→B \(percent(scrubProgress))")
                    .font(.system(.caption2, design: .monospaced).weight(.black))
                    .tracking(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.yellow.opacity(0.30)))
                Text("\(formatted(from.minuteOfDay)) → \(formatted(to.minuteOfDay))")
                    .font(.system(.caption2, design: .monospaced).weight(.black))
                    .tracking(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.35)))
            }
            if inspected.weatherFreshness != .live {
                Text(inspected.weatherFreshness.displayName.uppercased())
                    .font(.system(.caption2, design: .monospaced).weight(.black))
                    .tracking(1)
                    .foregroundStyle(.orange)
            }
        }
        .foregroundStyle(.white)
        .padding(10)
    }

    // MARK: - Scenario presets

    private var scenarios: some View {
        panel("SCENARIO PRESETS") {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 200), spacing: 8)],
                alignment: .leading, spacing: 8
            ) {
                ForEach(Self.scenarios) { scenario in
                    Button {
                        apply(scenario)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(scenario.label)
                                .font(.system(.caption, design: .monospaced))
                            Text(scenario.detail)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(ConsolePalette.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
            }
            Text("Each preset sets time, season, and weather together — the combination the authority resolver composes in production.")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(ConsolePalette.textSecondary)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            panel("TIME OF DAY") {
                Toggle("Use the real clock", isOn: $useLiveTime)
                    .font(.system(.callout, design: .monospaced))
                HStack(spacing: 12) {
                    Slider(value: minuteBinding, in: 0...1439, step: 1)
                        .accessibilityLabel("Time of day, one-minute steps")
                        .accessibilityValue(formatted(displayedMinute))
                    Text(formatted(displayedMinute))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(ConsolePalette.textPrimary)
                        .monospacedDigit()
                        .frame(width: 58, alignment: .trailing)
                }
                HStack(spacing: 6) {
                    ForEach(presets, id: \.label) { preset in
                        Button(preset.label) {
                            useLiveTime = false
                            minute = Double(preset.minute)
                        }
                        .font(.system(.caption2, design: .monospaced))
                        .buttonStyle(.bordered)
                    }
                }
            }

            panel("SEASON") {
                Toggle("Use the calendar season", isOn: $useLiveSeason)
                    .font(.system(.callout, design: .monospaced))
                Picker("Season", selection: $forcedSeason) {
                    ForEach(SeasonalPeriod.allCases, id: \.self) { season in
                        Text(season.rawValue.capitalized).tag(season)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(useLiveSeason)
                .opacity(useLiveSeason ? 0.45 : 1)
                Text(seasonWeightText)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(ConsolePalette.textSecondary)

                HStack(spacing: 8) {
                    Text("PHASE")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(ConsolePalette.textSecondary)
                    Picker("Phase", selection: $forcedPhase) {
                        ForEach(PhaseSelection.allCases) { phase in
                            Text(phase.label).tag(phase)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("Season phase")
                }
                Text("Early ramps the season in, prime is its peak, late fades it out. The phase scales seasonal air and particles; the hour of day still owns the palette.")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(ConsolePalette.textSecondary)
            }

            panel("WEATHER LAYER") {
                Toggle("Use the latest captured weather", isOn: $useLiveWeather)
                    .font(.system(.callout, design: .monospaced))
                HStack(spacing: 12) {
                    Picker("Kind", selection: $forcedKind) {
                        ForEach(WeatherVisualKind.allCases) { kind in
                            Label(kind.displayName, systemImage: kind.symbolName).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                    .disabled(useLiveWeather)

                    Slider(value: $forcedIntensity, in: 0...1, step: 0.05)
                        .disabled(useLiveWeather)
                    Text(percent(forcedIntensity))
                        .font(.system(.caption, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(ConsolePalette.textSecondary)
                        .frame(width: 44, alignment: .trailing)
                }
                .opacity(useLiveWeather ? 0.45 : 1)

                Divider().overlay(ConsolePalette.border)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("FINE CLOCK")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(ConsolePalette.textSecondary)
                        Button { nudgeMinute(by: -1) } label: {
                            Image(systemName: "minus")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("One minute earlier")
                        .accessibilityLabel("One minute earlier")

                        Slider(value: minuteBinding, in: 0...1439, step: 1)
                            .accessibilityLabel("Time of day while testing weather")
                            .accessibilityValue(formatted(displayedMinute))

                        Button { nudgeMinute(by: 1) } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("One minute later")
                        .accessibilityLabel("One minute later")

                        Text(formatted(displayedMinute))
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(ConsolePalette.textPrimary)
                            .monospacedDigit()
                            .frame(width: 58, alignment: .trailing)
                    }

                    HStack(spacing: 8) {
                        Text("Jump to")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(ConsolePalette.textSecondary)
                        TextField("16:18 or 4:18 PM", text: $clockEntry)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 120)
                            .onSubmit { commitClockEntry() }
                            .accessibilityLabel("Jump to an exact time")
                        Button("Set") { commitClockEntry() }
                            .font(.system(.caption2, design: .monospaced))
                            .controlSize(.small)
                        Spacer()
                    }

                    Text(clockEntryInvalid
                        ? "Enter a time as HH:MM or 4:18 PM."
                        : "One-minute steps while the weather controls stay unchanged — compare 16:16 rain against 16:18 rain directly.")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(clockEntryInvalid
                            ? AnyShapeStyle(Color.orange)
                            : AnyShapeStyle(ConsolePalette.textSecondary))
                }

                Text(liveWeatherProvenance)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(ConsolePalette.textSecondary)
            }
        }
    }

    // MARK: - Precipitation envelope

    private var weatherEnvelope: some View {
        panel("PRECIPITATION ENVELOPE") {
            Text("The observed rate still sets the ceiling. This slow envelope lets a long rain or snow pass visibly thicken and thin instead of holding one strength; the full arc is about two hours.")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(ConsolePalette.textSecondary)

            HStack(spacing: 10) {
                Toggle("Scrub event age", isOn: $scrubEventAge)
                    .font(.system(.callout, design: .monospaced))
                Slider(value: $eventAgeMinutes, in: 0...120, step: 1)
                    .disabled(!scrubEventAge)
                    .accessibilityLabel("Precipitation event age")
                    .accessibilityValue("\(Int(eventAgeMinutes)) minutes")
                Text(String(format: "%d min", Int(eventAgeMinutes)))
                    .font(.system(.callout, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(ConsolePalette.textPrimary)
                    .frame(width: 58, alignment: .trailing)
            }
            .opacity(scrubEventAge ? 1 : 0.55)

            HStack(spacing: 10) {
                Text("Pulse")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(ConsolePalette.textSecondary)
                Text(String(format: "×%.2f", engine.weatherTemporalMultiplier))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(ConsolePalette.textPrimary)
                    .monospacedDigit()
                Spacer()
                Text(inspected.weatherVisual.kind.isPrecipitation
                    ? "\(inspected.weatherVisual.kind.displayName) · \(formatted(displayedMinute))"
                    : "no precipitation — envelope idle")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(ConsolePalette.textSecondary)
            }

            Text(scrubEventAge
                ? "Scrubbing a preview age only; the app's own engine uses the real event clock."
                : "A new event starts at 55% and settles into its slow pulse over the first 8 minutes.")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(ConsolePalette.textSecondary)
        }
    }

    // MARK: - Location lab

    private var locationLab: some View {
        panel("LOCATION & RECALIBRATION") {
            Toggle("Use the detected location", isOn: $useLiveLocation)
                .font(.system(.callout, design: .monospaced))

            HStack(alignment: .bottom, spacing: 8) {
                coordinateField("Latitude", text: $latitudeText)
                coordinateField("Longitude", text: $longitudeText)
                Button("Apply") { applyManualCoordinate() }
                    .font(.system(.caption, design: .monospaced))
                Button("Refresh engine") { engine.refreshNow() }
                    .font(.system(.caption, design: .monospaced))
                Spacer()
            }
            .opacity(useLiveLocation ? 0.45 : 1)

            HStack(spacing: 6) {
                ForEach(Self.locationPresets) { preset in
                    Button(preset.label) { apply(preset) }
                        .font(.system(.caption2, design: .monospaced))
                        .buttonStyle(.bordered)
                }
            }
            .disabled(useLiveLocation)
            .opacity(useLiveLocation ? 0.45 : 1)

            if let coordinateError {
                Text(coordinateError)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.orange)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: 10)],
                alignment: .leading, spacing: 10
            ) {
                metric("Resolved coordinate", resolvedCoordinateText)
                metric("Location source", locationSourceText)
                metric("Solar timezone", solarTimeZoneText)
                metric("Sunrise", inspected.solarDaylight.hasLocation
                    ? formatted(inspected.solarDaylight.sunriseMinute) : "—")
                metric("Solar noon", inspected.solarDaylight.hasLocation
                    ? formatted(inspected.solarDaylight.solarNoonMinute) : "—")
                metric("Sunset", inspected.solarDaylight.hasLocation
                    ? formatted(inspected.solarDaylight.sunsetMinute) : "—")
                metric("Daylight", daylightText)
                metric("Solar elevation", String(
                    format: "%.1f°", inspected.solarDaylight.solarElevationDegrees))
                metric("Palette minute", formatted(inspected.minuteOfDay))
                metric("Wall clock", formatted(inspected.clockMinuteOfDay))
            }

            Text("A manual coordinate uses the longitude-derived solar offset (15° per hour) so the sun behaves as it would there. It is not a legal timezone database, and it never persists outside this pane.")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(ConsolePalette.textSecondary)
        }
    }

    // MARK: - Transition lab

    private var transitionLab: some View {
        panel("TRANSITION LAB") {
            HStack(spacing: 8) {
                Button("Capture A (target)") {
                    transitionA = engine.state
                    scrubProgress = 0
                }
                Button("Capture B (target)") {
                    transitionB = engine.state
                    scrubProgress = 1
                }
                Button("Back to live transition") {
                    transitionA = nil
                    transitionB = nil
                }
                .disabled(transitionA == nil && transitionB == nil)
                Spacer()
            }
            .font(.system(.caption, design: .monospaced))

            if let from = transitionA, let to = transitionB {
                HStack(spacing: 12) {
                    Text("A")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(ConsolePalette.textSecondary)
                    Slider(value: $scrubProgress, in: 0...1)
                    Text(percent(scrubProgress))
                        .font(.system(.caption, design: .monospaced))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                Text("A  \(summary(from))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(ConsolePalette.textSecondary)
                Text("B  \(summary(to))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(ConsolePalette.textSecondary)
            } else {
                Text("Capture the current target as A, change the controls, capture again as B, then scrub the cross-fade. The preview freezes on the scrubbed frame until you return to the live transition.")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(ConsolePalette.textSecondary)
            }
        }
    }

    // MARK: - Accessibility

    private var accessibilityLab: some View {
        panel("ACCESSIBILITY") {
            Text("Reduce Motion freezes the drifting atmosphere, stars, shooting stars, seasonal particles, and precipitation, and shortens the cross-fade to 0.4 s. Reduce Transparency cuts blur and atmosphere to 25%.")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(ConsolePalette.textSecondary)

            Toggle("Follow the system accessibility settings", isOn: $useSystemAccessibility)
                .font(.system(.callout, design: .monospaced))

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Preview Reduce Motion", isOn: $previewReducedMotion)
                    .font(.system(.callout, design: .monospaced))
                Toggle("Preview Reduce Transparency", isOn: $previewReducedTransparency)
                    .font(.system(.callout, design: .monospaced))
            }
            .disabled(useSystemAccessibility)
            .opacity(useSystemAccessibility ? 0.45 : 1)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: 10)],
                alignment: .leading, spacing: 10
            ) {
                metric("System reduce motion", systemReducedMotion ? "on" : "off")
                metric("System reduce transparency", systemReducedTransparency ? "on" : "off")
                metric("Effective reduce motion", inspected.reducedMotion ? "on" : "off")
                metric("Effective reduce transparency",
                    inspected.reducedTransparency ? "on" : "off")
                metric("Cross-fade span", String(
                    format: "%.1fs",
                    inspected.reducedMotion
                        ? EnvironmentPresentation.reducedMotionTransitionDuration
                        : engine.activeTransitionDuration))
                metric("Atmosphere", String(format: "%.2f", inspected.atmosphericOpacity))
            }

            Text(useSystemAccessibility
                ? "Mirroring macOS. Change a system accessibility setting and the preview follows within one engine tick."
                : "Previewing the reduced path only inside this pane. The app's own engine keeps reading macOS.")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(ConsolePalette.textSecondary)
        }
    }

    // MARK: - Authority

    private var authority: some View {
        panel("AUTHORITY & CROSS-FADE") {
            authorityRow(
                rank: "1", name: "TIME",
                body: "Base palette and solar day · \(anchorText)")
            authorityRow(
                rank: "2", name: "WEATHER",
                body: "\(inspected.weatherVisual.kind.displayName)"
                    + " · intensity \(percent(inspected.weatherVisual.intensity))"
                    + " · cloud \(percent(inspected.weatherVisual.cloud))"
                    + " · wind \(percent(inspected.weatherVisual.wind))"
                    + " · \(inspected.weatherFreshness.displayName.lowercased())")
            authorityRow(
                rank: "3", name: "SEASON",
                body: "\(seasonWeightText)"
                    + " · \(inspected.seasonalPhase.label(for: inspected.season))"
                    + " \(percent(inspected.seasonalMaturity)) maturity"
                    + " · tint \(percent(inspected.seasonalTintStrength))"
                    + " · particles \(percent(inspected.seasonalParticleIntensity))")

            Divider().overlay(ConsolePalette.border)

            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                transitionStatus(at: context.date)
            }
        }
    }

    private func authorityRow(rank: String, name: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(rank)
                .font(.system(.caption2, design: .monospaced).weight(.bold))
                .foregroundStyle(ConsolePalette.background)
                .frame(width: 16, height: 16)
                .background(Circle().fill(ConsolePalette.statusColor(.running)))
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(.caption2, design: .monospaced).weight(.bold))
                    .foregroundStyle(ConsolePalette.textPrimary)
                Text(body)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(ConsolePalette.textSecondary)
            }
        }
    }

    private func transitionStatus(at date: Date) -> some View {
        let duration = engine.state.reducedMotion
            ? EnvironmentPresentation.reducedMotionTransitionDuration
            : engine.activeTransitionDuration
        let progress = EnvironmentPresentation.progress(
            startedAt: engine.transitionStartedAt,
            now: date,
            duration: duration)
        let from = engine.previousState.weatherVisual
        let to = engine.state.weatherVisual

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("CROSS-FADE")
                    .font(.system(.caption2, design: .monospaced).weight(.bold))
                    .foregroundStyle(ConsolePalette.textPrimary)
                Text("\(from.kind.displayName) → \(to.kind.displayName)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(ConsolePalette.textSecondary)
                Spacer()
                Text(percent(progress))
                    .font(.system(.caption2, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(ConsolePalette.textSecondary)
            }
            ProgressView(value: progress)
                .tint(ConsolePalette.statusColor(.running))
            Text(String(
                format: "%.1fs span · %d frames at 60 Hz · engine tick every %ds",
                duration,
                Int((duration * 60).rounded()),
                Int(engine.recomputeIntervalSecondsForStudio)))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(ConsolePalette.textSecondary)
        }
    }

    // MARK: - Readout

    private var readout: some View {
        panel("COMPUTED STATE") {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 160), spacing: 10)],
                alignment: .leading, spacing: 10
            ) {
                metric("Preview", scrubOverride == nil
                    ? "live transition" : "A→B \(percent(scrubProgress))")
                metric("Wall clock", formatted(inspected.clockMinuteOfDay))
                metric("Palette clock", formatted(inspected.minuteOfDay))
                metric("Anchor", anchorText)
                metric("Season", "\(inspected.season.rawValue.capitalized) · \(seasonWeightText)")
                metric("Season phase", "\(inspected.seasonalPhase.label(for: inspected.season))"
                    + " · \(percent(inspected.seasonalMaturity)) maturity")
                metric("Sun", sunText)
                metric("Weather", inspected.weatherVisual.kind.displayName
                    + " · \(inspected.weatherFreshness.displayName.lowercased())")
                metric("Location", resolvedCoordinateText)
                metric("Gradient luminance", String(format: "%.2f", inspected.gradientLuminance))
                metric("Readability scrim", String(format: "%.2f", inspected.readabilityScrim))
                metric("Star visibility", String(format: "%.2f", inspected.starVisibility))
                metric("Atmosphere", String(format: "%.2f", inspected.atmosphericOpacity))
                metric("Night intensity", String(format: "%.2f", inspected.nightIntensity))
                metric("Seasonal tint", String(format: "%.2f", inspected.seasonalTintStrength))
                metric("Season particles", String(format: "%.2f", inspected.seasonalParticleIntensity))
                metric("Celestial glow", String(format: "%.2f", inspected.celestialGlowOpacity))
                metric("Reduced motion", inspected.reducedMotion ? "on" : "off")
            }
        }
    }

    // MARK: - Feedback

    private var feedback: some View {
        panel("LOOK FEEDBACK") {
            Text("Describe what reads wrong — colour temperature, brightness, star strength, rain weight, transition timing. The notes ride along with the exact composed state in the copied report.")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(ConsolePalette.textSecondary)
            TextEditor(text: $notes)
                .font(.system(.caption, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 90)
                .background(ConsolePalette.background)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(ConsolePalette.border, lineWidth: 1))
            HStack(spacing: 10) {
                Button("Copy look report") { copyLookReport() }
                    .font(.system(.caption, design: .monospaced))
                if let lastCopiedAt {
                    Text("Copied \(lastCopiedAt.formatted(date: .omitted, time: .standard))")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(ConsolePalette.textSecondary)
                }
                Spacer()
            }
        }
    }

    // MARK: - Actions

    private func loadExistingOverrides() {
        guard !didLoad else { return }
        didLoad = true
        if let forcedMinute = store.minuteOverride {
            useLiveTime = false
            minute = Double(forcedMinute)
        }
        if let forced = store.weatherOverride {
            useLiveWeather = false
            forcedKind = forced.kind
            forcedIntensity = forced.intensity
        }
        if let forced = store.seasonOverride {
            useLiveSeason = false
            forcedSeason = forced
        }
        engine.refreshNow()
    }

    private func applyOverrides() {
        if useLiveTime {
            store.clearMinuteOverride()
        } else {
            store.setMinuteOverride(Int(minute.rounded()))
        }
        if useLiveWeather {
            store.clearWeatherOverride()
        } else {
            store.setWeatherOverride(forcedKind, intensity: forcedIntensity)
        }
        if useLiveSeason {
            store.clearSeasonOverride()
        } else {
            store.setSeasonOverride(forcedSeason)
        }
        engine.refreshNow()
    }

    /// A minute-precise binding: touching the slider turns the real clock off
    /// in the same transaction, so the value the owner drags is the value the
    /// engine renders. No stale "live" label over a forced frame.
    private var minuteBinding: Binding<Double> {
        Binding(
            get: { useLiveTime ? inspected.minuteOfDay : minute },
            set: { value in
                useLiveTime = false
                minute = value
                clockEntryInvalid = false
            })
    }

    private func nudgeMinute(by delta: Double) {
        useLiveTime = false
        var next = (minute + delta).truncatingRemainder(dividingBy: 1440)
        if next < 0 { next += 1440 }
        minute = next
        clockEntryInvalid = false
    }

    private func commitClockEntry() {
        var text = clockEntry.trimmingCharacters(in: .whitespaces).lowercased()
        var meridiem: Bool?
        if text.hasSuffix("pm") {
            meridiem = true
            text.removeLast(2)
        } else if text.hasSuffix("am") {
            meridiem = false
            text.removeLast(2)
        }
        text = text.trimmingCharacters(in: .whitespaces)

        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              var hour = Int(parts[0]),
              let minuteValue = Int(parts[1]),
              (0...59).contains(minuteValue)
        else {
            clockEntryInvalid = true
            return
        }

        if let meridiem {
            guard (1...12).contains(hour) else {
                clockEntryInvalid = true
                return
            }
            hour = hour % 12 + (meridiem ? 12 : 0)
        } else if !(0...23).contains(hour) {
            clockEntryInvalid = true
            return
        }

        useLiveTime = false
        minute = Double(hour * 60 + minuteValue)
        clockEntry = ""
        clockEntryInvalid = false
    }

    private func applyAccessibilityPreview() {
        if useSystemAccessibility {
            engine.previewReducedMotionOverride = nil
            engine.previewReducedTransparencyOverride = nil
        } else {
            engine.previewReducedMotionOverride = previewReducedMotion
            engine.previewReducedTransparencyOverride = previewReducedTransparency
        }
        engine.refreshNow()
    }

    private func applyPhaseOverride() {
        engine.previewSeasonPhaseOverride = forcedPhase.phase
        engine.refreshNow()
    }

    private func applyWeatherEventAge() {
        engine.previewWeatherEventAgeOverride = scrubEventAge
            ? eventAgeMinutes * 60
            : nil
        engine.refreshNow()
    }

    private func resetToLive() {
        useLiveTime = true
        useLiveWeather = true
        useLiveSeason = true
        useLiveLocation = true
        useSystemAccessibility = true
        previewReducedMotion = false
        previewReducedTransparency = false
        forcedPhase = .auto
        scrubEventAge = false
        eventAgeMinutes = 30
        appliedCoordinate = nil
        coordinateError = nil
        transitionA = nil
        transitionB = nil
        store.clearAll()
        engine.previewCoordinateOverride = nil
        engine.previewTimeZoneOverride = nil
        engine.previewReducedMotionOverride = nil
        engine.previewReducedTransparencyOverride = nil
        engine.previewSeasonPhaseOverride = nil
        engine.previewWeatherEventAgeOverride = nil
        engine.refreshNow()
    }

    private func apply(_ scenario: Scenario) {
        useLiveTime = false
        minute = Double(scenario.minute)
        useLiveSeason = false
        forcedSeason = scenario.season
        useLiveWeather = false
        forcedKind = scenario.kind
        forcedIntensity = scenario.intensity
        transitionA = nil
        transitionB = nil
        engine.refreshNow()
    }

    private func applyManualCoordinate() {
        guard let latitude = Double(latitudeText.trimmingCharacters(in: .whitespaces)),
              let longitude = Double(longitudeText.trimmingCharacters(in: .whitespaces)),
              (-90...90).contains(latitude),
              (-180...180).contains(longitude)
        else {
            coordinateError = "Latitude must be −90…90 and longitude −180…180."
            useLiveLocation = true
            return
        }
        coordinateError = nil
        let coordinate = SolarCoordinate(latitude: latitude, longitude: longitude)
        appliedCoordinate = coordinate
        useLiveLocation = false
        engine.previewCoordinateOverride = coordinate
        engine.previewTimeZoneOverride = Self.solarTimeZone(forLongitude: longitude)
        engine.refreshNow()
    }

    private func apply(_ preset: LocationPreset) {
        latitudeText = String(format: "%.4f", preset.latitude)
        longitudeText = String(format: "%.4f", preset.longitude)
        useLiveLocation = false
        applyManualCoordinate()
    }

    private func clearCoordinateOverride() {
        appliedCoordinate = nil
        engine.previewCoordinateOverride = nil
        engine.previewTimeZoneOverride = nil
        engine.refreshNow()
    }

    // MARK: - Report

    private func copyLookReport() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lookReport(), forType: .string)
        lastCopiedAt = Date()
    }

    private func lookReport() -> String {
        let state = inspected
        let solar = state.solarDaylight
        let anchors = state.currentAnchorBlend
            .filter { $0.value > 0.01 }
            .sorted { $0.value > $1.value }
            .map { "\($0.key.displayName) \(percent($0.value))" }
            .joined(separator: " · ")

        let previewText: String
        if let from = transitionA, let to = transitionB {
            previewText = "A→B scrub at \(percent(scrubProgress))"
                + " (A \(formatted(from.minuteOfDay)) \(from.weatherVisual.kind.displayName)"
                + "; B \(formatted(to.minuteOfDay)) \(to.weatherVisual.kind.displayName))"
        } else {
            previewText = "live transition"
        }

        var lines: [String] = [
            "ASTERISMA ENVIRONMENT LOOK REPORT",
            "captured: \(Date().formatted(date: .numeric, time: .standard))",
            "preview: \(previewText)",
            "clock: \(formatted(state.minuteOfDay)) palette"
                + " · \(formatted(state.clockMinuteOfDay)) wall"
                + " · time \(useLiveTime ? "live" : "forced \(Int(minute.rounded()))")",
            "location: \(resolvedCoordinateText) · \(locationSourceText) · \(solarTimeZoneText)",
            "season: \(seasonWeightText)"
                + " · \(state.seasonalPhase.label(for: state.season))"
                + " \(percent(state.seasonalMaturity)) maturity"
                + " · tint \(percent(state.seasonalTintStrength))"
                + " · particles \(percent(state.seasonalParticleIntensity))"
                + " · mode \(useLiveSeason ? "live" : "forced")",
            "weather: \(state.weatherVisual.kind.displayName)"
                + " · intensity \(percent(state.weatherVisual.intensity))"
                + " · cloud \(percent(state.weatherVisual.cloud))"
                + " · wind \(percent(state.weatherVisual.wind))"
                + " · \(state.weatherFreshness.displayName.lowercased())"
                + " · mode \(useLiveWeather ? "live" : "forced")"
                + " · envelope ×\(String(format: "%.2f", engine.weatherTemporalMultiplier))"
                + (scrubEventAge ? " at \(Int(eventAgeMinutes)) min (scrubbed)" : ""),
            "weather crossfade: \(engine.previousState.weatherVisual.kind.displayName)"
                + " → \(state.weatherVisual.kind.displayName)",
            "authority: time primary · weather ≤18% · season ≤14%",
            "anchor blend: \(anchors)",
            "palette: luminance \(String(format: "%.3f", state.gradientLuminance))"
                + " · scrim \(String(format: "%.3f", state.readabilityScrim))"
                + " · stars \(String(format: "%.3f", state.starVisibility))"
                + " · night \(String(format: "%.3f", state.nightIntensity))"
                + " · atmosphere \(String(format: "%.3f", state.atmosphericOpacity))"
                + " · glow \(String(format: "%.3f", state.celestialGlowOpacity))",
            "ambient light: \(hex(state.ambientLightColor))",
            "seasonal tint colour: \(hex(state.seasonalTint))",
        ]

        let solarBasis = useLiveTime
            ? "actual instant"
            : "simulated at \(formatted(state.minuteOfDay))"
        if solar.hasLocation {
            let duration = Int(solar.daylightDurationMinutes.rounded())
            lines.append(
                "solar: basis \(solarBasis)"
                    + " · sunrise \(formatted(solar.sunriseMinute))"
                    + " · noon \(formatted(solar.solarNoonMinute))"
                    + " · sunset \(formatted(solar.sunsetMinute))"
                    + " · daylight \(duration / 60)h \(duration % 60)m"
                    + " · elevation \(String(format: "%.1f°", solar.solarElevationDegrees))"
                    + " · daylight factor \(String(format: "%.2f", solar.daylightFactor))"
                    + " · golden \(String(format: "%.2f", solar.goldenHourFactor))")
        } else {
            lines.append("solar: fixed equinox track (no coordinate) · basis \(solarBasis)")
        }

        lines.append("gradient:")
        for stop in state.backgroundGradient {
            lines.append(String(format: "  %.3f  %@", stop.location, hex(stop.color)))
        }
        lines.append("accessibility: system reduce motion \(systemReducedMotion ? "on" : "off")"
            + " · system reduce transparency \(systemReducedTransparency ? "on" : "off")"
            + " · effective reduced motion \(state.reducedMotion ? "on" : "off")"
            + " · effective reduced transparency \(state.reducedTransparency ? "on" : "off")"
            + " · preview \(useSystemAccessibility ? "system" : "forced")")
        lines.append("notes:")
        lines.append(notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "  (none)"
            : notes)

        return lines.joined(separator: "\n")
    }

    // MARK: - Formatting

    /// The state actually on screen: the scrubbed interpolation when the
    /// transition lab holds a frame, otherwise the engine's target.
    private var inspected: EnvironmentState {
        guard let from = transitionA, let to = transitionB else { return engine.state }
        return EnvironmentPresentation.interpolate(
            from: from, to: to, progress: scrubProgress)
    }

    private var scrubOverride: EnvironmentPresentationOverride? {
        guard let from = transitionA, let to = transitionB else { return nil }
        return EnvironmentPresentationOverride(
            from: from, to: to, progress: scrubProgress)
    }

    private var clockText: String { formatted(inspected.minuteOfDay) }

    /// The minute the slider is showing: the live palette minute while the real
    /// clock is in charge, the forced minute otherwise.
    private var displayedMinute: Double {
        useLiveTime ? inspected.minuteOfDay : minute
    }

    private var systemReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var systemReducedTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    private var anchorText: String {
        inspected.currentAnchorBlend
            .filter { $0.value > 0.01 }
            .sorted { $0.value > $1.value }
            .map { "\($0.key.displayName) \(percent($0.value))" }
            .joined(separator: " · ")
    }

    private var liveWeatherProvenance: String {
        let source = inspected.weatherFreshness.displayName
        guard let condition = inspected.weatherModifier.condition else {
            return "Weather source: \(source). No captured snapshot in the last 6 hours — the layer stays clear."
        }
        let captured = inspected.weatherModifier.capturedAt?
            .formatted(date: .abbreviated, time: .shortened) ?? "unknown time"
        return "Weather source: \(source). Latest capture: \(condition.rawValue) at \(captured)."
    }

    private var resolvedCoordinateText: String {
        guard let coordinate = engine.resolvedCoordinate else {
            return "none — fixed equinox track"
        }
        return String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
    }

    private var locationSourceText: String {
        if useLiveLocation { return "detected" }
        return appliedCoordinate == nil ? "none applied" : "manual"
    }

    private var solarTimeZoneText: String {
        let timezone: TimeZone
        if !useLiveLocation, let coordinate = appliedCoordinate {
            timezone = Self.solarTimeZone(forLongitude: coordinate.longitude)
        } else {
            timezone = .autoupdatingCurrent
        }
        return Self.offsetLabel(timezone, at: Date())
    }

    private var daylightText: String {
        let solar = inspected.solarDaylight
        guard solar.hasLocation else { return "—" }
        let duration = Int(solar.daylightDurationMinutes.rounded())
        return "\(duration / 60)h \(duration % 60)m"
    }

    private func summary(_ state: EnvironmentState) -> String {
        "\(formatted(state.minuteOfDay)) · \(state.season.rawValue.capitalized)"
            + " · \(state.weatherVisual.kind.displayName)"
            + " · stars \(String(format: "%.2f", state.starVisibility))"
            + " · \(state.weatherFreshness.displayName.lowercased())"
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", EnvironmentMath.clampUnit(value) * 100)
    }

    private func hex(_ color: EnvironmentColor) -> String {
        String(
            format: "#%02X%02X%02X",
            Int((EnvironmentMath.clampUnit(color.red) * 255).rounded()),
            Int((EnvironmentMath.clampUnit(color.green) * 255).rounded()),
            Int((EnvironmentMath.clampUnit(color.blue) * 255).rounded()))
    }

    private func formatted(_ minute: Double) -> String {
        let total = Int(minute.rounded())
        return String(format: "%02d:%02d", (total / 60) % 24, total % 60)
    }

    private var seasonWeightText: String {
        inspected.seasonalWeights
            .filter { $0.value > 0.01 }
            .sorted { $0.value > $1.value }
            .map { "\($0.key.rawValue.capitalized) \(percent($0.value))" }
            .joined(separator: " · ")
    }

    private var sunText: String {
        let solar = inspected.solarDaylight
        guard solar.hasLocation else { return "Fixed equinox track" }
        let duration = Int(solar.daylightDurationMinutes.rounded())
        return "↑ \(formatted(solar.sunriseMinute)) · ↓ \(formatted(solar.sunsetMinute)) · \(duration / 60)h \(duration % 60)m"
    }

    private var presets: [(label: String, minute: Int)] {
        [("Dawn", 345), ("Morning", 480), ("Noon", 720),
         ("Golden", 1080), ("Dusk", 1170), ("Night", 60)]
    }

    private static func solarTimeZone(forLongitude longitude: Double) -> TimeZone {
        let hours = (longitude / 15.0).rounded()
        return TimeZone(secondsFromGMT: Int(hours) * 3600) ?? .gmt
    }

    private static func offsetLabel(_ timezone: TimeZone, at date: Date) -> String {
        let seconds = timezone.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "−" : "+"
        let minutes = abs(seconds) / 60
        return String(format: "UTC%@%02d:%02d", sign, minutes / 60, minutes % 60)
    }

    // MARK: - Helpers

    private func panel<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(ConsolePalette.textSecondary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ConsolePalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(ConsolePalette.border, lineWidth: 1))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(ConsolePalette.textSecondary)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(ConsolePalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(ConsolePalette.background)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func coordinateField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(ConsolePalette.textSecondary)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .frame(width: 110)
        }
    }

    // MARK: - Presets

    private enum PhaseSelection: String, CaseIterable, Identifiable {
        case auto
        case early
        case prime
        case late

        var id: String { rawValue }

        var label: String {
            switch self {
            case .auto: return "Auto"
            case .early: return "Early"
            case .prime: return "Prime"
            case .late: return "Late"
            }
        }

        var phase: SeasonalPhase? {
            switch self {
            case .auto: return nil
            case .early: return .early
            case .prime: return .prime
            case .late: return .late
            }
        }
    }

    private struct Scenario: Identifiable {
        let id: String
        let label: String
        let minute: Int
        let season: SeasonalPeriod
        let kind: WeatherVisualKind
        let intensity: Double

        var detail: String {
            "\(Self.clock(minute)) · \(season.rawValue) · \(kind.displayName)"
                + String(format: " %.0f%%", intensity * 100)
        }

        private static func clock(_ minute: Int) -> String {
            String(format: "%02d:%02d", (minute / 60) % 24, minute % 60)
        }
    }

    private static let scenarios: [Scenario] = [
        Scenario(id: "summer-humid", label: "Summer afternoon · humid cloud",
                 minute: 926, season: .summer, kind: .cloudy, intensity: 0.55),
        Scenario(id: "summer-midnight", label: "Summer midnight · clear",
                 minute: 30, season: .summer, kind: .clear, intensity: 0.10),
        Scenario(id: "autumn-golden", label: "Autumn golden hour · clear",
                 minute: 1055, season: .autumn, kind: .clear, intensity: 0.20),
        Scenario(id: "spring-dawn-fog", label: "Spring dawn · fog",
                 minute: 380, season: .spring, kind: .fog, intensity: 0.60),
        Scenario(id: "winter-storm-night", label: "Winter night · thunderstorm",
                 minute: 1368, season: .winter, kind: .storm, intensity: 0.85),
        Scenario(id: "winter-blizzard", label: "Winter night · blizzard",
                 minute: 130, season: .winter, kind: .heavySnow, intensity: 0.90),
    ]

    private struct LocationPreset: Identifiable {
        let id: String
        let label: String
        let latitude: Double
        let longitude: Double
    }

    private static let locationPresets: [LocationPreset] = [
        LocationPreset(id: "sf", label: "San Francisco", latitude: 37.7749, longitude: -122.4194),
        LocationPreset(id: "quito", label: "Quito", latitude: -0.1807, longitude: -78.4678),
        LocationPreset(id: "reykjavik", label: "Reykjavík", latitude: 64.1466, longitude: -21.9426),
        LocationPreset(id: "tromso", label: "Tromsø", latitude: 69.6492, longitude: 18.9553),
        LocationPreset(id: "singapore", label: "Singapore", latitude: 1.3521, longitude: 103.8198),
        LocationPreset(id: "sydney", label: "Sydney", latitude: -33.8688, longitude: 151.2093),
    ]
}

#endif
