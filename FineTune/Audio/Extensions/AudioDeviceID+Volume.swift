// FineTune/Audio/Extensions/AudioDeviceID+Volume.swift
import AudioToolbox

// MARK: - Volume Control Detection

extension AudioDeviceID {
    /// Returns true if this device supports CoreAudio volume control.
    /// Monitors connected via HDMI/DisplayPort often return false here.
    func hasOutputVolumeControl() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(self, &address) else { return false }
        var settable: DarwinBoolean = false
        let err = AudioObjectIsPropertySettable(self, &address, &settable)
        return err == noErr && settable.boolValue
    }
}

// MARK: - Device Volume

extension AudioDeviceID {
    /// Reads the scalar volume (0.0 to 1.0) for the device.
    /// Tries multiple strategies to find the most representative volume:
    /// 1. Virtual main volume via VirtualMainVolume (matches system volume slider)
    /// 2. Master volume scalar (element 0)
    /// 3. Left channel volume (element 1)
    /// Returns 1.0 for devices without volume control.
    func readOutputVolumeScalar() -> Float {
        // Strategy 1: Try virtual main volume (preferred - matches system slider)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioObjectHasProperty(self, &address) {
            var volume: Float32 = 1.0
            var size = UInt32(MemoryLayout<Float32>.size)
            let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &volume)
            if err == noErr {
                return volume
            }
        }

        // Strategy 2: Try master volume scalar (element 0)
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioObjectHasProperty(self, &address) {
            var volume: Float32 = 1.0
            var size = UInt32(MemoryLayout<Float32>.size)
            let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &volume)
            if err == noErr {
                return volume
            }
        }

        // Strategy 3: Try left channel (element 1) - common for stereo devices
        address.mElement = 1
        if AudioObjectHasProperty(self, &address) {
            var volume: Float32 = 1.0
            var size = UInt32(MemoryLayout<Float32>.size)
            let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &volume)
            if err == noErr {
                return volume
            }
        }

        // No volume control available
        return 1.0
    }

    /// Sets the scalar volume (0.0 to 1.0) for the device.
    /// Uses VirtualMainVolume via VirtualMainVolume to match system volume slider behavior.
    /// Returns true if successful, false otherwise.
    func setOutputVolumeScalar(_ volume: Float) -> Bool {
        let clampedVolume = Swift.max(0.0, Swift.min(1.0, volume))

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(self, &address) else {
            return false
        }

        var volumeValue: Float32 = clampedVolume
        let size = UInt32(MemoryLayout<Float32>.size)
        let err = AudioObjectSetPropertyData(self, &address, 0, nil, size, &volumeValue)
        return err == noErr
    }
}

// MARK: - Device Mute

protocol AudioDeviceMuteAccessing {
    func outputChannelCount(for device: AudioDeviceID) -> Int
    func readMute(for device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool?
    func writeMute(_ muted: Bool, for device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool
}

struct CoreAudioDeviceMuteAccessor: AudioDeviceMuteAccessing {
    func outputChannelCount(for device: AudioDeviceID) -> Int {
        device.outputChannelCount()
    }

    func readMute(for device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )

        guard AudioObjectHasProperty(device, &address) else { return nil }

        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let err = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted)
        return err == noErr ? muted != 0 : nil
    }

    func writeMute(_ muted: Bool, for device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )

        guard AudioObjectHasProperty(device, &address) else { return false }

        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        let err = AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
        return err == noErr
    }
}

extension AudioDeviceID {
    /// Reads the mute state for the device.
    /// Returns true if muted, false if unmuted or if mute is not supported.
    func readMuteState() -> Bool {
        readMuteState(using: CoreAudioDeviceMuteAccessor())
    }

