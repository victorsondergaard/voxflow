import AVFoundation
import Foundation

enum AudioRecorderError: Error, LocalizedError {
    case noInputDevice
    case converterUnavailable

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No microphone input device found."
        case .converterUnavailable: return "Could not create the audio converter."
        }
    }
}

/// Captures microphone audio with AVAudioEngine and produces
/// 16 kHz mono 16-bit PCM WAV data regardless of the device's native format (SPEC R6).
final class AudioRecorder {
    /// Live input level 0…1, delivered on the main queue (drives the HUD bars).
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var pcmData = Data()
    private let queue = DispatchQueue(label: "voxflow.audio.append")
    private(set) var isRecording = false

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: true
    )!

    func start() throws {
        guard !isRecording else { return }
        queue.sync { pcmData.removeAll(keepingCapacity: true) }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputDevice
        }
        guard let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioRecorderError.converterUnavailable
        }
        converter = conv

        input.removeTap(onBus: 0)
        // Capture the converter locally so `stop()` nil-ing the property can't
        // race a queued append (converter access stays confined to `queue`).
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.queue.async { self.append(buffer: buffer, using: conv) }
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stops capture and returns a complete WAV file (or empty Data if nothing was captured).
    func stop() -> Data {
        guard isRecording else { return Data() }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        var samples = Data()
        queue.sync {
            samples = pcmData
            pcmData.removeAll(keepingCapacity: false)
        }
        converter = nil
        guard !samples.isEmpty else { return Data() }
        // Pad 0.3 s of silence on both ends: whisper is much better at catching
        // the first and last words when they aren't flush against the clip edge.
        let pad = Data(count: 4800 * MemoryLayout<Int16>.size)
        var padded = pad
        padded.append(samples)
        padded.append(pad)
        return AudioRecorder.wavFile(fromPCM: padded, sampleRate: 16000, channels: 1, bitsPerSample: 16)
    }

    // MARK: - Conversion

    private func append(buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var served = false
        var convError: NSError?
        converter.convert(to: out, error: &convError) { _, outStatus in
            if served {
                outStatus.pointee = .noDataNow
                return nil
            }
            served = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard convError == nil, out.frameLength > 0, let channel = out.int16ChannelData else { return }
        pcmData.append(UnsafeRawPointer(channel[0]).assumingMemoryBound(to: UInt8.self),
                       count: Int(out.frameLength) * MemoryLayout<Int16>.size)

        if let onLevel = onLevel {
            // Emit one level per ~32 ms window so the HUD scrolls like a real
            // waveform instead of giving one sluggish bounce per audio buffer.
            let total = Int(out.frameLength)
            var index = 0
            while index < total {
                let count = min(512, total - index)
                var sum: Double = 0
                for i in index..<(index + count) {
                    let sample = Double(channel[0][i])
                    sum += sample * sample
                }
                let rms = (sum / Double(count)).squareRoot() / 32768.0
                // Square-root curve makes normal speech fill the bars while
                // shouting clips at the top; below the gate is just room noise.
                let level: Float
                if rms < 0.003 {
                    level = 0.04
                } else {
                    level = Float(min(1.0, (rms * 14.0).squareRoot()))
                }
                DispatchQueue.main.async { onLevel(level) }
                index += count
            }
        }
    }

    // MARK: - WAV container

    static func wavFile(fromPCM pcm: Data, sampleRate: UInt32, channels: UInt16, bitsPerSample: UInt16) -> Data {
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(pcm.count)

        var header = Data()
        func append<T>(_ value: T) {
            var v = value
            withUnsafeBytes(of: &v) { header.append(contentsOf: $0) }
        }
        header.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataSize).littleEndian)
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16).littleEndian)               // fmt chunk size
        append(UInt16(1).littleEndian)                // PCM
        append(channels.littleEndian)
        append(sampleRate.littleEndian)
        append(byteRate.littleEndian)
        append(blockAlign.littleEndian)
        append(bitsPerSample.littleEndian)
        header.append(contentsOf: Array("data".utf8))
        append(dataSize.littleEndian)

        var file = header
        file.append(pcm)
        return file
    }
}
