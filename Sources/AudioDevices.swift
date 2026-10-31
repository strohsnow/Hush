import CoreAudio
import Foundation

/// Snapshot of an output device's properties.
struct OutputInfo {
    let name: String
    let uid: String
    let modelUID: String?
    let transport: UInt32?
    let dataSource: UInt32?
    let jackConnected: UInt32?

    /// Stable key for remembering a device. The model UID doesn't change when the DAC
    /// is plugged into a different port, unlike the device UID which may include the location.
    var key: String {
        if let model = modelUID, !model.isEmpty { return model }
        return uid
    }

    /// Wired external DACs that can be selected in the Outputs menu.
    /// Bluetooth is left out: a silent stream would keep the radio link busy and drain the headphones.
    var isExternalWired: Bool {
        transport == kAudioDeviceTransportTypeUSB
            || transport == kAudioDeviceTransportTypeThunderbolt
            || transport == kAudioDeviceTransportTypeFireWire
    }

    /// Whether audio is currently routed to the 3.5 mm headphone jack.
    /// Intel: a single built-in device whose data source switches between 'ispk' and 'hdpn'.
    /// Apple Silicon: a separate "External Headphones" device (UID BuiltInHeadphoneOutputDevice)
    /// that exposes JackIsConnected.
    var isHeadphoneJack: Bool {
        guard transport == kAudioDeviceTransportTypeBuiltIn else { return false }
        if dataSource == AudioDevices.headphones { return true }
        if dataSource == AudioDevices.speakers { return false }
        if let jack = jackConnected { return jack != 0 }
        return uid.localizedCaseInsensitiveContains("headphone")
    }
}

enum AudioDevices {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let headphones: UInt32 = 0x6864_706E  // 'hdpn'
    static let speakers: UInt32 = 0x6973_706B    // 'ispk'

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func uint32(_ object: AudioObjectID,
                       _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var addr = address(selector, scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let string = value else { return nil }
        return string.takeRetainedValue() as String
    }

    static func objectList(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static var defaultOutput: AudioDeviceID? {
        guard let id = uint32(system, kAudioHardwarePropertyDefaultOutputDevice),
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    static var allDevices: [AudioDeviceID] { objectList(kAudioHardwarePropertyDevices) }

    static func hasOutput(_ device: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr && size > 0
    }

    /// Whether any process other than Hush is currently playing audio.
    /// Needs macOS 14 (CoreAudio process objects); on older systems always false.
    static var othersPlaying: Bool {
        guard #available(macOS 14.0, *) else { return false }
        let ownPID = getpid()
        return objectList(kAudioHardwarePropertyProcessObjectList).contains { process in
            guard uint32(process, kAudioProcessPropertyIsRunningOutput) == 1,
                  let pid = uint32(process, kAudioProcessPropertyPID) else { return false }
            return pid_t(bitPattern: pid) != ownPID
        }
    }

    static func info(_ device: AudioDeviceID) -> OutputInfo {
        OutputInfo(
            name: string(device, kAudioObjectPropertyName) ?? "Device \(device)",
            uid: string(device, kAudioDevicePropertyDeviceUID) ?? "",
            modelUID: string(device, kAudioDevicePropertyModelUID),
            transport: uint32(device, kAudioDevicePropertyTransportType),
            dataSource: uint32(device, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput),
            jackConnected: uint32(device, kAudioDevicePropertyJackIsConnected, scope: kAudioObjectPropertyScopeOutput)
        )
    }
}

/// Watches the default output, the device list, jack connection and data source changes.
final class AudioDeviceWatcher {
    private let onChange: () -> Void
    private var watched = Set<AudioDeviceID>()
    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.handleChange()
    }

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func start() {
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var addr = AudioDevices.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioDevices.system, &addr, .main, listener)
        }
        watchNewDevices()
    }

    private func handleChange() {
        watchNewDevices()
        onChange()
    }

    /// Devices that don't support a property simply reject the listener.
    private func watchNewDevices() {
        let current = Set(AudioDevices.allDevices)
        watched.formIntersection(current)
        for device in current.subtracting(watched) {
            watched.insert(device)
            for selector in [kAudioDevicePropertyDataSource, kAudioDevicePropertyJackIsConnected] {
                var addr = AudioDevices.address(selector, kAudioObjectPropertyScopeOutput)
                AudioObjectAddPropertyListenerBlock(device, &addr, .main, listener)
            }
        }
    }
}
