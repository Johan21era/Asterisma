//  ComicReaderExperience.swift
//  AsterismaV2.0
//
//  2.5.1 — the quiet, tactile parts of the comic reader: paper palettes,
//  the appearance popover, a direct-manipulation page scrubber, a zoom
//  surface for inspecting artwork, and a local key monitor. Keeping these
//  here leaves ComicReaderScreen focused on reading order and lifecycle.

import AppKit
import SwiftUI

// MARK: - Paper

/// Comics are ink on a surface, so the surface is a first-class setting. The
/// defaults stay dark for image-first reading, but Paper and Snow make the
/// reader feel at home beside the EPUB reader's light themes.
enum ComicPaper: String, CaseIterable, Identifiable, Sendable {
    case ink
    case graphite
    case paper
    case snow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ink: return "Ink"
        case .graphite: return "Graphite"
        case .paper: return "Paper"
        case .snow: return "Snow"
        }
    }

    var isDark: Bool {
        self == .ink || self == .graphite
    }

    var background: Color {
        switch self {
        case .ink: return .black
        case .graphite: return Color(red: 0.055, green: 0.055, blue: 0.065)
        case .paper: return Color(red: 0.949, green: 0.925, blue: 0.875)
        case .snow: return Color(red: 0.975, green: 0.975, blue: 0.982)
        }
    }

    var chromeForeground: Color {
        isDark ? Color.white.opacity(0.94) : Color.black.opacity(0.76)
    }

    var chromeBackground: Color {
        isDark ? Color.black.opacity(0.58) : Color.white.opacity(0.86)
    }

    var chromeStroke: Color {
        isDark ? Color.white.opacity(0.13) : Color.black.opacity(0.08)
    }

    var chromeShadow: Color {
        isDark ? Color.black.opacity(0.55) : Color.black.opacity(0.16)
    }

    var pageShadow: Color {
        isDark ? Color.black.opacity(0.6) : Color.black.opacity(0.18)
    }

    var placeholder: Color {
        isDark ? Color.white.opacity(0.055) : Color.black.opacity(0.045)
    }

    var placeholderStrong: Color {
        isDark ? Color.white.opacity(0.11) : Color.black.opacity(0.09)
    }

    var secondaryText: Color {
        isDark ? Color.white.opacity(0.58) : Color.black.opacity(0.54)
    }
}

// MARK: - Appearance

struct ComicReaderAppearancePanel: View {
    @Binding var paperRaw: String
    @Binding var brightness: Double
    @Binding var autoHideChrome: Bool
    @Binding var mode: ComicReadingMode

    @Environment(\.dismiss) private var dismiss

