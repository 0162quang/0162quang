import AVFoundation

enum AudioError: LocalizedError {
    case noInput
    var errorDescription: String? { "Không tìm thấy micro. Kiểm tra quyền truy cập micro trong Cài đặt." }
}

/// Bao quanh AVAudioEngine. Callback thời gian thực chỉ gọi thẳng vào C, không đụng runtime Swift.
final class AudioIO {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var timePitch: AVAudioUnitTimePitch?
    private var vocalMix: AVAudioMixerNode?
    private var dsp: UnsafeMutableRawPointer?
    private var playerFormat: AVAudioFormat?
    private let scratchFrames = 4096
    private let scratch: UnsafeMutablePointer<Float>

    private(set) var sampleRate: Double = 48000
    private(set) var isRunning = false
    private(set) var beatFile: AVAudioFile?
    private var beatPlaying = false
    private var beatGen = 0
    var onBeatEnded: (() -> Void)?

    /// Độ trễ vòng đo thật (giây). Nil = dùng số ước tính của hệ thống.
    var measuredRoundTrip: Double?
    private(set) var countInSeconds = 0.0
    private var beatSeconds = 0.6

    private var dryFile: AVAudioFile?
    private var wetFile: AVAudioFile?
    private var writerTimer: DispatchSourceTimer?
    private let writerQueue = DispatchQueue(label: "vocaltune.writer", qos: .utility)
    private var drainBuf: AVAudioPCMBuffer?

    init() {
        scratch = .allocate(capacity: scratchFrames)
        scratch.initialize(repeating: 0, count: scratchFrames)
    }
    deinit { scratch.deallocate() }

    // MARK: Độ trễ

    private var estimatedRoundTrip: Double {
        let s = AVAudioSession.sharedInstance()
        return s.ioBufferDuration * 2 + s.inputLatency + s.outputLatency
    }
    var roundTripSeconds: Double { measuredRoundTrip ?? estimatedRoundTrip }

    var latencyMs: Double {
        guard let dsp else { return 0 }
        return (Double(vt_latency(dsp)) / sampleRate + roundTripSeconds) * 1000
    }

    /// Độ trễ cần trừ khi mix gối beat (giây).
    var recordingCompensation: Double {
        if let m = measuredRoundTrip { return m }
        let s = AVAudioSession.sharedInstance()
        return s.inputLatency + s.outputLatency + s.ioBufferDuration
    }

    var sessionBufferMs: Double { AVAudioSession.sharedInstance().ioBufferDuration * 1000 }

    // MARK: Điều khiển engine

    func start(settings: TuneSettings, lowPower: Bool, bufferFrames: Int) throws {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement,
                                options: [.allowBluetoothA2DP, .defaultToSpeaker])
        try session.setPreferredSampleRate(48000)
        try session.setPreferredIOBufferDuration(Double(bufferFrames) / 48000.0)
        try session.setActive(true)

        let engine = AVAudioEngine()
        let hw = engine.inputNode.outputFormat(forBus: 0)
        guard hw.sampleRate > 0, hw.channelCount > 0 else { throw AudioError.noInput }
        sampleRate = hw.sampleRate

        guard let handle = vt_create(Float(hw.sampleRate), Int32(settings.range.rawValue)) else { throw AudioError.noInput }
        dsp = handle
        var p = settings.vtParams(lowPower: lowPower)
        vt_set_params(handle, &p)

        // Mic -> DSP
        let scratchPtr = scratch
        let scratchCap = scratchFrames
        let sink = AVAudioSinkNode { _, frames, abl in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
            guard list.count > 0, let raw = list[0].mData else { return noErr }
            let src = raw.assumingMemoryBound(to: Float.self)
            let ch = Int(list[0].mNumberChannels)
            let n = Int(frames)
            if ch <= 1 {
                vt_capture(handle, src, Int32(n))
            } else {
                let m = min(n, scratchCap)
                for i in 0..<m { scratchPtr[i] = src[i * ch] }
                vt_capture(handle, scratchPtr, Int32(m))
            }
            return noErr
        }

