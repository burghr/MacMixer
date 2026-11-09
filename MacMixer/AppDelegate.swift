// MacMixer v2 — menu bar status item + popover, driving the MixerModel.
// Menu-bar-only (LSUIElement); no dock icon.

import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = MixerModel()
    private let updates = UpdateController()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
        model.start()
        updates.start()
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

        if let release = updates.available {
            let install = NSMenuItem(title: "Install MacMixer \(release.version)",
                                     action: #selector(installUpdate),
                                     keyEquivalent: "")
            install.target = self
            menu.addItem(install)
        }

        let check = NSMenuItem(title: "Check for Updates…",
                               action: #selector(checkForUpdates),
                               keyEquivalent: "")
        check.target = self
        menu.addItem(check)

        let auto = NSMenuItem(title: "Install Updates Automatically",
                              action: #selector(toggleAutoInstall),
                              keyEquivalent: "")
        auto.target = self
        auto.state = updates.autoInstall ? .on : .off
        menu.addItem(auto)

        let version = NSMenuItem(title: "Version \(updates.currentVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)

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

    @objc private func installUpdate() {
        Task { await updates.install(); showUpdateFailureIfAny() }
    }

    @objc private func toggleAutoInstall() {
        updates.autoInstall.toggle()
    }

    /// A manual check always shows the result in an alert.
    @objc private func checkForUpdates() {
        Task {
            await updates.check(manual: true)
            let alert = NSAlert()
            switch updates.state {
            case .available(let version):
                alert.messageText = "MacMixer \(version) is available"
                alert.informativeText = "You have version \(updates.currentVersion)."
                alert.addButton(withTitle: "Install and Restart")
                alert.addButton(withTitle: "Release Notes")
                alert.addButton(withTitle: "Later")
                NSApp.activate(ignoringOtherApps: true)
                switch alert.runModal() {
                case .alertFirstButtonReturn: installUpdate()
                case .alertSecondButtonReturn: updates.openReleasePage()
                default: break
                }
                return
            case .upToDate:
                alert.messageText = "MacMixer is up to date"
                alert.informativeText = "Version \(updates.currentVersion) is the latest version."
            case .failed(let text):
                alert.messageText = "The update check failed"
                alert.informativeText = text
            default:
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func showUpdateFailureIfAny() {
        guard case .failed(let text) = updates.state else { return }
        let alert = NSAlert()
        alert.messageText = "MacMixer could not install the update"
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Release Page")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { updates.openReleasePage() }
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
            rootView: PopupView().environmentObject(model).environmentObject(updates)
        )
    }
}
