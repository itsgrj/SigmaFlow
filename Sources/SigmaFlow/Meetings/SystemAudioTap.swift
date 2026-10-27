import AVFoundation
import CoreAudio
import Foundation

/// Records the other side of a call: what the Mac plays, tapped before it reaches the
/// speakers or AirPods, so headphones make no difference (tested 13 Oct 2026 with AirPods).
///
/// A Core Audio process tap (macOS 14.4+) on everything except SigmaFlow itself, so the
/// start and stop sounds never land in the recording, read through a private aggregate
/// device. Written the way `MeetingRecorder` writes the microphone: 16 kHz mono AAC, straight
/// to disk. The first use asks macOS for System Audio Recording (`NSAudioCaptureUsageDescription`).
/// Refused, the tap delivers silence and the meeting is simply the microphone.
///
/// The IO block runs on its own queue; the state it touches sits behind `nonisolated(unsafe)`
/// and is only mutated there, the same contract as `MeetingRecorder`'s tap.
final class SystemAudioTap: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.grj.sigmaflow.call-tap", qos: .userInitiated)

    private nonisolated(unsafe) var file: AVAudioFile?
    private nonisolated(unsafe) var converter: AVAudioConverter?
    private nonisolated(unsafe) var tapFormat: AVAudioFormat?
    private nonisolated(unsafe) var onLevel: (@Sendable (Float) -> Void)?
    private nonisolated(unsafe) var loudest: Float = 0

    struct Failure: LocalizedError {
        let step: String
        let status: OSStatus
        var errorDescription: String? { "\(step) (\(status))" }
    }

    /// Starts tapping and writing. Throws if the tap or its device cannot be made.
    func start(to url: URL, onLevel: @escaping @Sendable (Float) -> Void) throws {
        let excluded = Self.ownProcessObject().map { [$0] } ?? []
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw Failure(step: "create tap", status: status) }

        let outputUID = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SigmaFlow call",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { stop(); throw Failure(step: "create device", status: status) }

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            stop(); throw Failure(step: "read format", status: status)
        }
        tapFormat = format
        converter = AVAudioConverter(from: format, to: MeetingRecorder.outputFormat)
        file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: MeetingRecorder.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
            ],
            commonFormat: .pcmFormatFloat32, interleaved: false)
        self.onLevel = onLevel

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            self?.handle(input)
        }
        guard status == noErr else { stop(); throw Failure(step: "create io", status: status) }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { stop(); throw Failure(step: "start", status: status) }
        Log.meetings.info("call tap started: \(format.sampleRate) Hz, \(format.channelCount) ch")
    }

    /// Stops and closes the file. Returns the loudest sample heard, so a silent call side
    /// (no call, or permission refused) can be left out.
    @discardableResult
    func stop() -> Float {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        // The queue may be mid-write; let it finish before the file is dropped.
        queue.sync {}
        file = nil
        converter = nil
        onLevel = nil
        return loudest
    }

    // MARK: Audio queue

    private func handle(_ input: UnsafePointer<AudioBufferList>) {
        guard let format = tapFormat, let file, let converter,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
              buffer.frameLength > 0
        else { return }

        if let samples = buffer.floatChannelData?[0] {
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) {
                let s = samples[i]
                sum += s * s
                loudest = max(loudest, abs(s))
            }
            let rms = (sum / Float(buffer.frameLength)).squareRoot()
            let db = 20 * log10(max(rms, 1e-7))
            onLevel?(max(0, min(1, (db + 50) / 50)))
        }

        let ratio = MeetingRecorder.sampleRate / format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: MeetingRecorder.outputFormat, frameCapacity: capacity) else { return }
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let source = buffer
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return source
        }
        guard error == nil, status != .error, converted.frameLength > 0 else { return }
        try? file.write(from: converted)
    }

    // MARK: Devices

    private static func ownProcessObject() -> AudioObjectID? {
        var pid = ProcessInfo.processInfo.processIdentifier
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr else { throw Failure(step: "default output", status: status) }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw Failure(step: "output uid", status: status) }
        return uid.takeRetainedValue() as String
    }
}
