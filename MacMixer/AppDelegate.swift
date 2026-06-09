// MacMixer v2 — menu bar status item + popover, driving the MixerModel.
// Menu-bar-only (LSUIElement); no dock icon.

import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = MixerModel()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    // MARK: status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "slider.vertical.3",
                                accessibilityDescription: "MacMixer")
            btn.image?.isTemplate = true
            btn.action = #selector(statusItemClicked(_:))
            btn.target = self
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let btn = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.refreshAll()
            popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: context menu

    private func showContextMenu() {
        let menu = NSMenu()

        let login = NSMenuItem(title: "Open at Login",
                               action: #selector(toggleLoginItem),
                               keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)

        let privacy = NSMenuItem(title: "Privacy Settings…",
                                 action: #selector(openPrivacyPrefs),
                                 keyEquivalent: "")
        privacy.target = self
        menu.addItem(privacy)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit MacMixer",
                              action: #selector(NSApp.terminate(_:)),
                              keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        DispatchQueue.main.async { [weak self] in self?.statusItem.menu = nil }
    }

    @objc private func toggleLoginItem() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
    }

    @objc private func openPrivacyPrefs() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: popover

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        // No animation so drag-to-resize tracks the cursor instead of easing.
        popover.animates = false
        popover.contentViewController = NSHostingController(
            rootView: PopupView().environmentObject(model)
        )
    }
}
