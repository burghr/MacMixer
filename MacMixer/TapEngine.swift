// MacMixer v2 — audio engine built on CoreAudio process taps (macOS 14.2+).
//
// For each app we control we create a private process tap with
// `CATapMutedWhenTapped`: the app's audio is muted at the source while we read
// it, and we replay it ourselves with per-app gain applied. All taps plus the
// chosen output device are combined into one private aggregate device clocked
// by the output, so a single IO callback mixes every tap into the output with
// no ring buffer and no sample-rate drift. If our callback ever stops, the
// "when tapped" mute releases and apps play normally again.
//
// Unlike v1 (a virtual HAL driver doing input-stream loopback), a process tap
// is not classified as microphone input, so there's no orange mic indicator.

import CoreAudio
import Foundation

/// Reliable, Console-visible logging for the engine during bring-up.
private enum log {
    static func info(_ m: String)  { NSLog("[MacMixer] %@", m) }
    static func error(_ m: String) { NSLog("[MacMixer] ERROR %@", m) }
}

final class TapEngine {

    // MARK: Realtime-shared state
    // The IO callback runs on a realtime thread. It only ever reads these raw
    // buffers (no Swift allocation / ARC), which the main thread updates.

    private static let maxTaps = 64
    private let gains = UnsafeMutablePointer<Float>.allocate(capacity: maxTaps)
    private let tapCount = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    /// Number of leading input buffers that belong to the output sub-device
    /// (not taps); taps follow these in the aggregate's input buffer list.
    private let inputOffset = UnsafeMutablePointer<Int32>.allocate(capacity: 1)

    // MARK: Main-thread state

    private(set) var currentOutputID = AudioObjectID(kAudioObjectUnknown)
    private var deviceVolume: DeviceVolume?

    /// An app the UI wants to control: its main pid + bundle id.
    struct TrackedApp { let pid: pid_t; let bundleID: String? }

    /// A CoreAudio process object to tap, and the app pid that owns it.
    private struct TapTarget { let procObj: AudioObjectID; let owner: pid_t }

    /// app pid -> linear gain (1.0 == unity). Persists across tap rebuilds.
    private var pidGain: [pid_t: Float] = [:]
    /// Apps the UI currently wants controlled (visible apps).
    private var trackedApps: [TrackedApp] = []
    /// Owning app pid for each tap slot; index == slot in `gains`.
    private var slotOwner: [pid_t] = []
    /// Process objects backing the current taps (for change detection).
    private var tappedProcObjs: [AudioObjectID] = []
    private var currentTargets: [TapTarget] = []
    private var tapIDs: [AudioObjectID] = []

    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var running = false

    init() {
        gains.initialize(repeating: 1.0, count: Self.maxTaps)
        tapCount.pointee = 0
        inputOffset.pointee = 0
    }

    deinit {
        teardownAggregate()
        gains.deallocate()
        tapCount.deallocate()
        inputOffset.deallocate()
    }

    // MARK: Lifecycle

    func start() throws {
        currentOutputID = CADevices.defaultOutput()
        guard currentOutputID != AudioObjectID(kAudioObjectUnknown) else {
            throw EngineError.noOutputDevice
        }
        deviceVolume = DeviceVolume(currentOutputID)
        running = true
        // Taps get built on the first setTrackedApps() call from the model.
        log.info("TapEngine started; output=\(self.currentOutputID)")
    }

    func stop() {
        running = false
        teardownAggregate()
    }

    // MARK: Output device

    func outputDevices() -> [AudioDeviceInfo] { CADevices.outputDevices() }

    /// Switch the system default output and rebuild our aggregate around it.
    @discardableResult
    func setOutputDevice(_ id: AudioObjectID) -> Bool {
        guard id != AudioObjectID(kAudioObjectUnknown) else { return false }
        CADevices.setDefaultOutput(id)
        currentOutputID = id
        deviceVolume = DeviceVolume(id)
        if running { rebuildAggregate(targets: currentTargets) }
        return true
    }

    // MARK: Master (output device hardware volume)

    var hasMasterVolume: Bool { deviceVolume?.hasVolume ?? false }
    var hasMute: Bool { deviceVolume?.hasMute ?? false }
    func masterVolume() -> Float { deviceVolume?.volume() ?? 0 }
    func setMasterVolume(_ v: Float) { deviceVolume?.setVolume(v) }
    func isMuted() -> Bool { deviceVolume?.isMuted() ?? false }
    func setMuted(_ m: Bool) { deviceVolume?.setMuted(m) }

