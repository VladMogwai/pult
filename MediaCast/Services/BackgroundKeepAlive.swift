import AVFoundation

/// Keeps the app alive while the phone is locked during DLNA casting.
/// Plays a silent audio loop — requires UIBackgroundModes: [audio] in Info.plist.
final class BackgroundKeepAlive {
    static let shared = BackgroundKeepAlive()

    private var player: AVAudioPlayer?
    private var isRunning = false

    private init() {}

    func start() {
        guard !isRunning else { return }
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[MC-BG] AVAudioSession error: \(error)")
            return
        }

        let wav = makeSilentWAV()
        do {
            let p = try AVAudioPlayer(data: wav, fileTypeHint: AVFileType.wav.rawValue)
            p.numberOfLoops = -1
            p.volume = 0.01
            p.prepareToPlay()
            p.play()
            player = p
            isRunning = true
            print("[MC-BG] keep-alive started, playing=\(p.isPlaying)")
        } catch {
            print("[MC-BG] AVAudioPlayer error: \(error)")
        }
        #endif
    }

    func stop() {
        guard isRunning else { return }
        player?.stop()
        player = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        isRunning = false
        print("[MC-BG] keep-alive stopped")
    }

    // MARK: - WAV builder

    /// Returns a minimal valid WAV (44100 Hz, mono, 16-bit, 0.5 s of silence) as Data.
    /// AVAudioPlayer needs a real audio format — AVAudioEngine with zero-filled buffers
    /// can be detected and ignored by iOS, leaving the app suspended on lock.
    private func makeSilentWAV() -> Data {
        let sampleRate: UInt32 = 44100
        let numSamples: UInt32 = sampleRate / 2   // 0.5 s
        let dataSize:   UInt32 = numSamples * 2   // 16-bit mono → 2 bytes/sample

        var d = Data()
        d += fourCC("RIFF")
        d += u32LE(36 + dataSize)
        d += fourCC("WAVE")
        d += fourCC("fmt ")
        d += u32LE(16)            // fmt chunk size
        d += u16LE(1)             // PCM
        d += u16LE(1)             // channels
        d += u32LE(sampleRate)
        d += u32LE(sampleRate * 2) // byte rate
        d += u16LE(2)             // block align
        d += u16LE(16)            // bits per sample
        d += fourCC("data")
        d += u32LE(dataSize)
        d += Data(count: Int(dataSize))
        return d
    }

    private func fourCC(_ s: String) -> Data { Data(s.utf8) }
    private func u32LE(_ v: UInt32) -> Data { Data([
        UInt8(v & 0xff), UInt8((v >> 8) & 0xff),
        UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)
    ]) }
    private func u16LE(_ v: UInt16) -> Data { Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]) }
}
