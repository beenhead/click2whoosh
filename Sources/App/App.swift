// click2whoosh menu bar app.

import AppKit
import Combine
import SwiftUI

@main
struct Click2WhooshApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            ContentView(manager: appDelegate.manager)
        } label: {
            MenuIcon(manager: appDelegate.manager)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuIcon: View {
    @ObservedObject var manager: ClickManager
    var body: some View {
        if !manager.accessibilityOK {
            Image(systemName: "exclamationmark.triangle")
        } else {
            Image(systemName: manager.pucks.contains(where: \.ready) ? "bicycle.circle.fill" : "bicycle.circle")
        }
    }
}

/// Also shows the panel as a regular window: on launch, and whenever the app is opened
/// again from Finder/Spotlight. The menu bar icon can end up hidden behind the notch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let manager = ClickManager()
    private var window: NSWindow?
    private var bannerWatch: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["CLICK2WHOOSH_SIMULATE"] == "1" { manager.startSimulation() }
        if ProcessInfo.processInfo.environment["CLICK2WHOOSH_NOWINDOW"] != "1" { showWindow() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func showWindow() {
        if window == nil {
            // The SwiftUI view must NOT drive the window size: letting it do so caused an
            // AppKit "update constraints" loop crash on rapid button presses. Instead the
            // window gets a fixed size, refitted only when the permission banner toggles.
            let host = NSHostingView(rootView: ContentView(manager: manager))
            host.sizingOptions = []
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.contentView = host
            w.title = "click2whoosh"
            w.isReleasedWhenClosed = false
            w.center()
            window = w
            bannerWatch = manager.$accessibilityOK.removeDuplicates().dropFirst().sink { [weak self] _ in
                DispatchQueue.main.async { self?.refit() }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func refit() {
        guard let w = window, let v = w.contentView else { return }
        var frame = w.frame
        let newSize = w.frameRect(forContentRect: NSRect(origin: .zero, size: v.fittingSize)).size
        frame.origin.y += frame.height - newSize.height  // keep the top edge in place
        frame.size = newSize
        w.setFrame(frame, display: true, animate: false)
    }
}

struct ContentView: View {
    @ObservedObject var manager: ClickManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("click2whoosh").font(.headline)
                Spacer()
                Toggle("Enabled", isOn: $manager.enabled).toggleStyle(.switch).controlSize(.small).labelsHidden()
            }

            if !manager.accessibilityOK { accessibilityBanner }

            // Fixed set of rows (always both pucks) so the panel never changes height on its own.
            section("Controllers") {
                puckRow("Right puck", manager.pucks.first { !$0.isLeft })
                puckRow("Left puck", manager.pucks.first { $0.isLeft })
                Text(manager.pucks.contains(where: \.ready)
                     ? "Left puck only sends presses if unlocked in Zwift within ~24 h."
                     : manager.bluetoothStatus)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            section("Buttons") {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    ForEach(clickButtons) { b in
                        GridRow {
                            Text(b.label)
                                .frame(width: 70, alignment: .leading)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(manager.pressed.contains(b.id) ? Color.accentColor.opacity(0.35) : .clear,
                                            in: RoundedRectangle(cornerRadius: 4))
                            Text(b.leftPuck ? "left" : "right").font(.caption).foregroundStyle(.secondary)
                            Picker("", selection: binding(for: b.id)) {
                                ForEach(keyOptions) { Text($0.name).tag($0.name) }
                            }.labelsHidden().frame(width: 100)
                        }
                    }
                }
                Text("MyWhoosh: K = harder gear, I = easier gear").font(.caption).foregroundStyle(.secondary)
            }

            Toggle("Only send keys when MyWhoosh is in front", isOn: $manager.onlyWhenMyWhooshFront)
                .font(.callout)

            section("Last event") {
                Text(manager.lastEvent).font(.callout.monospaced())
                    .lineLimit(2, reservesSpace: true)  // fixed height: no resize on every press
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            Divider()
            HStack {
                Button("Reset mapping") { manager.resetMapping() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }.controlSize(.small)
        }
        .padding(14)
        .frame(width: 330)
    }

    private var accessibilityBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Keystrokes are blocked", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.bold()).foregroundStyle(.orange)
            Text("Allow click2whoosh in System Settings › Privacy & Security › Accessibility.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Request access") { manager.requestAccessibility() }
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }.controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption2.bold()).foregroundStyle(.secondary)
            content()
        }
    }

    private func binding(for id: String) -> Binding<String> {
        Binding(get: { manager.mapping[id] ?? "None" }, set: { manager.mapping[id] = $0 })
    }

    private func puckRow(_ title: String, _ puck: PuckState?) -> some View {
        HStack(spacing: 8) {
            Circle().fill(puck.map(color) ?? .gray).frame(width: 8, height: 8)
            Text(title)
            Spacer()
            Text(puck.map(status) ?? "not found").foregroundStyle(.secondary)
            Text(puck?.battery.map { "\($0)%" } ?? "").foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }.font(.callout)
    }

    private func color(_ p: PuckState) -> Color { p.ready ? .green : p.connected ? .yellow : .gray }
    private func status(_ p: PuckState) -> String { p.ready ? "ready" : p.connected ? "connecting" : "asleep" }
    private func batteryIcon(_ b: Int) -> String {
        b > 75 ? "battery.100" : b > 50 ? "battery.75" : b > 25 ? "battery.50" : "battery.25"
    }
}