    // MARK: Per-app gain

    func gain(forPID pid: pid_t) -> Float { pidGain[pid] ?? 1.0 }

    func setGain(_ gain: Float, forPID pid: pid_t) {
        pidGain[pid] = gain
        // An app can own several taps (e.g. Chromium helpers); set them all.
        for (slot, owner) in slotOwner.enumerated() where owner == pid && slot < Self.maxTaps {
            gains[slot] = gain
        }
    }

    /// Tell the engine which apps to control. Maps every CoreAudio process
    /// object to an owning app and rebuilds only when the set of process
    /// objects we'd tap actually changes.
    func setTrackedApps(_ apps: [TrackedApp]) {
        guard running else { return }
        trackedApps = apps
        let targets = computeTapTargets()
        if Set(targets.map(\.procObj)) == Set(tappedProcObjs) { return }
        currentTargets = targets
        tappedProcObjs = targets.map(\.procObj)
        rebuildAggregate(targets: targets)
    }

    /// Enumerate every process object and match each to a tracked app by exact
    /// pid, exact bundle id, or bundle-id prefix (so e.g. Edge/Chrome/Teams
    /// helper processes are attributed to their parent app).
    private func computeTapTargets() -> [TapTarget] {
        let procs = CA.array(CA.systemObject,
                             CA.address(kAudioHardwarePropertyProcessObjectList),
                             AudioObjectID.self)
        var targets: [TapTarget] = []
        for p in procs {
            let pid = CA.scalar(p, CA.address(kAudioProcessPropertyPID), pid_t(-1))
            let bid = CA.cfString(p, CA.address(kAudioProcessPropertyBundleID))
            guard let owner = ownerPID(processPID: pid, bundleID: bid) else { continue }
            targets.append(TapTarget(procObj: p, owner: owner))
        }
        return targets
    }

    private func ownerPID(processPID pid: pid_t, bundleID: String?) -> pid_t? {
        if let app = trackedApps.first(where: { $0.pid == pid }) { return app.pid }
        guard let bid = bundleID, !bid.isEmpty else { return nil }
        if let app = trackedApps.first(where: { $0.bundleID == bid }) { return app.pid }
        // Longest (most specific) prefix wins: "com.x.helper" -> "com.x".
        let prefixMatch = trackedApps
            .filter { ($0.bundleID.map { bid.hasPrefix($0 + ".") }) ?? false }
            .max(by: { ($0.bundleID?.count ?? 0) < ($1.bundleID?.count ?? 0) })
        return prefixMatch?.pid
    }

    // MARK: Aggregate + tap construction