    private var paper: ComicPaper {
        ComicPaper(rawValue: paperRaw) ?? .graphite
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Comic Appearance")
                        .font(.headline)
                    Text("Keep the artwork quiet and the controls out of the way.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Paper")
                    .font(.callout.weight(.semibold))
                HStack(spacing: 12) {
                    ForEach(ComicPaper.allCases) { option in
                        Button {
                            paperRaw = option.rawValue
                        } label: {
                            Circle()
                                .fill(option.background)
                                .frame(width: 30, height: 30)
                                .overlay(
                                    Circle().strokeBorder(
                                        option == paper
                                            ? Color.accentColor
                                            : Color.primary.opacity(0.16),
                                        lineWidth: option == paper ? 2 : 1
                                    )
                                )
                                .overlay {
                                    if option == paper {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(option.isDark ? .white : .black)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .help(option.displayName)
                        .accessibilityLabel(option.displayName)
                    }
                    Spacer(minLength: 0)
                    Text(paper.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Reading mode")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Picker("Reading mode", selection: $mode) {
                        ForEach(ComicReadingMode.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 184)
                }
                Text(mode == .vertical
                     ? "A continuous strip. Scroll at your own pace."
                     : "One page at a time with native swipe and arrow navigation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Brightness")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text("\(Int(brightness * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: $brightness,
                    in: ReaderComfort.brightnessRange,
                    step: 0.01
                )
                Text("Dims the artwork only. The controls stay at full brightness.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Toggle("Hide controls while reading", isOn: $autoHideChrome)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.callout)

            Divider()

            Text("Arrows turn pages. Space advances, Shift-Space goes back, Home and End jump to the edges. Double-click a page to inspect it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 340)
    }
}

// MARK: - Scrubber

/// A page scrubber that previews its page in place. The coordinator is only
/// written when the drag ends, so a long drag never fires hundreds of page
/// turns or fights the reader's own scroll position.
struct ComicProgressScrubber: View {
    let pageIndex: Int
    let pageCount: Int
    let tint: Color
    let onSeek: (Int) -> Void

    @State private var scrubIndex: Int?
    @State private var hovering = false

    private var displayedIndex: Int {
        min(max(scrubIndex ?? pageIndex, 0), max(pageCount - 1, 0))
    }

    private var progress: CGFloat {
        guard pageCount > 1 else { return 0 }
        return CGFloat(displayedIndex) / CGFloat(pageCount - 1)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let thumbSize: CGFloat = hovering || scrubIndex != nil ? 12 : 10

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(tint.opacity(0.16))
                    .frame(height: 4)

                Capsule()
                    .fill(tint.opacity(0.82))
                    .frame(width: max(4, width * progress), height: 4)

                Circle()
                    .fill(tint)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: tint.opacity(0.24), radius: 3)
                    .offset(x: min(max(0, width * progress - thumbSize / 2), width - thumbSize))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard pageCount > 1 else { return }
                        let fraction = min(max(value.location.x / width, 0), 1)
                        let target = Int((fraction * CGFloat(pageCount - 1)).rounded())
                        scrubIndex = min(max(target, 0), pageCount - 1)
                    }
                    .onEnded { _ in
                        if let scrubIndex {
                            onSeek(scrubIndex)
                        }
                        scrubIndex = nil
                    }
            )
            .onHover { hovering = $0 }
            .overlay(alignment: .top) {
                if let scrubIndex {
                    Text("Page \(scrubIndex + 1)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule())
                        .offset(y: -25)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: scrubIndex != nil)
        }
        .frame(height: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reading position")
        .accessibilityValue(
            pageCount > 0
                ? "Page \(displayedIndex + 1) of \(pageCount)"
                : "No pages"
        )
        .accessibilityAdjustableAction { direction in
            guard pageCount > 1 else { return }
            switch direction {
            case .increment:
                onSeek(min(pageIndex + 1, pageCount - 1))
            case .decrement:
                onSeek(max(pageIndex - 1, 0))
            @unknown default:
                break
            }
        }
    }
}

// MARK: - Zoom

/// A single page lifted out of the reading flow for close inspection. The
/// reading surface stays intact underneath, so closing returns to the same
/// page and the same progress.
struct ComicZoomView: View {
    let page: ComicPage
    let archive: ComicArchive
    let store: ComicPageImageStore
    let paper: ComicPaper
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: NSImage?
    @State private var failed = false
    @State private var scale: CGFloat = 1
    @State private var gestureScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var panBase: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                paper.background.ignoresSafeArea()

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(magnify(in: geometry.size))
                        .simultaneousGesture(pan(in: geometry.size))
                        .onTapGesture(count: 2) {
                            toggleZoom(in: geometry.size)
                        }
                        .animation(
                            reduceMotion ? nil : .easeOut(duration: 0.18),
                            value: scale
                        )
                        .accessibilityLabel(page.name)
                } else if failed {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 36))
                        Text("This page could not be read.")
                            .font(.callout)
                        Button("Close") { onClose() }
                    }
                    .foregroundStyle(paper.chromeForeground)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .tint(paper.chromeForeground)
                }

                VStack {
                    HStack {
                        Spacer()
                        zoomControls(in: geometry.size)
                    }
                    Spacer()
                    Text(page.name)
                        .font(.caption2)
                        .foregroundStyle(paper.secondaryText)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(paper.chromeBackground, in: Capsule())
                        .overlay(
                            Capsule().strokeBorder(paper.chromeStroke, lineWidth: 1)
                        )
                }
                .padding(18)
            }
            .clipped()
        }
        .task(id: page.id) {
            image = await store.loadImage(for: page, in: archive)
            failed = image == nil
        }
    }

    private func zoomControls(in size: CGSize) -> some View {
        HStack(spacing: 5) {
            zoomButton("minus.magnifyingglass", help: "Zoom out") {
                setScale(max(1, scale - 0.5), in: size)
            }
            zoomButton("plus.magnifyingglass", help: "Zoom in") {
                setScale(min(6, scale + 0.5), in: size)
            }
            zoomButton("arrow.counterclockwise", help: "Reset zoom") {
                reset(in: size)
            }
            Divider().frame(height: 16)
            zoomButton("xmark", help: "Close zoom") { onClose() }
        }
        .padding(8)
        .background(paper.chromeBackground, in: Capsule())
        .overlay(Capsule().strokeBorder(paper.chromeStroke, lineWidth: 1))
        .shadow(color: paper.chromeShadow, radius: 12, y: 4)
    }

    private func zoomButton(
        _ systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(paper.chromeForeground)
        .help(help)
    }

    private func magnify(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(6, max(1, gestureScale * value.magnification))
            }
            .onEnded { _ in
                gestureScale = scale
                if scale < 1.01 {
                    reset(in: size)
                } else {
                    clampOffset(in: size)
                }
            }
    }

    private func pan(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(
                    width: panBase.width + value.translation.width,
                    height: panBase.height + value.translation.height
                )
            }
            .onEnded { _ in
                panBase = offset
                clampOffset(in: size)
            }
    }

    private func toggleZoom(in size: CGSize) {
        if scale > 1.01 {
            reset(in: size)
        } else {
            setScale(2.6, in: size)
        }
    }

    private func setScale(_ value: CGFloat, in size: CGSize) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            scale = value
            gestureScale = value
            if value <= 1.01 {
                offset = .zero
                panBase = .zero
            }
        }
        clampOffset(in: size)
    }

    private func reset(in size: CGSize) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            scale = 1
            gestureScale = 1
            offset = .zero
            panBase = .zero
        }
        _ = size
    }

    private func clampOffset(in size: CGSize) {
        let maxX = max(0, size.width * (scale - 1) / 2)
        let maxY = max(0, size.height * (scale - 1) / 2)
        offset = CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
        panBase = offset
    }
}

