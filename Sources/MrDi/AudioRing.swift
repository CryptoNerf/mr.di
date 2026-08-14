import AVFoundation

/// Кольцевой буфер последних N секунд звука.
/// Пишется из аудио-очереди ScreenCaptureKit, читается с главной — отсюда замок.
final class AudioRing {
    private var storage: [Float]
    private var writeIndex = 0
    private var filled = 0
    private let lock = NSLock()

    let sampleRate: Double
    let capacity: Int

    init(seconds: Double, sampleRate: Double) {
        self.sampleRate = sampleRate
        self.capacity = Int(seconds * sampleRate)
        self.storage = [Float](repeating: 0, count: capacity)
    }

    func append(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        lock.lock()
        defer { lock.unlock() }

        // если кусок больше кольца — берём только его хвост
        let start = max(0, count - capacity)
        for i in start..<count {
            storage[writeIndex] = samples[i]
            writeIndex = (writeIndex + 1) % capacity
        }
        filled = min(capacity, filled + (count - start))
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        writeIndex = 0
        filled = 0
    }

    var secondsBuffered: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(filled) / sampleRate
    }

    /// Последние `seconds` секунд в хронологическом порядке.
    func snapshot(seconds: Double) -> AVAudioPCMBuffer? {
        lock.lock()
        let wanted = min(filled, Int(seconds * sampleRate))
        guard wanted > 0 else { lock.unlock(); return nil }

        var samples = [Float](repeating: 0, count: wanted)
        let startIndex = (writeIndex - wanted + capacity) % capacity
        for i in 0..<wanted {
            samples[i] = storage[(startIndex + i) % capacity]
        }
        lock.unlock()

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: 1,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(wanted))
        else { return nil }

        buffer.frameLength = AVAudioFrameCount(wanted)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: wanted)
        }
        return buffer
    }
}