        // DSP -> tai nghe
        let outFmt = AVAudioFormat(standardFormatWithSampleRate: hw.sampleRate, channels: 2)!
        let source = AVAudioSourceNode(format: outFmt) { _, _, frames, abl in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            guard list.count > 0, let raw = list[0].mData else { return noErr }
            let p0 = raw.assumingMemoryBound(to: Float.self)
            vt_monitor(handle, p0, Int32(frames))
            if list.count > 1, let r1 = list[1].mData {
                memcpy(r1, p0, Int(frames) * MemoryLayout<Float>.size)
            }
            return noErr
        }

        let vocalMix = AVAudioMixerNode()
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        engine.attach(sink); engine.attach(source); engine.attach(vocalMix)
        engine.attach(player); engine.attach(timePitch)
        engine.connect(engine.inputNode, to: sink, format: hw)
        engine.connect(source, to: vocalMix, format: outFmt)
        engine.connect(vocalMix, to: engine.mainMixerNode, format: outFmt)
        let beatFmt = beatFile?.processingFormat ?? outFmt
        engine.connect(player, to: timePitch, format: beatFmt)
        engine.connect(timePitch, to: engine.mainMixerNode, format: beatFmt)
        playerFormat = beatFmt
        vocalMix.outputVolume = Float(settings.vocalGain)
        player.volume = Float(settings.beatGain)
        timePitch.pitch = Float(settings.beatTranspose * 100)
        timePitch.bypass = settings.beatTranspose == 0

        engine.prepare()
        try engine.start()
        self.engine = engine; self.player = player; self.vocalMix = vocalMix; self.timePitch = timePitch
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        if dryFile != nil { stopRecording() }
        beatGen += 1; player?.stop(); beatPlaying = false
        engine?.stop()
        engine = nil; player = nil; vocalMix = nil; timePitch = nil
        if let dsp { vt_destroy(dsp) }
        dsp = nil
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func apply(settings: TuneSettings, lowPower: Bool, monitorAllowed: Bool) {
        guard let dsp else { return }
        var p = settings.vtParams(lowPower: lowPower)
        vt_set_params(dsp, &p)
        vocalMix?.outputVolume = monitorAllowed ? Float(settings.vocalGain) : 0
        player?.volume = Float(settings.beatGain)
        timePitch?.pitch = Float(settings.beatTranspose * 100)
        timePitch?.bypass = settings.beatTranspose == 0
    }

    func setBufferFrames(_ frames: Int) {
        try? AVAudioSession.sharedInstance().setPreferredIOBufferDuration(Double(frames) / 48000.0)
    }

    func telemetry() -> VTTelemetry {
        var t = VTTelemetry()
        if let dsp { vt_get_telemetry(dsp, &t) }
        return t
    }

    func diag() -> VTDiag {
        var d = VTDiag()
        if let dsp { vt_get_diag(dsp, &d) }
        return d
    }

    // MARK: Hiệu chuẩn độ trễ

    func calibStart() {
        guard let dsp else { return }
        vocalMix?.outputVolume = 1
        vt_calib_start(dsp)
    }
    var calibProgress: Double { dsp.map { Double(vt_calib_progress($0)) } ?? 0 }
    func calibResult() -> (ms: Double, conf: Double)? {
        guard let dsp else { return nil }
        var ms: Float = 0, cf: Float = 0
        return vt_calib_result(dsp, &ms, &cf) == 1 ? (Double(ms), Double(cf)) : nil
    }
    func calibStop() { if let dsp { vt_calib_stop(dsp) } }

    // MARK: Beat

    func loadBeat(_ url: URL?) throws {
        if beatPlaying { stopBeat() }
        beatFile = try url.map { try AVAudioFile(forReading: $0) }
        // Đổi beat khi engine đang chạy: nối lại node player theo định dạng mới.
        if isRunning, let engine, let player, let timePitch {
            let fmt = beatFile?.processingFormat ?? playerFormat
            if let fmt {
                engine.connect(player, to: timePitch, format: fmt)
                engine.connect(timePitch, to: engine.mainMixerNode, format: fmt)
                playerFormat = fmt
            }
        }
    }

