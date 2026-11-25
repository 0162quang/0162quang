import AVFoundation

enum OfflineError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        if case .failed(let m) = self { return m }
        return nil
    }
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case m4a, wav
    var id: String { rawValue }
    var title: String { self == .m4a ? "M4A" : "WAV" }
}

enum OfflineRenderer {
    /// Render lại giọng dry với cài đặt hiện tại (studio). Chạy trên luồng nền.
    static func render(dryURL: URL, wetURL: URL, settings: TuneSettings,
                       progress: @escaping (Double) -> Void) throws {
        let input = try AVAudioFile(forReading: dryURL)
        let fmt = input.processingFormat
        guard let handle = vt_create(Float(fmt.sampleRate), Int32(settings.range.rawValue)) else {
            throw OfflineError.failed("Không khởi tạo được bộ xử lý")
        }
        defer { vt_destroy(handle) }
        var p = settings.vtParams(lowPower: false)
        vt_set_params(handle, &p)
        let delay = Int(vt_latency(handle))

        try? FileManager.default.removeItem(at: wetURL)
        let out = try AVAudioFile(forWriting: wetURL, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: fmt.sampleRate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)

        let cap: AVAudioFrameCount = 4096
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap),
              let outBuf = AVAudioPCMBuffer(pcmFormat: out.processingFormat, frameCapacity: cap),
              let inCh = inBuf.floatChannelData?[0], let outCh = outBuf.floatChannelData?[0] else {
            throw OfflineError.failed("Không cấp phát được bộ đệm")
        }
        var skip = delay
        let total = max(1, Double(input.length))

        func push(_ n: Int) throws {
            vt_process(handle, inCh, outCh, Int32(n))
            var start = 0
            if skip > 0 { start = min(skip, n); skip -= start }
            let remain = n - start
            if remain > 0 {
                if start > 0 { memmove(outCh, outCh + start, remain * MemoryLayout<Float>.size) }
                outBuf.frameLength = AVAudioFrameCount(remain)
                try out.write(from: outBuf)
            }
        }

        while input.framePosition < input.length {
            try input.read(into: inBuf, frameCount: cap)
            let n = Int(inBuf.frameLength)
            if n == 0 { break }
            try push(n)
            progress(Double(input.framePosition) / total)
        }
        // xả phần đuôi bằng im lặng
        var flushed = 0
        while flushed < delay {
            let n = min(Int(cap), delay - flushed)
            memset(inCh, 0, n * MemoryLayout<Float>.size)
            inBuf.frameLength = AVAudioFrameCount(n)
            try push(n)
            flushed += n
        }
        progress(1)
    }
}

enum Exporter {
    /// Mix giọng + beat ra file bằng engine ngoại tuyến (tự đổi sample rate).
    /// shiftMs < 0: kéo giọng lên sớm hơn (bù trễ thu).
    static func mix(vocalURL: URL, beatURL: URL?, vocalGain: Float, beatGain: Float,
                    shiftMs: Double, beatPitchCents: Float = 0, format: ExportFormat, to url: URL,
                    progress: @escaping (Double) -> Void) throws {
        let outRate = 48000.0
        let engine = AVAudioEngine()
        let vocalP = AVAudioPlayerNode(), beatP = AVAudioPlayerNode()
        let vocal = try AVAudioFile(forReading: vocalURL)
        let beat = try beatURL.map { try AVAudioFile(forReading: $0) }
        engine.attach(vocalP)
        engine.connect(vocalP, to: engine.mainMixerNode, format: vocal.processingFormat)
        if let beat {
            let tp = AVAudioUnitTimePitch()
            tp.pitch = beatPitchCents; tp.bypass = beatPitchCents == 0
            engine.attach(beatP); engine.attach(tp)
            engine.connect(beatP, to: tp, format: beat.processingFormat)
            engine.connect(tp, to: engine.mainMixerNode, format: beat.processingFormat)
        }
        vocalP.volume = vocalGain; beatP.volume = beatGain

        let renderFmt = AVAudioFormat(standardFormatWithSampleRate: outRate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: renderFmt, maximumFrameCount: 4096)

        let vSR = vocal.processingFormat.sampleRate
        let shift = Int64(shiftMs / 1000.0 * vSR)
        if shift < 0 {
            let skipF = min(-shift, vocal.length)
            vocalP.scheduleSegment(vocal, startingFrame: skipF, frameCount: AVAudioFrameCount(vocal.length - skipF), at: nil, completionHandler: nil)
        } else {
            if shift > 0, let silence = AVAudioPCMBuffer(pcmFormat: vocal.processingFormat, frameCapacity: AVAudioFrameCount(shift)) {
                silence.frameLength = AVAudioFrameCount(shift)
                vocalP.scheduleBuffer(silence, completionHandler: nil)
            }
            vocalP.scheduleFile(vocal, at: nil, completionHandler: nil)
        }
        beat.map { beatP.scheduleFile($0, at: nil, completionHandler: nil) }

        try engine.start()
        vocalP.play()
        if beat != nil { beatP.play() }

        let vocalFrames = Int64(Double(max(0, vocal.length + min(0, shift) + max(0, shift))) / vSR * outRate)
        let beatFrames = beat.map { Int64(Double($0.length) / $0.processingFormat.sampleRate * outRate) } ?? 0
        let total = max(vocalFrames, beatFrames) + 2400

        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any]
        switch format {
        case .wav:
            settings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: outRate, AVNumberOfChannelsKey: 2,
                        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        case .m4a:
            settings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: outRate, AVNumberOfChannelsKey: 2,
                        AVEncoderBitRateKey: 192000]
        }
        let out = try AVAudioFile(forWriting: url, settings: settings)
        guard let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            throw OfflineError.failed("Không cấp phát được bộ đệm")
        }
        while engine.manualRenderingSampleTime < total {
            let remaining = total - engine.manualRenderingSampleTime
            let n = AVAudioFrameCount(min(Int64(buf.frameCapacity), remaining))
            switch try engine.renderOffline(n, to: buf) {
            case .success:
                try out.write(from: buf)
                progress(Double(engine.manualRenderingSampleTime) / Double(total))
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                continue
            case .error:
                throw OfflineError.failed("Lỗi khi mix file")
            @unknown default:
                throw OfflineError.failed("Lỗi không xác định")
            }
        }
        engine.stop()
        progress(1)
    }
}

