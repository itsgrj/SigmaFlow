import AudioToolbox
import AVFoundation
import Foundation

/// Records a meeting straight to a compressed file on disk.
///
/// The microphone is converted on the fly to 16 kHz mono float and written as AAC. That
/// rate is what every speech model downstream wants, and AAC at 32 kbps keeps a 45-minute
/// meeting near 11 MB rather than the 90 MB a WAV would take. Nothing is kept in memory:
/// the file is the recording, so a crash mid-meeting loses seconds, not the meeting.
///
/// Same threading contract as `AudioCapture`: the tap runs on the real-time audio thread,
/// so the state it touches sits behind `nonisolated(unsafe)` and is only ever mutated there.
final class MeetingRecorder: @unchecked Sendable {
    static let sampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private nonisolated(unsafe) var converter: AVAudioConverter?
    private nonisolated(unsafe) var file: AVAudioFile?
    private nonisolated(unsafe) var framesWritten: AVAudioFramePosition = 0
    private nonisolated(unsafe) var onLevel: (@Sendable (Float) -> Void)?
    /// Every 16 kHz buffer as it is written, for a live transcript (live notes). Each call
    /// gets its own copy: the tap's buffers are recycled the moment the callback returns.
    private nonisolated(unsafe) var onAudio: (@Sendable (AudioChunk) -> Void)?
    /// Paused: the microphone stays open, nothing is written or handed on. The file and the
    /// live transcript share one clock, the audio's, so a pause leaves no gap in either.
    nonisolated(unsafe) var isPaused = false
    /// Muted: silence is written in place of sound, so the clock runs on but nothing said is
    /// kept (live notes while you dictate).
    nonisolated(unsafe) var isMuted = false
    private var isRunning = false
    private(set) var fileURL: URL?

    static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    /// The file every meeting's audio is written as: AAC, 32 kbps, 16 kHz, mono. A dropped
    /// recording is converted to exactly this too (`MeetingImport`).
    static let fileSettings: [String: any Sendable] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
    ]

    /// Seconds of audio written so far. Safe to read from any thread for display purposes.
    var seconds: Double {
        Double(framesWritten) / Self.sampleRate
    }

    func start(
        to url: URL, inputDeviceUID: String?, onLevel: @escaping @Sendable (Float) -> Void,
        onAudio: (@Sendable (AudioChunk) -> Void)? = nil
    ) throws {
        guard !isRunning else { return }

        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(
            forWriting: url, settings: Self.fileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.file = file
        self.fileURL = url
        self.framesWritten = 0
        self.onLevel = onLevel
        self.onAudio = onAudio
        self.isPaused = false
        self.isMuted = false

        let input = engine.inputNode
        if let inputDeviceUID {
            if var deviceID = MicrophoneDevices.audioDeviceID(forUID: inputDeviceUID),
               let unit = input.audioUnit {
                let status = AudioUnitSetProperty(
                    unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                    &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
                if status != noErr {
                    Log.audio.error("meeting: couldn't select microphone (\(status)) — using system default")
                }
            } else {
                Log.audio.info("meeting: selected microphone not connected — using system default")
            }
        }

        let native = input.outputFormat(forBus: 0)
        converter = native == Self.outputFormat ? nil : AVAudioConverter(from: native, to: Self.outputFormat)
        // A nil converter must mean "formats already match", never "couldn't convert":
        // writing a mismatched buffer into the file raises an ObjC exception no catch sees.
        if native != Self.outputFormat, converter == nil {
            throw NSError(domain: "MeetingRecorder", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Can't convert \(Int(native.sampleRate)) Hz input to 16 kHz.",
            ])
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: native) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        try engine.start()
        isRunning = true
        Log.audio.info("meeting recording started — native \(native.sampleRate)Hz → 16kHz AAC")
    }

    /// Stops and closes the file. Returns the URL and the duration written.
    @discardableResult
    func stop() -> (url: URL, seconds: Double)? {
        guard isRunning else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        converter = nil
        onLevel = nil
        onAudio = nil
        // AVAudioFile has no explicit close; dropping the last reference flushes the encoder.
        let result = fileURL.map { ($0, seconds) }
        file = nil
        Log.audio.info("meeting recording stopped — \(self.seconds, format: .fixed(precision: 1))s")
        return result
    }

    // MARK: Audio thread

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard !isPaused else {
            onLevel?(0)
            return
        }
        if isMuted, let channel = buffer.floatChannelData {
            for index in 0..<Int(buffer.format.channelCount) {
                channel[index].update(repeating: 0, count: Int(buffer.frameLength))
            }
        }
        onLevel?(Self.rms(of: buffer))
        guard let file else { return }

        guard let converter else {
            write(buffer, to: file)
            return
        }

        let ratio = Self.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity) else {
            return
        }

        nonisolated(unsafe) let input = buffer
        let consumed = Latch()
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            guard !consumed.take() else {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return input
        }
        if let error {
            Log.audio.error("meeting: conversion failed: \(error.localizedDescription)")
            return
        }
        guard status != .error, converted.frameLength > 0 else { return }
        write(converted, to: file)
    }

    private func write(_ buffer: AVAudioPCMBuffer, to file: AVAudioFile) {
        do {
            try file.write(from: buffer)
            framesWritten += AVAudioFramePosition(buffer.frameLength)
            if let onAudio, let copy = Self.copy(buffer) { onAudio(AudioChunk(buffer: copy)) }
        } catch {
            Log.audio.error("meeting: write failed: \(error.localizedDescription)")
        }
    }

    private final class Latch: @unchecked Sendable {
        private var fired = false
        func take() -> Bool {
            defer { fired = true }
            return fired
        }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let from = buffer.floatChannelData?[0], let to = copy.floatChannelData?[0]
        else { return nil }
        copy.frameLength = buffer.frameLength
        to.update(from: from, count: Int(buffer.frameLength))
        return copy
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count {
            let sample = channel[i]
            sum += sample * sample
        }
        let rms = (sum / Float(count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        return max(0, min(1, (db + 50) / 50))
    }
}
