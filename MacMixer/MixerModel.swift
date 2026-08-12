// MacMixer v2 — observable bridge between the SwiftUI popover and TapEngine.
// Owns the engine lifecycle and publishes output devices, master volume, and
// the per-app sliders the popover renders.

import SwiftUI
import AppKit
import Combine
import CoreAudio

@MainActor
final class MixerModel: ObservableObject {
    /// One running app with an audio slider.
    struct AppEntry: Identifiable {
        let id: pid_t            // process identifier
        let name: String
        let bundleID: String?
        let icon: NSImage?
        var volume: Double       // percent, 0...200 (100 == unity)
    }

    @Published var running = false
    @Published var startupError: String? = nil

    @Published var outputDevices: [AudioDeviceInfo] = []
    @Published var currentOutputID = AudioObjectID(kAudioObjectUnknown)

    @Published var hasMaster = false
    @Published var masterVolume: Double = 0      // 0...1
    @Published var hasMute = false
    @Published var muted = false

    @Published var apps: [AppEntry] = []
    @Published var showingHidden = false

    @Published private var hiddenKeys: Set<String> = []
    private static let hiddenDefaultsKey = "userHiddenAppKeys"
    private static let didSeedDefaultsKey = "didSeedDefaultHiddenApps"

    /// Utility apps that don't play audio — hidden by default on first run.
    private static let defaultHiddenKeys: Set<String> = [
        "com.apple.finder",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.apple.systempreferences",
        "com.apple.ActivityMonitor",
    ]

    private let engine = TapEngine()
    private var refreshTimer: Timer?

    // Apps we never show a slider for (ourselves).
    private let excludedBundleIDs: Set<String> = [
        Bundle.main.bundleIdentifier ?? "com.macmixer.app"
    ]

    /// Output devices seen on the last poll, for "follow new device".
    private var knownDeviceIDs: Set<AudioObjectID> = []

