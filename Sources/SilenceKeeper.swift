import AVFoundation

/// Keeps the audio output open with a continuous stream of digital silence.
/// While the stream runs, macOS doesn't power down the codec/amp, so there's no click when sound starts.
final class SilenceKeeper: NSObject {
    private var engine: AVAudioEngine?

    /// Called on the main queue when the engine stops on its own (output device changed, etc.).
    var onUnexpectedStop: (() -> Void)?

    var isRunning: Bool { engine?.isRunning == true }

    func start() {
        if isRunning { return }
        stop()

        let engine = AVAudioEngine()
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: 1) else {
            return
        }

        let source = AVAudioSourceNode(format: format, renderBlock: Self.silence)
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        guard (try? engine.start()) != nil else { return }

        NotificationCenter.default.addObserver(self, selector: #selector(configurationChanged),
                                               name: .AVAudioEngineConfigurationChange, object: engine)
        self.engine = engine
    }

    func stop() {
        guard let engine else { return }
        NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: engine)
        engine.stop()
        self.engine = nil
    }

    @objc private func configurationChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stop()
            self.onUnexpectedStop?()
        }
    }

    /// Runs on the realtime audio thread: no allocations, no locks.
    private static let silence: AVAudioSourceNodeRenderBlock = { _, _, _, bufferList -> OSStatus in
        for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
        return noErr
    }
}
