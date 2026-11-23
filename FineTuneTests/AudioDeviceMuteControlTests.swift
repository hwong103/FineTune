// FineTuneTests/AudioDeviceMuteControlTests.swift
import AudioToolbox
import Testing
@testable import FineTune

@Suite("AudioDeviceID mute controls")
struct AudioDeviceMuteControlTests {
    @Test("reads and clears per-channel mute when main mute is unavailable")
    func perChannelMuteFallback() {
        let device = AudioDeviceID(42_424)
        let accessor = FakeAudioDeviceMuteAccessor(
            channelMutes: [
                1: true,
                2: true
            ]
        )

        #expect(device.readMuteState(using: accessor))
        #expect(device.setMuteState(false, using: accessor))
        #expect(accessor.channelMutes == [1: false, 2: false])
    }
}

private final class FakeAudioDeviceMuteAccessor: AudioDeviceMuteAccessing {
    var channelMutes: [AudioObjectPropertyElement: Bool]

    init(channelMutes: [AudioObjectPropertyElement: Bool]) {
        self.channelMutes = channelMutes
    }

    func outputChannelCount(for device: AudioDeviceID) -> Int {
        channelMutes.count
    }

    func readMute(for device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool? {
        channelMutes[element]
    }

    func writeMute(_ muted: Bool, for device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool {
        guard channelMutes[element] != nil else { return false }
        channelMutes[element] = muted
        return true
    }
}
