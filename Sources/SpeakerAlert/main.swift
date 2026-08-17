import Accelerate
import CoreAudio
import Foundation

private final class SpeakerAlert {
    private let stateQueue = DispatchQueue(label: "io.github.meteorsliu.speaker-alert.state")
    private var speakerDevice = AudioDeviceID(kAudioObjectUnknown)
    private var bytesPerFrame = UInt32(0)
    private var silenceFrameThreshold = UInt64(0)
    private var silentFrameCount = UInt64(0)
    private var tapHasSignal = false
    private var hasSignal = false
    private var isMuted = false
    private var volume: Float32 = 0
    private var wasAudible = false

    private var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private lazy var outputControlListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.refreshOutputControls()
    }

    func run() {
        var translateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var speakerUID = "BuiltInSpeakerDevice" as CFString
        var device = AudioDeviceID(kAudioObjectUnknown)
        var deviceSize = UInt32(MemoryLayout.size(ofValue: device))
        let translateStatus = withUnsafePointer(to: &speakerUID) { uidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &translateAddress,
                UInt32(MemoryLayout<CFString>.size),
                uidPointer,
                &deviceSize,
                &device
            )
        }
        guard translateStatus == noErr, device != kAudioObjectUnknown else {
            fputs("speaker-alert: cannot find the built-in speaker (OSStatus \(translateStatus))\n", stderr)
            exit(1)
        }
        speakerDevice = device

        guard stateQueue.sync(execute: refreshOutputControls) else {
            exit(1)
        }
        let muteListenerStatus = AudioObjectAddPropertyListenerBlock(
            device,
            &muteAddress,
            stateQueue,
            outputControlListener
        )
        guard muteListenerStatus == noErr else {
            fputs("speaker-alert: cannot monitor speaker mute (OSStatus \(muteListenerStatus))\n", stderr)
            exit(1)
        }
        let volumeListenerStatus = AudioObjectAddPropertyListenerBlock(
            device,
            &volumeAddress,
            stateQueue,
            outputControlListener
        )
        guard volumeListenerStatus == noErr else {
            AudioObjectRemovePropertyListenerBlock(
                device,
                &muteAddress,
                stateQueue,
                outputControlListener
            )
            fputs("speaker-alert: cannot monitor speaker volume (OSStatus \(volumeListenerStatus))\n", stderr)
            exit(1)
        }

        let tapDescription = CATapDescription(
            excludingProcesses: [],
            deviceUID: "BuiltInSpeakerDevice",
            stream: 0
        )
        tapDescription.name = "Speaker Alert"
        tapDescription.uuid = UUID()
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &tap)
        guard tapStatus == noErr else {
            fputs("speaker-alert: cannot create process tap (OSStatus \(tapStatus))\n", stderr)
            exit(1)
        }

        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout.size(ofValue: format))
        let formatStatus = AudioObjectGetPropertyData(
            tap,
            &formatAddress,
            0,
            nil,
            &formatSize,
            &format
        )
        guard formatStatus == noErr,
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else {
            AudioHardwareDestroyProcessTap(tap)
            fputs("speaker-alert: built-in speaker tap is not Float32 PCM\n", stderr)
            exit(1)
        }
        bytesPerFrame = format.mBytesPerFrame
        silenceFrameThreshold = UInt64(format.mSampleRate / 4)

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Speaker Alert",
            kAudioAggregateDeviceUIDKey: "io.github.meteorsliu.speaker-alert.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapDescription.uuid.uuidString]
            ],
        ]
        var aggregateDevice = AudioDeviceID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &aggregateDevice
        )
        guard aggregateStatus == noErr else {
            AudioHardwareDestroyProcessTap(tap)
            fputs("speaker-alert: cannot create tap device (OSStatus \(aggregateStatus))\n", stderr)
            exit(1)
        }

        var ioProc: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(
            &ioProc,
            aggregateDevice,
            nil
        ) { [weak self] _, inputData, _, _, _ in
            self?.handleAudio(inputData)
        }
        guard ioStatus == noErr, let ioProc else {
            AudioHardwareDestroyAggregateDevice(aggregateDevice)
            AudioHardwareDestroyProcessTap(tap)
            fputs("speaker-alert: cannot create audio callback (OSStatus \(ioStatus))\n", stderr)
            exit(1)
        }

        let startStatus = AudioDeviceStart(aggregateDevice, ioProc)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregateDevice, ioProc)
            AudioHardwareDestroyAggregateDevice(aggregateDevice)
            AudioHardwareDestroyProcessTap(tap)
            fputs("speaker-alert: cannot start audio callback (OSStatus \(startStatus))\n", stderr)
            exit(1)
        }

        // Core Audio invokes handleAudio for each tapped buffer; there is no polling timer.
        dispatchMain()
    }

    private func handleAudio(_ inputData: UnsafePointer<AudioBufferList>) {
        var bufferHasSignal = false
        var bufferFrameCount = UInt32(0)
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        for buffer in buffers {
            guard let data = buffer.mData else {
                continue
            }
            let samples = data.assumingMemoryBound(to: Float.self)
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            bufferFrameCount = max(bufferFrameCount, buffer.mDataByteSize / bytesPerFrame)
            if sampleCount > 0 {
                var maximumMagnitude: Float = 0
                vDSP_maxmgv(samples, 1, &maximumMagnitude, vDSP_Length(sampleCount))
                bufferHasSignal = maximumMagnitude > 0
            }
            if bufferHasSignal {
                break
            }
        }

        if bufferHasSignal {
            silentFrameCount = 0
            guard !tapHasSignal else {
                return
            }
            tapHasSignal = true
        } else {
            guard tapHasSignal else {
                return
            }
            silentFrameCount += UInt64(bufferFrameCount)
            guard silentFrameCount >= silenceFrameThreshold else {
                return
            }
            silentFrameCount = 0
            tapHasSignal = false
        }

        let hasSignal = tapHasSignal
        stateQueue.async { [weak self] in
            self?.hasSignal = hasSignal
            self?.updateAudibility()
        }
    }

    @discardableResult
    private func refreshOutputControls() -> Bool {
        var mute: UInt32 = 0
        var muteSize = UInt32(MemoryLayout.size(ofValue: mute))
        var muteProperty = muteAddress
        let muteStatus = AudioObjectGetPropertyData(
            speakerDevice,
            &muteProperty,
            0,
            nil,
            &muteSize,
            &mute
        )

        var currentVolume: Float32 = 0
        var volumeSize = UInt32(MemoryLayout.size(ofValue: currentVolume))
        var volumeProperty = volumeAddress
        let volumeStatus = AudioObjectGetPropertyData(
            speakerDevice,
            &volumeProperty,
            0,
            nil,
            &volumeSize,
            &currentVolume
        )
        guard muteStatus == noErr, volumeStatus == noErr else {
            fputs(
                "speaker-alert: cannot read speaker controls " +
                "(mute OSStatus \(muteStatus), volume OSStatus \(volumeStatus))\n",
                stderr
            )
            return false
        }

        isMuted = mute != 0
        volume = currentVolume
        updateAudibility()
        return true
    }

    private func updateAudibility() {
        let isAudible = hasSignal && !isMuted && volume > 0
        guard isAudible != wasAudible else {
            return
        }
        wasAudible = isAudible
        if isAudible {
            notify()
        }
    }

    private func notify() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "display notification \"音频正在通过 Mac 扬声器播放\" with title \"扬声器提醒\""
        ]
        do {
            try process.run()
        } catch {
            fputs("speaker-alert: cannot display notification: \(error)\n", stderr)
        }
    }
}

private let speakerAlert = SpeakerAlert()
speakerAlert.run()
