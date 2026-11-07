//  EnvironmentStudioView.swift
//  AsterismaV2.5 — DEVELOPER CONSOLE
//
//  The missing visual proving ground for the environment system. Before this
//  pane there was no way to see the background at a chosen hour or force a
//  weather kind anywhere in the app — the studio existed only in prose.
//
//  It renders a REAL `EnvironmentBackgroundView` (same engine, same layers,
//  same weather effects) in a fixed preview frame, and drives the engine
//  through `EnvironmentOverrideStore`, the same store the app's own engine
//  reads. Overrides are cleared when this pane disappears, so closing the
//  studio always returns the app to the real clock and real weather.

#if DEBUG

import SwiftUI

struct EnvironmentStudioView: View {
    @StateObject private var engine = EnvironmentEngine()

    private let store = EnvironmentOverrideStore.standard

    @State private var useLiveTime = true
    @State private var minute: Double = 600
    @State private var useLiveWeather = true
    @State private var forcedKind: WeatherVisualKind = .rain
    @State private var forcedIntensity: Double = 0.65
    @State private var didLoad = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                preview
                controls
                readout
            }
            .padding(20)
        }
        .background(ConsolePalette.background)
        .onAppear(perform: loadExistingOverrides)
        .onDisappear {
            store.clearAll()
            engine.refreshNow()
        }
        .onChange(of: useLiveTime) { _, _ in applyOverrides() }
        .onChange(of: minute) { _, _ in applyOverrides() }
        .onChange(of: useLiveWeather) { _, _ in applyOverrides() }
        .onChange(of: forcedKind) { _, _ in applyOverrides() }
        .onChange(of: forcedIntensity) { _, _ in applyOverrides() }
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
                Text("Renders the real background layers. Force any hour or weather kind, then close the pane to return to live values.")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(ConsolePalette.textSecondary)
            }
            Spacer()
            Button("Reset to live") {
                useLiveTime = true
                useLiveWeather = true
                store.clearAll()
                engine.refreshNow()
            }
            .font(.system(.caption, design: .monospaced))
        }
    }

    // MARK: - Preview

    private var preview: some View {
        ZStack(alignment: .bottomLeading) {
            EnvironmentBackgroundView(engine: engine)
        }
        .frame(height: 360)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(ConsolePalette.border, lineWidth: 1))
        .overlay(alignment: .topLeading) {
            HStack(spacing: 8) {
                Text(clockText)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                Text(useLiveTime ? "LIVE CLOCK" : "FORCED TIME")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.35)))
                Text(engine.state.weatherVisual.kind.displayName.uppercased())
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.35)))
                if !engine.state.weatherVisual.isLive {
                    Text("FORCED WEATHER")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(.orange)
                }
            }
            .foregroundStyle(.white)
            .padding(10)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            panel("TIME OF DAY") {
                Toggle("Use the real clock", isOn: $useLiveTime)
                    .font(.system(.callout, design: .monospaced))
                HStack(spacing: 12) {
                    Slider(value: $minute, in: 0...1439, step: 5)
                        .disabled(useLiveTime)
                    Text(formatted(minute))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(ConsolePalette.textPrimary)
                        .monospacedDigit()
                        .frame(width: 58, alignment: .trailing)
                }
                .opacity(useLiveTime ? 0.45 : 1)
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
                    Text(String(format: "%.0f%%", forcedIntensity * 100))
                        .font(.system(.caption, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(ConsolePalette.textSecondary)
                        .frame(width: 44, alignment: .trailing)
                }
                .opacity(useLiveWeather ? 0.45 : 1)
                Text(liveWeatherProvenance)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(ConsolePalette.textSecondary)
            }
        }
    }

    // MARK: - Readout

    private var readout: some View {
        panel("COMPUTED STATE") {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 160), spacing: 10)],
                alignment: .leading, spacing: 10
            ) {
                metric("Clock", clockText)
                metric("Anchor", anchorText)
                metric("Weather", engine.state.weatherVisual.kind.displayName
                    + (engine.state.weatherVisual.isLive ? " · live" : " · forced"))
                metric("Gradient luminance", String(format: "%.2f", engine.state.gradientLuminance))
                metric("Readability scrim", String(format: "%.2f", engine.state.readabilityScrim))
                metric("Star visibility", String(format: "%.2f", engine.state.starVisibility))
                metric("Atmosphere", String(format: "%.2f", engine.state.atmosphericOpacity))
                metric("Reduced motion", engine.state.reducedMotion ? "on" : "off")
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
        engine.refreshNow()
    }

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

    // MARK: - Formatting

    private var clockText: String { formatted(engine.state.minuteOfDay) }

    private var anchorText: String {
        engine.state.currentAnchorBlend
            .filter { $0.value > 0.01 }
            .sorted { $0.value > $1.value }
            .map { "\($0.key.displayName) \(Int(($0.value * 100).rounded()))%" }
            .joined(separator: " · ")
    }

    private var liveWeatherProvenance: String {
        guard let condition = engine.state.weatherModifier.condition else {
            return "No captured weather snapshot in the last 6 hours — the layer stays clear."
        }
        let captured = engine.state.weatherModifier.capturedAt?
            .formatted(date: .abbreviated, time: .shortened) ?? "unknown time"
        return "Latest capture: \(condition.rawValue) at \(captured)."
    }

    private func formatted(_ minute: Double) -> String {
        let total = Int(minute.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private var presets: [(label: String, minute: Int)] {
        [("Dawn", 345), ("Morning", 480), ("Noon", 720),
         ("Golden", 1080), ("Dusk", 1170), ("Night", 60)]
    }
}

#endif
