import AVFoundation
import ScreenCaptureKit

/// Непрерывно держит в памяти последние 30 секунд системного звука.
///
/// Ничего не пишется на диск и не уходит в сеть: это кольцевой буфер в оперативке,
/// который постоянно перезаписывается. Включается вручную и по умолчанию выключен —
/// фоновая запись всего, что звучит на компьютере, не должна происходить втихую.
final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    static let shared = SystemAudioRecorder()

    private(set) var isRunning = false
    private var stream: SCStream?
    private let audioQueue = DispatchQueue(label: "mrdi.audio")
    private let ring = AudioRing(seconds: 30, sampleRate: 48_000)

    var onStop: ((Error?) -> Void)?

    private override init() { super.init() }

    var secondsBuffered: Double { ring.secondsBuffered }

    func start() async throws {
        guard !isRunning else { return }

        let content = try await SCShareableContent.current
        guard let display = content.displays.first else { throw ScreenCaptureError.displayNotFound }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // видео-поток не нужен, но SCStream без него не запускается:
        // берём минимальный кадр раз в секунду
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3
        config.showsCursor = false

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: audioQueue)
        try await stream.startCapture()

        self.stream = stream
        isRunning = true
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
        isRunning = false
        ring.reset()
    }

    /// Последние `seconds` секунд звука.
    func recentAudio(seconds: Double) -> AVAudioPCMBuffer? {
        ring.snapshot(seconds: seconds)
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        else { return }

        let channels = Int(asbd.mChannelsPerFrame)
        try? sampleBuffer.withAudioBufferList { list, _ in
            guard let first = list.first, let data = first.mData else { return }
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let pointer = data.assumingMemoryBound(to: Float.self)

            if channels <= 1 || list.count > 1 {
                // планарный звук: первый канал уже моно
                ring.append(pointer, count: frames)
            } else {
                // чередующийся стерео-буфер: сводим в моно
                var mono = [Float](repeating: 0, count: frames / channels)
                for i in 0..<mono.count {
                    var sum: Float = 0
                    for c in 0..<channels { sum += pointer[i * channels + c] }
                    mono[i] = sum / Float(channels)
                }
                mono.withUnsafeBufferPointer { ring.append($0.baseAddress!, count: $0.count) }
            }
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        isRunning = false
        self.stream = nil
        DispatchQueue.main.async { [weak self] in self?.onStop?(error) }
    }
}