    /// Phát beat, tùy chọn đếm nhịp trước (cùng một player nên nối liền chính xác đến từng mẫu).
    func startBeat(countInBeats: Int = 0, bpm: Double = 100) {
        guard isRunning, let player, let beat = beatFile, let fmt = playerFormat else { return }
        player.stop()
        beatGen += 1
        let gen = beatGen
        beatSeconds = 60.0 / max(30.0, bpm)
        countInSeconds = countInBeats > 0 ? beatSeconds * Double(countInBeats) : 0
        if countInBeats > 0, let clicks = makeCountIn(beats: countInBeats, format: fmt) {
            player.scheduleBuffer(clicks, at: nil, options: [], completionHandler: nil)
        } else {
            countInSeconds = 0
        }
        player.scheduleFile(beat, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.beatGen == gen, self.beatPlaying else { return }
                self.beatPlaying = false
                self.onBeatEnded?()
            }
        }
        player.play()
        beatPlaying = true
    }

    func stopBeat() { beatGen += 1; player?.stop(); beatPlaying = false; countInSeconds = 0 }
    var isBeatPlaying: Bool { beatPlaying }

    private func makeCountIn(beats: Int, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let beatFrames = Int(beatSeconds * sr)
        let total = beatFrames * beats
        guard total > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)),
              let ch = buf.floatChannelData else { return nil }
        buf.frameLength = AVAudioFrameCount(total)
        let chans = Int(format.channelCount)
        for c in 0..<chans { memset(ch[c], 0, total * MemoryLayout<Float>.size) }
        let clickLen = Int(0.045 * sr)
        for b in 0..<beats {
            let f = b == 0 ? 2200.0 : 1600.0
            let start = b * beatFrames
            for i in 0..<min(clickLen, total - start) {
                let env = exp(-Double(i) / (0.008 * sr))
                let s = Float(0.8 * env * sin(2 * Double.pi * f * Double(i) / sr))
                for c in 0..<chans { ch[c][start + i] = s }
            }
        }
        return buf
    }

    var beatDuration: Double {
        guard let b = beatFile else { return 0 }
        return Double(b.length) / b.processingFormat.sampleRate
    }

    private var playerSeconds: Double? {
        guard beatPlaying, let player, let nt = player.lastRenderTime,
              let pt = player.playerTime(forNodeTime: nt) else { return nil }
        return Double(pt.sampleTime) / pt.sampleRate
    }

    /// Thời điểm hiện tại trong beat (giây), đã trừ phần đếm nhịp.
    var beatTime: Double { max(0, (playerSeconds ?? 0) - countInSeconds) }
    /// 0...1, chỉ có nghĩa khi beat đang phát.
    var beatProgress: Double { beatDuration > 0 ? min(1, beatTime / beatDuration) : 0 }
    /// Số nhịp còn lại của phần đếm nhịp (4, 3, 2, 1) hoặc nil nếu không đang đếm.
    var countInNumber: Int? {
        guard countInSeconds > 0, let s = playerSeconds, s < countInSeconds else { return nil }
        return max(1, Int(ceil((countInSeconds - s) / beatSeconds)))
    }

    // MARK: Ghi âm (dry + wet)

    func startRecording(dryURL: URL, wetURL: URL) throws {
        guard let dsp else { throw AudioError.noInput }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
        ]
        dryFile = try AVAudioFile(forWriting: dryURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        wetFile = try AVAudioFile(forWriting: wetURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        drainBuf = AVAudioPCMBuffer(pcmFormat: dryFile!.processingFormat, frameCapacity: 8192)

        let timer = DispatchSource.makeTimerSource(queue: writerQueue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        writerTimer = timer
        vt_set_recording(dsp, 1)
    }

    private func drain() {
        guard let dsp, let buf = drainBuf, let ch = buf.floatChannelData?[0] else { return }
        for (file, isDry) in [(dryFile, true), (wetFile, false)] {
            guard let file else { continue }
            while true {
                let n = isDry ? vt_read_dry(dsp, ch, 8192) : vt_read_wet(dsp, ch, 8192)
                if n <= 0 { break }
                buf.frameLength = AVAudioFrameCount(n)
                try? file.write(from: buf)
            }
        }
    }

    func stopRecording() {
        if let dsp { vt_set_recording(dsp, 0) }
        writerTimer?.cancel(); writerTimer = nil
        writerQueue.sync { self.drain() }
        dryFile = nil; wetFile = nil; drainBuf = nil
    }
}
