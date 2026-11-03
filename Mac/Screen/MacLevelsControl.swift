import AudioToolbox
import CoreAudio
import CoreGraphics
import Foundation

/// The Mac's output volume and mute, on the default output device, and a display's brightness. macOS exposes
/// brightness only through its private DisplayServices framework, which covers the built-in display and Apple
/// displays; other displays report none.
enum MacLevelsControl {
    static func levels(display: CGDirectDisplayID) -> MacLevels {
        MacLevels(volume: OutputVolume.volume, muted: OutputVolume.muted, brightness: Brightness.level(display))
    }

    /// Sets what's given, then answers with the levels as they are.
    static func apply(_ change: MacLevelsParams) throws -> MacLevels {
        let display = change.displayId.map { CGDirectDisplayID($0) } ?? CGMainDisplayID()
        if let volume = change.volume { try OutputVolume.set(volume) }
        if let muted = change.muted { try OutputVolume.setMuted(muted) }
        if let brightness = change.brightness { try Brightness.set(brightness, display: display) }
        return levels(display: display)
    }
}

private enum OutputVolume {
    static var device: AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    static var volume: Double? {
        read(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, as: Float32.self).map(Double.init)
    }

    static var muted: Bool? {
        read(kAudioDevicePropertyMute, as: UInt32.self).map { $0 != 0 }
    }

    static func set(_ volume: Double) throws {
        try write(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, Float32(min(max(volume, 0), 1)),
                  missing: "This sound output's volume can't be changed.")
    }

    static func setMuted(_ muted: Bool) throws {
        try write(kAudioDevicePropertyMute, UInt32(muted ? 1 : 0), missing: "This sound output can't be muted.")
    }

    private static func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<T: Numeric & BitwiseCopyable>(_ selector: AudioObjectPropertySelector, as type: T.Type) -> T? {
        guard let device else { return nil }
        var address = property(selector)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func write<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector, _ value: T, missing: String) throws {
        guard let device else { throw WireError(code: "unsupported", message: "The Mac has no sound output.") }
        var address = property(selector)
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else {
            throw WireError(code: "unsupported", message: missing)
        }
        var value = value
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value)
        guard status == noErr else { throw WireError.failed("macOS didn't change the sound output (\(status)).") }
    }
}

/// DisplayServices isn't public API; if a macOS version drops it, brightness simply reports none.
private enum Brightness {
    private typealias CanChange = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Put = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                                          RTLD_LAZY)

    private static func function<T>(_ name: String, as type: T.Type) -> T? {
        guard let framework, let pointer = dlsym(framework, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    private static func changeable(_ display: CGDirectDisplayID) -> Bool {
        function("DisplayServicesCanChangeBrightness", as: CanChange.self)?(display) ?? false
    }

    static func level(_ display: CGDirectDisplayID) -> Double? {
        guard changeable(display), let get = function("DisplayServicesGetBrightness", as: Get.self) else { return nil }
        var level = Float(0)
        return get(display, &level) == 0 ? Double(level) : nil
    }

    static func set(_ level: Double, display: CGDirectDisplayID) throws {
        guard changeable(display), let put = function("DisplayServicesSetBrightness", as: Put.self) else {
            throw WireError(code: "unsupported", message: "This display's brightness can't be changed from here.")
        }
        guard put(display, Float(min(max(level, 0), 1))) == 0 else {
            throw WireError.failed("macOS didn't change the brightness.")
        }
    }
}