enum KeyDetector {
    struct Result { let root: Int; let minor: Bool; let confidence: Float }
    struct Analysis { let key: Result?; let bpm: Float?; let bpmConfidence: Float }

    /// Đọc ~45 giây ở giữa bài, trộn mono.
    static func loadMono(url: URL) -> (mono: [Float], rate: Double)? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        let fmt = f.processingFormat
        let want = AVAudioFrameCount(min(Double(f.length), 45 * fmt.sampleRate))
        f.framePosition = f.length > Int64(want) * 2 ? f.length / 4 : 0
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: want) else { return nil }
        try? f.read(into: buf, frameCount: want)
        let n = Int(buf.frameLength)
        guard n > 0, let ch = buf.floatChannelData else { return nil }
        let chans = Int(fmt.channelCount)
        var mono = [Float](repeating: 0, count: n)
        for c in 0..<chans { let p = ch[c]; for i in 0..<n { mono[i] += p[i] } }
        if chans > 1 { let k = 1 / Float(chans); for i in 0..<n { mono[i] *= k } }
        return (mono, fmt.sampleRate)
    }

    static func key(_ mono: [Float], _ rate: Double, _ refA4: Float) -> Result? {
        var root: Int32 = 0, minor: Int32 = 0, conf: Float = 0
        guard vt_detect_key(mono, Int32(mono.count), Float(rate), refA4, &root, &minor, &conf) == 1 else { return nil }
        return Result(root: Int(root), minor: minor != 0, confidence: conf)
    }

    static func detect(url: URL, refA4: Float) -> Result? {
        guard let m = loadMono(url: url) else { return nil }
        return key(m.mono, m.rate, refA4)
    }

    /// Nhận key và nhịp cùng lúc. Chạy trên luồng nền.
    static func analyze(url: URL, refA4: Float) -> Analysis {
        guard let m = loadMono(url: url) else { return Analysis(key: nil, bpm: nil, bpmConfidence: 0) }
        var bpm: Float = 0, conf: Float = 0
        let ok = vt_detect_bpm(m.mono, Int32(m.mono.count), Float(m.rate), &bpm, &conf) == 1
        return Analysis(key: key(m.mono, m.rate, refA4), bpm: ok ? bpm : nil, bpmConfidence: ok ? conf : 0)
    }
}

enum VocalImporter {
    /// Đọc âm thanh từ file (m4a, mp3, wav, hoặc video) và ghi ra CAF mono 48 kHz. Trả về thời lượng (giây).
    static func convert(url: URL, to dest: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw OfflineError.failed("File này không có âm thanh.")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else {
            throw OfflineError.failed(reader.error?.localizedDescription ?? "Không đọc được file.")
        }
        let out = try AVAudioFile(forWriting: dest, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000.0, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        var frames: Int64 = 0
        while let sb = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let len = CMBlockBufferGetDataLength(block)
            let n = len / MemoryLayout<Float>.size
            guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: out.processingFormat, frameCapacity: AVAudioFrameCount(n)),
                  let dst = buf.floatChannelData?[0] else { continue }
            buf.frameLength = AVAudioFrameCount(n)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * MemoryLayout<Float>.size, destination: dst)
            try out.write(from: buf)
            frames += Int64(n)
        }
        if reader.status == .failed { throw OfflineError.failed(reader.error?.localizedDescription ?? "Lỗi khi đọc file.") }
        guard frames > 0 else { throw OfflineError.failed("File không có dữ liệu âm thanh.") }
        return Double(frames) / 48000.0
    }
}
