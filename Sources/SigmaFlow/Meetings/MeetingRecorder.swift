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
    /// The microphone picked in Settings, kept for reopening after a device change.
    private var inputDeviceUID: String?
    /// When the tap last delivered a buffer. Only touched on the main thread while the tap is
    /// removed, and on the audio thread otherwise.
    private nonisolated(unsafe) var lastAudioAt = Date.distantPast
    private var reopens = 0
    private static let reopenLimit = 20
    /// Silence written for a gap is capped, so a wrong clock can't write an hour of zeros.
    private static let longestGap: TimeInterval = 60
    private var configObserver: (any NSObjectProtocol)?

    init() {
        // AirPods connecting mid-meeting stop the engine and post this; without a reopen the
        // rest of the meeting would be recorded as nothing (as a dictation was, 26 Nov 2026).
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.reopen()
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

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
        self.inputDeviceUID = inputDeviceUID
        reopens = 0

        try open()
        isRunning = true
    }

    /// Opens the microphone again after a device change, and fills the time it was gone with
    /// silence, so the file keeps the meeting's clock: photo, screenshot and video times are
    /// all read against it.
    private func reopen() {
        guard isRunning, let file else { return }
        guard reopens < Self.reopenLimit else {
            Log.audio.error("meeting: not reopening the microphone again")
            return
        }
        reopens += 1
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let gap = min(Date().timeIntervalSince(lastAudioAt), Self.longestGap)
        if !isPaused, gap > 0.05, lastAudioAt != .distantPast {
            writeSilence(seconds: gap, to: file)
        }
        do {
            try open()
            Log.audio.info("meeting: microphone reopened after a device change, \(gap, format: .fixed(precision: 2))s filled")
        } catch {
            Log.audio.error("meeting: couldn't reopen the microphone: \(error.localizedDescription)")
        }
    }

    private func writeSilence(seconds: TimeInterval, to file: AVAudioFile) {
        let frames = AVAudioFrameCount(seconds * Self.sampleRate)
        guard frames > 0, let silence = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: frames) else {
            return
        }
        silence.frameLength = frames
        if let channel = silence.floatChannelData?[0] { channel.update(repeating: 0, count: Int(frames)) }
        write(silence, to: file)
    }

    private func open() throws {
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
        guard native.sampleRate > 0, native.channelCount > 0 else {
            throw NSError(domain: "MeetingRecorder", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "The microphone isn\u{2019}t ready.",
            ])
        }
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
        lastAudioAt = Date()
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
        lastAudioAt = Date()
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
