// MacMixer v2 — CoreAudio helpers
// Thin wrappers around the AudioObject property API plus the macOS 14.2+
// process-object and tap helpers the engine relies on.

import CoreAudio
import Foundation

enum MixerConstants {
    /// Fixed UID of the private aggregate MacMixer builds. Our own process can
    /// still see private aggregates, so we filter this out of device lists.
    static let aggregateUID = "com.macmixer.aggregate"
}

enum CA {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    static let mainElement = kAudioObjectPropertyElementMain

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = mainElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
        var a = addr
        return AudioObjectHasProperty(obj, &a)
    }

    static func isSettable(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
        var a = addr
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(obj, &a, &settable) == noErr && settable.boolValue
    }

    /// Read a fixed-size scalar property, returning `fallback` on failure.
    /// `T` must be a trivial (POD) CoreAudio type.
    static func scalar<T>(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ fallback: T) -> T {
        var a = addr
        var value = fallback
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0)
        }
        return status == noErr ? value : fallback
    }

    @discardableResult
    static func setScalar<T>(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ value: T) -> Bool {
        var a = addr
        var v = value
        return withUnsafePointer(to: &v) {
            AudioObjectSetPropertyData(obj, &a, 0, nil, UInt32(MemoryLayout<T>.size), $0) == noErr
        }
    }

    /// Read a variable-size property into an array of trivially-copyable T.
    static func array<T>(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ type: T.Type) -> [T] {
        var a = addr
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        var sz = size
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, raw) == noErr else { return [] }
        let typed = raw.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: count))
    }

    static func cfString(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> String? {
        var a = addr
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0)
        }
        guard status == noErr, let s = value else { return nil }
        return s as String
    }
}

// MARK: - Devices

struct AudioDeviceInfo: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transportType: UInt32

    /// SF Symbol that reflects the kind of device (AirPods / headphones / speaker).
    var symbolName: String {
        let n = name.lowercased()
        if n.contains("airpods max")  { return "airpodsmax" }
        if n.contains("airpods pro")  { return "airpodspro" }
        if n.contains("airpods")      { return "airpods" }
        if n.contains("headphone") || n.contains("headset")
            || n.contains("earbud") || n.contains("earphone") { return "headphones" }
        switch transportType {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "headphones"          // most personal BT audio is headphones/earbuds
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "tv"
        default:
            return "hifispeaker.fill"    // built-in / USB / unknown -> speaker
        }
    }
}

enum CADevices {
    static func defaultOutput() -> AudioObjectID {
        CA.scalar(CA.systemObject,
                  CA.address(kAudioHardwarePropertyDefaultOutputDevice),
                  AudioObjectID(kAudioObjectUnknown))
    }

    @discardableResult
    static func setDefaultOutput(_ id: AudioObjectID) -> Bool {
        CA.setScalar(CA.systemObject, CA.address(kAudioHardwarePropertyDefaultOutputDevice), id)
    }

    static func allDeviceIDs() -> [AudioObjectID] {
        CA.array(CA.systemObject, CA.address(kAudioHardwarePropertyDevices), AudioObjectID.self)
    }

    static func uid(_ id: AudioObjectID) -> String? {
        CA.cfString(id, CA.address(kAudioDevicePropertyDeviceUID))
    }

    static func name(_ id: AudioObjectID) -> String? {
        CA.cfString(id, CA.address(kAudioObjectPropertyName))
            ?? CA.cfString(id, CA.address(kAudioDevicePropertyDeviceNameCFString))
    }

    /// A device can be selected as output if it has at least one output stream.
    static func hasOutputStreams(_ id: AudioObjectID) -> Bool {
        let addr = CA.address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
        return !CA.array(id, addr, AudioObjectID.self).isEmpty
    }

    static func transportType(_ id: AudioObjectID) -> UInt32 {
        CA.scalar(id, CA.address(kAudioDevicePropertyTransportType), UInt32(0))
    }

    /// HDMI / DisplayPort outputs are monitors — excluded from "follow new device".
    static func isDisplay(_ id: AudioObjectID) -> Bool {
        let t = transportType(id)
        return t == kAudioDeviceTransportTypeHDMI || t == kAudioDeviceTransportTypeDisplayPort
    }

    static func outputDevices() -> [AudioDeviceInfo] {
        allDeviceIDs().compactMap { id in
            guard hasOutputStreams(id), let uid = uid(id),
                  uid != MixerConstants.aggregateUID else { return nil }
            return AudioDeviceInfo(id: id, uid: uid, name: name(id) ?? uid,
                                   transportType: transportType(id))
        }
    }
}

// MARK: - Device volume / mute (used for "master")

/// Wraps a device's hardware output volume + mute. Some devices expose volume on
/// the main element, others only per-channel; this picks whatever is settable.
struct DeviceVolume {
    let deviceID: AudioObjectID
    private let volumeElements: [AudioObjectPropertyElement]
    private let muteElement: AudioObjectPropertyElement?

    init(_ deviceID: AudioObjectID) {
        self.deviceID = deviceID
        let scope = kAudioObjectPropertyScopeOutput

        // Prefer the main element; fall back to channels 1/2.
        var volElems: [AudioObjectPropertyElement] = []
        let mainVol = CA.address(kAudioDevicePropertyVolumeScalar, scope, CA.mainElement)
        if CA.has(deviceID, mainVol) {
            volElems = [CA.mainElement]
        } else {
            for ch in [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)] {
                if CA.has(deviceID, CA.address(kAudioDevicePropertyVolumeScalar, scope, ch)) {
                    volElems.append(ch)
                }
            }
        }
        self.volumeElements = volElems

        let mainMute = CA.address(kAudioDevicePropertyMute, scope, CA.mainElement)
        self.muteElement = CA.has(deviceID, mainMute) ? CA.mainElement : nil
    }

    var hasVolume: Bool { !volumeElements.isEmpty }
    var hasMute: Bool { muteElement != nil }

    func volume() -> Float {
        guard let first = volumeElements.first else { return 0 }
        let scope = kAudioObjectPropertyScopeOutput
        return CA.scalar(deviceID, CA.address(kAudioDevicePropertyVolumeScalar, scope, first), Float(0))
    }

    func setVolume(_ value: Float) {
        let scope = kAudioObjectPropertyScopeOutput
        let v = max(0, min(1, value))
        for el in volumeElements {
            CA.setScalar(deviceID, CA.address(kAudioDevicePropertyVolumeScalar, scope, el), v)
        }
    }

    func isMuted() -> Bool {
        guard let el = muteElement else { return false }
        return CA.scalar(deviceID, CA.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, el), UInt32(0)) != 0
    }

    func setMuted(_ muted: Bool) {
        guard let el = muteElement else { return }
        CA.setScalar(deviceID, CA.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, el), UInt32(muted ? 1 : 0))
    }
}

// MARK: - Taps (macOS 14.2+)

enum CATap {
    static func uid(_ tapID: AudioObjectID) -> String? {
        CA.cfString(tapID, CA.address(kAudioTapPropertyUID))
    }
}
