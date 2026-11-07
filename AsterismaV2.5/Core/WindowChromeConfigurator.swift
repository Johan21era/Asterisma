//  WindowChromeConfigurator.swift
//  AsterismaV2.5
//
//  Owner-test F4 / fullscreen design directive:
//  The starfield should read as one continuous surface from the window's top
//  edge, while the native toolbar, traffic lights, and green zoom button must
//  remain fully functional. SwiftUI's `.hiddenTitleBar` removed the toolbar in
//  windowed mode, so we keep the standard toolbar and make the titlebar itself
//  transparent/full-size instead.

import AppKit
import SwiftUI

struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }

            // Content paints all the way to the top; the starfield background
            // already ignores the safe area.
            window.styleMask.insert(.fullSizeContentView)
            window.styleMask.insert(.resizable)

            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.backgroundColor = .clear
            window.isOpaque = false

            // Keep the native toolbar and its controls, but remove the
            // baseline separator that otherwise draws a horizontal rule.
            window.toolbarStyle = .unifiedCompact
            window.toolbar?.showsBaselineSeparator = false
            window.toolbar?.isVisible = false

            window.minSize = NSSize(width: 900, height: 640)

            // No control should look pre-focused at launch. Clear the
            // automatic first-responder assignment after the window settles;
            // keyboard focus still works normally once the user starts.
            window.initialFirstResponder = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                window.makeFirstResponder(nil)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}


/// Controls the native toolbar only where it is genuinely needed: the reader.
/// In the library surface the toolbar is hidden, so fullscreen has no gray
/// system bar at the top.
struct WindowToolbarVisibility: NSViewRepresentable {
    let visible: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.toolbar?.isVisible = visible
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.toolbar?.isVisible = visible
        }
    }
}

// MARK: - Arrow-key navigation

enum KeyNavigationCommand {
    case up, down, left, right, returnKey, escape
}

/// Local key monitor for the library surface. It intentionally does nothing
/// while a text field is first responder or a sheet is open, so typing and
/// modal dialogs keep their native behavior.
struct KeyNavigationConfigurator: NSViewRepresentable {
    let isEnabled: Bool
    let onCommand: (KeyNavigationCommand) -> Bool

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
        var onCommand: ((KeyNavigationCommand) -> Bool)?
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

                // Let the search field and any other text editor win.
                if window.firstResponder is NSTextView { return event }

                let disallowed: NSEvent.ModifierFlags = [.command, .control, .option]
                guard event.modifierFlags.intersection(disallowed).isEmpty else { return event }

                let command: KeyNavigationCommand?
                switch event.keyCode {
                case 126: command = .up
                case 125: command = .down
                case 123: command = .left
                case 124: command = .right
                case 36, 76: command = .returnKey
                case 53: command = .escape
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