    func readMuteState(using accessor: any AudioDeviceMuteAccessing) -> Bool {
        if let mainMute = accessor.readMute(for: self, element: kAudioObjectPropertyElementMain) {
            return mainMute
        }

        let channelCount = accessor.outputChannelCount(for: self)
        guard channelCount > 0 else { return false }

        let channelMutes = (1...channelCount).compactMap {
            accessor.readMute(for: self, element: AudioObjectPropertyElement($0))
        }
        // Expose a partially muted device as muted so one toggle restores every channel.
        return channelMutes.contains(true)
    }

    /// Sets the mute state for the device.
    /// Returns true if successful, false otherwise.
    func setMuteState(_ muted: Bool) -> Bool {
        setMuteState(muted, using: CoreAudioDeviceMuteAccessor())
    }

    func setMuteState(_ muted: Bool, using accessor: any AudioDeviceMuteAccessing) -> Bool {
        if accessor.writeMute(muted, for: self, element: kAudioObjectPropertyElementMain) {
            return true
        }

        let channelCount = accessor.outputChannelCount(for: self)
        guard channelCount > 0 else { return false }

        var supportedChannelCount = 0
        var allWritesSucceeded = true
        for channel in 1...channelCount {
            let element = AudioObjectPropertyElement(channel)
            guard accessor.readMute(for: self, element: element) != nil else { continue }
            supportedChannelCount += 1
            if !accessor.writeMute(muted, for: self, element: element) {
                allWritesSucceeded = false
            }
        }
        return supportedChannelCount > 0 && allWritesSucceeded
    }
}

// MARK: - Input Device Volume

extension AudioDeviceID {
    /// Reads the scalar volume (0.0 to 1.0) for the input device (microphone).
    /// Tries multiple strategies to find the most representative volume:
    /// 1. Virtual main volume via VirtualMainVolume (matches system input slider)
    /// 2. Master volume scalar (element 0)
    /// 3. Left channel volume (element 1)
    /// Returns 1.0 for devices without volume control.
    func readInputVolumeScalar() -> Float {
        // Strategy 1: Try virtual main volume (preferred - matches system slider)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioObjectHasProperty(self, &address) {
            var volume: Float32 = 1.0
            var size = UInt32(MemoryLayout<Float32>.size)
            let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &volume)
            if err == noErr {
                return volume
            }
        }

        // Strategy 2: Try master volume scalar (element 0)
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioObjectHasProperty(self, &address) {
            var volume: Float32 = 1.0
            var size = UInt32(MemoryLayout<Float32>.size)
            let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &volume)
            if err == noErr {
                return volume
            }
        }

        // Strategy 3: Try left channel (element 1) - common for stereo devices
        address.mElement = 1
        if AudioObjectHasProperty(self, &address) {
            var volume: Float32 = 1.0
            var size = UInt32(MemoryLayout<Float32>.size)
            let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &volume)
            if err == noErr {
                return volume
            }
        }

        // No volume control available
        return 1.0
    }

    /// Sets the scalar volume (0.0 to 1.0) for the input device (microphone).
    /// Uses VirtualMainVolume via VirtualMainVolume to match system input slider behavior.
    /// Returns true if successful, false otherwise.
    func setInputVolumeScalar(_ volume: Float) -> Bool {
        let clampedVolume = Swift.max(0.0, Swift.min(1.0, volume))

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(self, &address) else {
            return false
        }

        var volumeValue: Float32 = clampedVolume
        let size = UInt32(MemoryLayout<Float32>.size)
        let err = AudioObjectSetPropertyData(self, &address, 0, nil, size, &volumeValue)
        return err == noErr
    }
}

// MARK: - Input Device Mute

extension AudioDeviceID {
    /// Reads the mute state for the input device (microphone).
    /// Returns true if muted, false if unmuted or if mute is not supported.
    func readInputMuteState() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(self, &address) else {
            return false
        }

        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let err = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &muted)
        return err == noErr && muted != 0
    }

    /// Sets the mute state for the input device (microphone).
    /// Returns true if successful, false otherwise.
    func setInputMuteState(_ muted: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(self, &address) else {
            return false
        }

        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        let err = AudioObjectSetPropertyData(self, &address, 0, nil, size, &value)
        return err == noErr
    }
}