// MARK: - Keyboard

enum ComicKeyCommand: Sendable {
    case left
    case right
    case up
    case down
    case pageUp
    case pageDown
    case first
    case last
    case space
    case shiftSpace
    case escape
    case toggleFullScreen
    case toggleChrome
}

/// A small local monitor so the reader owns its keys even after a button or
/// slider takes focus. Text editors and attached sheets win automatically.
struct ComicKeyboardMonitor: NSViewRepresentable {
    let isEnabled: Bool
    let onCommand: (ComicKeyCommand) -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onCommand = onCommand
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onCommand = onCommand
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var view: NSView?
        var isEnabled = true
        var onCommand: ((ComicKeyCommand) -> Bool)?
        private var monitor: Any?

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      self.isEnabled,
                      let window = self.view?.window,
                      window.isKeyWindow,
                      window.attachedSheet == nil
                else { return event }

                if window.firstResponder is NSTextView { return event }

                let disallowed: NSEvent.ModifierFlags = [.command, .control, .option]
                guard event.modifierFlags.intersection(disallowed).isEmpty else { return event }

                let shifted = event.modifierFlags.contains(.shift)
                let command: ComicKeyCommand?
                switch event.keyCode {
                case 123: command = .left
                case 124: command = .right
                case 125: command = .down
                case 126: command = .up
                case 49: command = shifted ? .shiftSpace : .space
                case 116: command = .pageUp
                case 121: command = .pageDown
                case 115: command = .first
                case 119: command = .last
                case 53: command = .escape
                case 3: command = .toggleFullScreen
                case 36, 76: command = .toggleChrome
                default: command = nil
                }

                guard let command, self.onCommand?(command) == true else { return event }
                return nil
            }
        }

        func remove() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit { remove() }
    }
}