    private func rebuildAggregate(targets: [TapTarget]) {
        teardownAggregate()
        guard running,
              currentOutputID != AudioObjectID(kAudioObjectUnknown),
              let outUID = CADevices.uid(currentOutputID) else { return }

        // 1. Create one private muted-when-tapped tap per process object.
        var newTapIDs: [AudioObjectID] = []
        var tapUIDs: [String] = []
        var owners: [pid_t] = []
        for target in targets {
            let slot = newTapIDs.count
            if slot >= Self.maxTaps { break }
            let desc = CATapDescription()
            desc.name = "MacMixer-\(target.owner)-\(target.procObj)"
            desc.isPrivate = true
            desc.muteBehavior = .mutedWhenTapped
            desc.isMono = false
            desc.isMixdown = true        // stereo mixdown -> predictable 2ch format
            desc.isExclusive = false     // tap (include) the listed process
            // `processes` is NS_REFINED_FOR_SWIFT; set via KVC to avoid the
            // refined name and pass the process AudioObjectID directly.
            desc.setValue([NSNumber(value: target.procObj)], forKey: "processes")

            var tapID = AudioObjectID(kAudioObjectUnknown)
            let status = AudioHardwareCreateProcessTap(desc, &tapID)
            guard status == noErr, tapID != AudioObjectID(kAudioObjectUnknown),
                  let uid = CATap.uid(tapID) else {
                log.error("CreateProcessTap failed for obj \(target.procObj): \(status)")
                continue
            }
            newTapIDs.append(tapID)
            tapUIDs.append(uid)
            owners.append(target.owner)
            gains[slot] = pidGain[target.owner] ?? 1.0
        }

        tapIDs = newTapIDs
        slotOwner = owners
        tapCount.pointee = Int32(newTapIDs.count)

        guard !newTapIDs.isEmpty else {
            // Nothing to tap right now; leave audio playing natively.
            log.info("No tappable apps; aggregate not created")
            return
        }

        // 2. Build the private aggregate: output device (clock master) + taps.
        let aggUID = MixerConstants.aggregateUID
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MacMixer",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: tapUIDs.map {
                [kAudioSubTapUIDKey: $0, kAudioSubTapDriftCompensationKey: true]
            },
        ]

        var aggID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggID)
        guard status == noErr, aggID != AudioObjectID(kAudioObjectUnknown) else {
            log.error("CreateAggregateDevice failed: \(status)")
            teardownTaps()
            return
        }
        aggregateID = aggID

        // 3. Work out how many leading input buffers belong to the output
        // sub-device so the render callback can index the tap buffers.
        let inAddr = CA.address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        let inputBufferCount = bufferCount(aggID, inAddr)
        inputOffset.pointee = Int32(max(0, inputBufferCount - newTapIDs.count))

        // 4. Install the render callback and start IO.
        let block = makeIOBlock()
        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil, block)
        guard createStatus == noErr, let procID else {
            log.error("CreateIOProcIDWithBlock failed: \(createStatus)")
            teardownAggregate()
            return
        }
        ioProcID = procID
        let startStatus = AudioDeviceStart(aggID, procID)
        if startStatus != noErr {
            log.error("AudioDeviceStart failed: \(startStatus)")
            teardownAggregate()
            return
        }
        log.info("aggregate running with \(newTapIDs.count) tap(s)")
    }

    private func teardownAggregate() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let proc = ioProcID {
                AudioDeviceStop(aggregateID, proc)
                AudioDeviceDestroyIOProcID(aggregateID, proc)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        teardownTaps()
        tapCount.pointee = 0
    }

    private func teardownTaps() {
        for tap in tapIDs { AudioHardwareDestroyProcessTap(tap) }
        tapIDs = []
    }

    // MARK: Render callback

    private func makeIOBlock() -> AudioDeviceIOBlock {
        // Capture raw pointers by value so the realtime thread never touches
        // Swift reference counting.
        let gains = self.gains
        let tapCountP = self.tapCount
        let offsetP = self.inputOffset

        return { _, inInputData, _, outOutputData, _ in
            let outBL = UnsafeMutableAudioBufferListPointer(outOutputData)
            guard outBL.count > 0 else { return }

            // Zero all output buffers first.
            for ob in outBL {
                if let d = ob.mData { memset(d, 0, Int(ob.mDataByteSize)) }
            }

            let inBL = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            let count = Int(tapCountP.pointee)
            let offset = Int(offsetP.pointee)
            guard count > 0 else { return }

            // Mix into the first (main) interleaved output buffer.
            let out = outBL[0]
            guard let outRaw = out.mData else { return }
            let outFloats = outRaw.assumingMemoryBound(to: Float.self)
            let outSampleCount = Int(out.mDataByteSize) / MemoryLayout<Float>.size

            for t in 0..<count {
                let inIndex = offset + t
                guard inIndex < inBL.count else { break }
                let g = gains[t]
                if g == 0 { continue }
                let ib = inBL[inIndex]
                guard let inRaw = ib.mData else { continue }
                let inFloats = inRaw.assumingMemoryBound(to: Float.self)
                let n = min(outSampleCount, Int(ib.mDataByteSize) / MemoryLayout<Float>.size)
                if g == 1.0 {
                    for s in 0..<n { outFloats[s] += inFloats[s] }
                } else {
                    for s in 0..<n { outFloats[s] += inFloats[s] * g }
                }
            }
        }
    }

    // MARK: Diagnostics

    private func bufferCount(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Int {
        var a = addr
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let abl = raw.assumingMemoryBound(to: AudioBufferList.self)
        return Int(abl.pointee.mNumberBuffers)
    }

    enum EngineError: LocalizedError {
        case noOutputDevice
        var errorDescription: String? {
            switch self {
            case .noOutputDevice: return "No audio output device is available."
            }
        }
    }
}