    init() {
        hiddenKeys = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenDefaultsKey) ?? [])
        if !UserDefaults.standard.bool(forKey: Self.didSeedDefaultsKey) {
            hiddenKeys.formUnion(Self.defaultHiddenKeys)
            UserDefaults.standard.set(true, forKey: Self.didSeedDefaultsKey)
            persistHidden()
        }
    }

    // MARK: Hiding apps

    var visibleApps: [AppEntry] { apps.filter { !hiddenKeys.contains(Self.hideKey(for: $0)) } }
    var hiddenApps:  [AppEntry] { apps.filter {  hiddenKeys.contains(Self.hideKey(for: $0)) } }

    static func hideKey(for entry: AppEntry) -> String { entry.bundleID ?? entry.name }

    func hide(_ entry: AppEntry) {
        hiddenKeys.insert(Self.hideKey(for: entry))
        persistHidden()
        syncTrackedApps()
    }

    func unhide(_ entry: AppEntry) {
        hiddenKeys.remove(Self.hideKey(for: entry))
        persistHidden()
        syncTrackedApps()
    }

    private func persistHidden() {
        UserDefaults.standard.set(Array(hiddenKeys), forKey: Self.hiddenDefaultsKey)
    }

    // MARK: Lifecycle

    func start() {
        attemptEngineStart()
        // Poll even if the engine failed to start (e.g. no output device yet):
        // the timer retries until a device shows up.
        startPolling()
    }

    private func attemptEngineStart() {
        do {
            try engine.start()
            running = true
            startupError = nil
            knownDeviceIDs = Set(engine.outputDevices().map(\.id))
            refreshAll()
        } catch {
            startupError = error.localizedDescription
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        engine.stop()
        running = false
    }

    func refreshAll() {
        refreshDevices()
        refreshMaster()
        refreshApps()
    }

    private func startPolling() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.running { self.refreshAll() } else { self.attemptEngineStart() }
            }
        }
    }

    // MARK: Output devices (+ follow new device)

    func refreshDevices() {
        let devices = engine.outputDevices()
        outputDevices = devices

        let ids = Set(devices.map(\.id))
        let added = ids.subtracting(knownDeviceIDs)
        // Switch to a newly-connected non-display device (e.g. AirPods).
        var followedNewDevice = false
        if let newDevice = devices.first(where: { added.contains($0.id) && !CADevices.isDisplay($0.id) }) {
            engine.setOutputDevice(newDevice.id)
            followedNewDevice = true
        }
        knownDeviceIDs = ids

        // Follow a default-output change made outside the app (Control Center,
        // System Settings) without writing the default back. Skipped on the
        // poll where we just set the default ourselves, in case the HAL hasn't
        // surfaced that write yet.
        let systemDefault = CADevices.defaultOutput()
        if !followedNewDevice, systemDefault != engine.currentOutputID, ids.contains(systemDefault) {
            engine.adoptOutputDevice(systemDefault)
        }

        currentOutputID = engine.currentOutputID
        // If the current output vanished, fall back to the system default.
        if !ids.contains(currentOutputID) {
            let fallback = CADevices.defaultOutput()
            engine.setOutputDevice(fallback)
            currentOutputID = engine.currentOutputID
        }
    }

    func selectOutput(_ deviceID: AudioObjectID) {
        guard engine.setOutputDevice(deviceID) else { return }
        currentOutputID = engine.currentOutputID
        refreshMaster()
    }

    // MARK: Master

    func refreshMaster() {
        hasMaster = engine.hasMasterVolume
        if hasMaster { masterVolume = Double(engine.masterVolume()) }
        hasMute = engine.hasMute
        if hasMute { muted = engine.isMuted() }
    }

    func setMaster(_ value: Double) {
        masterVolume = value
        engine.setMasterVolume(Float(value))
    }

    func toggleMute() {
        muted.toggle()
        engine.setMuted(muted)
    }

    // MARK: Per-app volumes

    func refreshApps() {
        let regular = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
                && !(($0.bundleIdentifier).map(excludedBundleIDs.contains) ?? false)
        }

        let existing = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var updated: [AppEntry] = []
        updated.reserveCapacity(regular.count)
        for app in regular {
            let pid = app.processIdentifier
            if let entry = existing[pid] {
                updated.append(entry)
            } else {
                let bid = app.bundleIdentifier
                updated.append(AppEntry(
                    id: pid,
                    name: app.localizedName ?? bid ?? "App \(pid)",
                    bundleID: bid,
                    icon: app.icon,
                    volume: Self.gainToPercent(engine.gain(forPID: pid))
                ))
            }
        }
        updated.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // Only republish when the set of pids changed (avoids racing ForEach).
        if updated.map(\.id) != apps.map(\.id) {
            apps = updated
        }
        // Re-sync every poll: an app's audio (helper) process can appear after
        // the app itself, and the engine no-ops unless the tap set changed.
        syncTrackedApps()
    }

    /// Tell the engine to tap exactly the apps that have visible sliders.
    private func syncTrackedApps() {
        engine.setTrackedApps(visibleApps.map {
            TapEngine.TrackedApp(pid: $0.id, bundleID: $0.bundleID)
        })
    }

    func setVolume(_ value: Double, for entry: AppEntry) {
        if let idx = apps.firstIndex(where: { $0.id == entry.id }) {
            apps[idx].volume = value
        }
        engine.setGain(Self.percentToGain(value), forPID: entry.id)
    }

    // MARK: Scale
    // 100% == unity (gain 1.0); 0% == mute; up to 200% == 2x boost.
    static let normalPercent: Double = 100
    static let maxPercent: Double = 200

    private static func percentToGain(_ percent: Double) -> Float { Float(percent / 100.0) }
    private static func gainToPercent(_ gain: Float) -> Double { min(maxPercent, Double(gain) * 100.0) }
}
