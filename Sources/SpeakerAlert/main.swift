import CoreAudio
import Foundation

private final class SpeakerAlert {
    private let notificationQueue = DispatchQueue(label: "io.github.meteorsliu.speaker-alert.notification")
    private var wasAudible = false

    func run() {
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
        var isAudible = false
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        for buffer in buffers {
            guard let data = buffer.mData else {
                continue
            }
            let samples = data.assumingMemoryBound(to: Float.self)
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            for index in 0..<sampleCount where samples[index] != 0 {
                isAudible = true
                break
            }
            if isAudible {
                break
            }
        }

        if isAudible {
            if !wasAudible {
                wasAudible = true
                notificationQueue.async { [weak self] in
                    self?.notify()
                }
            }
        } else {
            wasAudible = false
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
