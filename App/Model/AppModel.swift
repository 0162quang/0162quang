import AVFoundation
import MetricKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum RouteKind {
    case wired, bluetooth, speaker
    var title: String {
        switch self {
        case .wired: return "Tai nghe"
        case .bluetooth: return "Bluetooth"
        case .speaker: return "Loa ngoài"
        }
    }
    var icon: String {
        switch self {
        case .wired: return "headphones"
        case .bluetooth: return "airpods"
        case .speaker: return "speaker.wave.2.fill"
        }
    }
}

struct Banner: Equatable {
    enum Level { case info, warn, danger }
    let text: String
    let icon: String
    let level: Level
}

struct Toast: Equatable, Identifiable {
    let id = UUID()
    let text: String
    let icon: String
}

enum SheetKind: String, Identifiable {
    case advanced, scale, takes, diagnostics, calibration, lyrics
    var id: String { rawValue }
}

enum ImportKind { case beat, lyrics, vocal }

enum CalibState: Equatable {
    case idle
    case running(Double)
    case done(ms: Double, conf: Double)
    case failed
}

/// Thu số liệu MetricKit (CPU, thời gian nền trước, âm thanh nền) lưu cục bộ, không gửi đi đâu.
final class MetricsCollector: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricsCollector()
    func start() { MXMetricManager.shared.add(self) }
    func didReceive(_ payloads: [MXMetricPayload]) {
        guard let p = payloads.last else { return }
        var parts: [String] = []
        if let c = p.cpuMetrics?.cumulativeCPUTime { parts.append("CPU \(Int(c.converted(to: .seconds).value)) s") }
        if let a = p.applicationTimeMetrics {
            parts.append("nền trước \(Int(a.cumulativeForegroundTime.converted(to: .seconds).value)) s")
            parts.append("âm thanh nền \(Int(a.cumulativeBackgroundAudioTime.converted(to: .seconds).value)) s")
        }
        UserDefaults.standard.set(parts.joined(separator: " · "), forKey: "metrics.summary")
    }
}

@Observable @MainActor
final class AppModel {
    var settings = TuneSettings()
    var presetID: String? = "natural"
    var sheet: SheetKind?
    var monitorOn = false
    var isRecording = false
    var recordStart: Date?
    var route: RouteKind = .wired
    var forceMonitor = false
    var saverMode = false
    var thermalCritical = false
    var beatName: String?
    var beatPreviewing = false
    var takes: [Take] = []
    var busyText: String?
    var errorMessage: String?
    var errorOpensSettings = false
    var playingTake: UUID?
    var exportNudgeMs = 0.0
    var latencyText = "—"
    var toast: Toast?
    var shareURL: URL?
    var importKind: ImportKind = .beat
    var showImporter = false
    var lyrics: Lyrics?
    var lyricsName: String?
    var darkActive = false
    var calib: CalibState = .idle
    var calibrating = false
    var calibrations: [String: Double] = [:]
    var routeUID = "default"
    var routeName = ""

    @ObservationIgnored let audio = AudioIO()
    @ObservationIgnored let history = PitchHistory()
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored private var darkTask: Task<Void, Never>?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var currentTakeDir: URL?
    @ObservationIgnored private var currentTake: Take?
    @ObservationIgnored private var beatFileName: String?

    var monitorAllowed: Bool { route != .speaker || forceMonitor }
    var uiFPS: Double { saverMode ? 15 : 30 }
    var engineRunning: Bool { monitorOn || isRecording || beatPreviewing || calibrating }
    var beatProgress: Double { audio.beatProgress }
    var calibMs: Double? { calibrations[routeUID] }

    /// Cảnh báo theo ngữ cảnh, chỉ hiện khi thật sự liên quan.
    var banner: Banner? {
        if thermalCritical { return Banner(text: "Máy đang rất nóng. Nên dừng thu và để máy nguội.", icon: "thermometer.high", level: .danger) }
        if route == .speaker && (monitorOn || isRecording) && !forceMonitor {
            return Banner(text: "Đang ra loa ngoài nên đã tắt tiếng giọng đã chỉnh để tránh hú. Cắm tai nghe để nghe.", icon: "speaker.slash.fill", level: .warn)
        }
        if route == .bluetooth && (monitorOn || isRecording) {
            return Banner(text: "Bluetooth bị trễ nhiều khi hát live. Nên dùng tai nghe có dây.", icon: "airpods", level: .warn)
        }
        return nil
    }

    var keyTitle: String {
        let s = settings
        return "\(noteNames[s.keyRoot]) \(s.scale == .custom ? "Custom" : s.scale.title)"
    }

    private var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var takesDir: URL { docs.appendingPathComponent("Takes", isDirectory: true) }
    private var beatsDir: URL { docs.appendingPathComponent("Beats", isDirectory: true) }
    private var lyricsDir: URL { docs.appendingPathComponent("Lyrics", isDirectory: true) }
    private var lyricsKey: String { "lyrics:" + (beatFileName ?? "none") }

    init() {
        if let data = UserDefaults.standard.data(forKey: "settings"), let s = TuneSettings.migrated(from: data) {
            settings = s
        }
        if let d = UserDefaults.standard.dictionary(forKey: "calibrations") as? [String: Double] { calibrations = d }
        for d in [takesDir, beatsDir, lyricsDir] { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        loadTakes()
        restoreBeat()
        observeSystem()
        adaptPerformance()
        evaluateRoute()
        MetricsCollector.shared.start()
        audio.onBeatEnded = { [weak self] in Task { @MainActor in self?.beatEnded() } }
    }

    func showToast(_ text: String, icon: String = "checkmark.circle.fill") {
        let t = Toast(text: text, icon: icon)
        toast = t
        Task {
            try? await Task.sleep(for: .seconds(3.5))
            if toast?.id == t.id { toast = nil }
        }
    }

    // MARK: Cài đặt

    func binding<T>(_ kp: WritableKeyPath<TuneSettings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: kp] },
                set: { self.settings[keyPath: kp] = $0; self.settingsChanged() })
    }

    func settingsChanged(keepPreset: Bool = false) {
        if !keepPreset { presetID = nil }
        pushToEngine()
        persistTask?.cancel()
        persistTask = Task { [settings] in
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            if let d = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(d, forKey: "settings") }
        }
    }

    func applyPreset(_ p: Preset) {
        var s = settings
        p.apply(&s)
        settings = s
        presetID = p.id
        settingsChanged(keepPreset: true)
    }

    func resetSettings() {
        var d = TuneSettings()
        let o = settings
        d.keyRoot = o.keyRoot; d.scale = o.scale; d.customMask = o.customMask; d.range = o.range
        d.autoKey = o.autoKey; d.bpm = o.bpm; d.countInBeats = o.countInBeats
        d.darkRecord = o.darkRecord; d.beatTranspose = o.beatTranspose
        settings = d
        applyPreset(Preset.all[0])
    }

    private func pushToEngine() {
        audio.apply(settings: settings, lowPower: saverMode, monitorAllowed: monitorAllowed)
    }

    // MARK: Beat: đổi key, nhịp

    func setBeatTranspose(_ v: Int) {
        let nv = max(-6, min(6, v))
        let delta = nv - settings.beatTranspose
        guard delta != 0 else { return }
        settings.beatTranspose = nv
        settings.keyRoot = ((settings.keyRoot + delta) % 12 + 12) % 12
        settings.customMask = Self.rotate(settings.customMask, by: delta)
        settingsChanged(keepPreset: true)
        showToast("Beat \(nv >= 0 ? "+" : "")\(nv) nửa cung · key \(keyTitle)", icon: "music.note")
    }

    private static func rotate(_ m: UInt16, by d: Int) -> UInt16 {
        let k = UInt32(((d % 12) + 12) % 12)
        let x = UInt32(m) & 0xFFF
        return UInt16(((x << k) | (x >> (12 - k))) & 0xFFF)
    }

    func scaleBPM(by f: Double) {
        settings.bpm = min(220, max(40, (settings.bpm * f * 10).rounded() / 10))
        settingsChanged(keepPreset: true)
    }

    // MARK: Engine

    private func ensureEngine() async -> Bool {
        if audio.isRunning { return true }
        let granted: Bool
        switch AVAudioApplication.shared.recordPermission {
        case .granted: granted = true
        case .denied: granted = false
        default: granted = await AVAudioApplication.requestRecordPermission()
        }
        guard granted else {
            errorOpensSettings = true
            errorMessage = "VocalTune cần quyền dùng micro để thu và chỉnh giọng. Bạn có thể bật lại trong Cài đặt."
            return false
        }
        do {
            try audio.start(settings: settings, lowPower: saverMode, bufferFrames: saverMode ? 256 : 128)
            evaluateRoute()
            refreshLatency()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func refreshLatency() {
        latencyText = audio.isRunning ? String(format: "≈ %.0f ms", audio.latencyMs) : "—"
    }

    private func releaseEngineIfIdle() {
        if !engineRunning && audio.isRunning { audio.stop(); latencyText = "—"; history.clear() }
    }

    func toggleMonitor() {
        if monitorOn { monitorOn = false; releaseEngineIfIdle(); return }
        Task { if await ensureEngine() { monitorOn = true } }
    }

    // MARK: Thu âm

    func toggleRecord() {
        if isRecording { stopRecording() } else { Task { await startRecording() } }
    }

    private func startRecording() async {
        guard await ensureEngine() else { return }
        let id = UUID()
        let dir = takesDir.appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try audio.startRecording(dryURL: dir.appendingPathComponent("dry.caf"),
                                     wetURL: dir.appendingPathComponent("wet.caf"))
        } catch {
            errorMessage = error.localizedDescription
            releaseEngineIfIdle()
            return
        }
        currentTakeDir = dir
        beatPreviewing = false
        audio.startBeat(countInBeats: settings.countInBeats, bpm: settings.bpm)
        let take = Take(id: id, date: Date(), duration: 0, settings: settings, beatFile: beatFileName,
                        latencyCompMs: audio.recordingCompensation * 1000, sampleRate: audio.sampleRate,
                        rendered: false, countInMs: audio.countInSeconds * 1000, inProgress: true, imported: false)
        currentTake = take
        writeMeta(take)                      // ghi ngay để còn khôi phục được nếu app bị tắt giữa chừng
        recordStart = Date()
        isRecording = true
        scheduleDark(after: 10)
    }

    private func stopRecording() {
        guard isRecording, var take = currentTake, let start = recordStart else { return }
        audio.stopRecording()
        audio.stopBeat()
        isRecording = false
        darkTask?.cancel(); darkActive = false
        take.duration = Date().timeIntervalSince(start)
        take.inProgress = false
        writeMeta(take)
        takes.insert(take, at: 0)
        currentTake = nil; currentTakeDir = nil; recordStart = nil
        releaseEngineIfIdle()
    }

    // MARK: Chế độ thu tối (tiết kiệm pin)

    private func scheduleDark(after seconds: Double) {
        darkTask?.cancel()
        guard settings.darkRecord, isRecording else { return }
        darkTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled && isRecording { darkActive = true }
        }
    }

    func wake() {
        darkActive = false
        scheduleDark(after: 20)
    }

    // MARK: Nhập file

    func requestImport(_ kind: ImportKind) {
        importKind = kind
        showImporter = true
    }

    var importTypes: [UTType] {
        switch importKind {
        case .beat: return [.audio]
        case .lyrics: return [.plainText, .text, UTType(filenameExtension: "lrc") ?? .data]
        case .vocal: return [.audio, .movie]
        }
    }

    func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let e): errorMessage = e.localizedDescription
        case .success(let url):
            switch importKind {
            case .beat: importBeat(url)
            case .lyrics: importLyrics(url)
            case .vocal: importVocal(url)
            }
        }
    }

    // MARK: Beat

    private func restoreBeat() {
        guard let name = UserDefaults.standard.string(forKey: "lastBeat") else { return }
        let url = beatsDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path), (try? audio.loadBeat(url)) != nil else { return }
        beatFileName = name
        beatName = url.deletingPathExtension().lastPathComponent
        restoreLyrics()
    }

    private func importBeat(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = beatsDir.appendingPathComponent(url.lastPathComponent)
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: url, to: dest)
            try audio.loadBeat(dest)
        } catch { errorMessage = "Không đọc được file nhạc nền: \(error.localizedDescription)"; return }
        beatFileName = dest.lastPathComponent
        beatName = url.deletingPathExtension().lastPathComponent
        UserDefaults.standard.set(beatFileName, forKey: "lastBeat")
        settings.beatTranspose = 0
        lyrics = nil; lyricsName = nil
        restoreLyrics()
        analyzeBeat(dest)
    }

    func redetectKey() {
        guard let f = beatFileName else { return }
        analyzeBeat(beatsDir.appendingPathComponent(f), force: true)
    }

    private func analyzeBeat(_ url: URL, force: Bool = false) {
        let ref = Float(settings.refA4)
        Task {
            let a = await Task.detached(priority: .utility) { KeyDetector.analyze(url: url, refA4: ref) }.value
            var parts: [String] = []
            if let r = a.key, (settings.autoKey && r.confidence >= 0.5) || force {
                settings.keyRoot = (r.root + settings.beatTranspose + 12) % 12
                settings.scale = r.minor ? .minor : .major
                parts.append("key \(keyTitle)")
            }
            if let b = a.bpm, a.bpmConfidence > 0.1 {
                settings.bpm = (Double(b) * 10).rounded() / 10
                parts.append("\(Int(settings.bpm.rounded())) BPM")
            }
            settingsChanged(keepPreset: true)
            showToast(parts.isEmpty ? "Chưa nhận được key và nhịp. Hãy đặt thủ công." : "Đã nhận " + parts.joined(separator: " · "),
                      icon: parts.isEmpty ? "questionmark.circle" : "checkmark.circle.fill")
        }
    }

    func removeBeat() {
        beatPreviewing = false
        audio.stopBeat()
        try? audio.loadBeat(nil)
        beatFileName = nil; beatName = nil
        lyrics = nil; lyricsName = nil
        UserDefaults.standard.removeObject(forKey: "lastBeat")
        releaseEngineIfIdle()
    }

    func toggleBeatPreview() {
        if beatPreviewing {
            beatPreviewing = false; audio.stopBeat(); releaseEngineIfIdle()
        } else {
            Task {
                guard await ensureEngine() else { return }
                beatPreviewing = true
                audio.startBeat()
            }
        }
    }

    private func beatEnded() {
        beatPreviewing = false
        releaseEngineIfIdle()
    }

    // MARK: Lời bài hát

    private func importLyrics(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? String(data: data, encoding: .isoLatin1)
        else { errorMessage = "Không đọc được file lời bài hát."; return }
        let dest = lyricsDir.appendingPathComponent(UUID().uuidString + ".txt")
        try? text.write(to: dest, atomically: true, encoding: .utf8)
        UserDefaults.standard.set(dest.lastPathComponent, forKey: lyricsKey)
        let l = Lyrics.parse(text)
        lyrics = l
        lyricsName = url.deletingPathExtension().lastPathComponent
        showToast(l.isTimed ? "Đã thêm lời (có mốc thời gian, sẽ chạy theo beat)" : "Đã thêm lời (không có mốc thời gian)")
    }

    private func restoreLyrics() {
        guard let name = UserDefaults.standard.string(forKey: lyricsKey),
              let text = try? String(contentsOf: lyricsDir.appendingPathComponent(name), encoding: .utf8) else { return }
        lyrics = Lyrics.parse(text)
        lyricsName = beatName
    }

    func removeLyrics() {
        UserDefaults.standard.removeObject(forKey: lyricsKey)
        lyrics = nil; lyricsName = nil
    }

    // MARK: Bản thu

    private func loadTakes() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: takesDir, includingPropertiesForKeys: nil)) ?? []
        var recovered = 0
        var list: [Take] = []
        for d in dirs {
            guard let data = try? Data(contentsOf: d.appendingPathComponent("meta.json")), var t = Take.migrated(from: data) else { continue }
            if t.inProgress == true {
                // App bị tắt giữa lúc thu: cắt file theo độ dài thực có và đánh dấu hoàn tất
                if let f = try? AVAudioFile(forReading: d.appendingPathComponent("dry.caf")), f.length > 0 {
                    t.duration = Double(f.length) / f.processingFormat.sampleRate
                    t.inProgress = false
                    if let enc = try? JSONEncoder().encode(t) { try? enc.write(to: d.appendingPathComponent("meta.json")) }
                    recovered += 1
                } else {
                    try? FileManager.default.removeItem(at: d)
                    continue
                }
            }
            list.append(t)
        }
        takes = list.sorted { $0.date > $1.date }
        if recovered > 0 {
            Task { showToast("Đã khôi phục \(recovered) bản thu bị gián đoạn", icon: "arrow.counterclockwise") }
        }
    }

    private func dir(_ t: Take) -> URL { takesDir.appendingPathComponent(t.id.uuidString, isDirectory: true) }

    private func writeMeta(_ t: Take) {
        if let d = try? JSONEncoder().encode(t) { try? d.write(to: dir(t).appendingPathComponent("meta.json")) }
    }

    func delete(_ t: Take) {
        try? FileManager.default.removeItem(at: dir(t))
        takes.removeAll { $0.id == t.id }
    }

    func rerender(_ t: Take) {
        let d = dir(t), s = settings
        busyText = "Đang render lại…"
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try OfflineRenderer.render(dryURL: d.appendingPathComponent("dry.caf"),
                                               wetURL: d.appendingPathComponent("wet.caf"),
                                               settings: s) { p in
                        Task { @MainActor in self.busyText = "Đang render lại… \(Int(p * 100))%" }
                    }
                }.value
                if let i = takes.firstIndex(where: { $0.id == t.id }) {
                    takes[i].settings = s; takes[i].rendered = true; writeMeta(takes[i])
                }
            } catch { errorMessage = error.localizedDescription }
            busyText = nil
        }
    }

    func importVocal(_ url: URL) {
        let id = UUID()
        let d = takesDir.appendingPathComponent(id.uuidString, isDirectory: true)
        let s = settings
        busyText = "Đang nhập file giọng…"
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
                let dry = d.appendingPathComponent("dry.caf"), wet = d.appendingPathComponent("wet.caf")
                let dur = try await VocalImporter.convert(url: url, to: dry)
                busyText = "Đang chỉnh giọng…"
                try await Task.detached(priority: .userInitiated) {
                    try OfflineRenderer.render(dryURL: dry, wetURL: wet, settings: s) { p in
                        Task { @MainActor in self.busyText = "Đang chỉnh giọng… \(Int(p * 100))%" }
                    }
                }.value
                let take = Take(id: id, date: Date(), duration: dur, settings: s, beatFile: nil, latencyCompMs: 0,
                                sampleRate: 48000, rendered: true, countInMs: 0, inProgress: false, imported: true)
                writeMeta(take)
                takes.insert(take, at: 0)
                showToast("Đã nhập và chỉnh giọng")
            } catch {
                errorMessage = error.localizedDescription
                try? FileManager.default.removeItem(at: d)
            }
            busyText = nil
        }
    }

    /// Mix ra file (gối beat nếu có). Trả về URL tạm để chia sẻ hoặc nghe thử.
    func mixFile(_ t: Take, format: ExportFormat) async throws -> URL {
        let d = dir(t)
        let beatURL = t.beatFile.map { beatsDir.appendingPathComponent($0) }
        let beat = (beatURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false) ? beatURL : nil
        let name = "VocalTune \(t.date.formatted(.dateTime.year().month().day().hour().minute())).\(format.rawValue)"
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        // Giọng trong file chậm hơn beat một đoạn: phần đếm nhịp + độ trễ vòng. Kéo giọng lên sớm hơn.
        let shift = -(t.countInMs ?? 0) - t.latencyCompMs + exportNudgeMs
        let (vg, bg) = (Float(t.settings.vocalGain), Float(t.settings.beatGain))
        let cents = Float(t.settings.beatTranspose * 100)
        busyText = "Đang mix…"
        defer { busyText = nil }
        try await Task.detached(priority: .userInitiated) {
            try Exporter.mix(vocalURL: d.appendingPathComponent("wet.caf"), beatURL: beat,
                             vocalGain: vg, beatGain: bg, shiftMs: shift, beatPitchCents: cents,
                             format: format, to: out) { _ in }
        }.value
        return out
    }

    func export(_ t: Take, _ format: ExportFormat) {
        Task {
            do { shareURL = try await mixFile(t, format: format) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func togglePlay(_ t: Take) {
        if playingTake == t.id { player?.stop(); playingTake = nil; return }
        Task {
            do {
                if audio.isRunning { monitorOn = false; beatPreviewing = false; audio.stop() }
                let url = try await mixFile(t, format: .m4a)
                try AVAudioSession.sharedInstance().setCategory(.playback)
                try AVAudioSession.sharedInstance().setActive(true)
                player = try AVAudioPlayer(contentsOf: url)
                player?.play()
                playingTake = t.id
            } catch { errorMessage = error.localizedDescription }
        }
    }

    // MARK: Hiệu chuẩn độ trễ

    func startCalibration() {
        guard !calibrating, !isRecording else { return }
        Task {
            guard await ensureEngine() else { return }
            calibrating = true
            calib = .running(0)
            audio.calibStart()
            while audio.calibProgress < 1 {
                try? await Task.sleep(for: .milliseconds(100))
                calib = .running(audio.calibProgress)
            }
            let r = audio.calibResult()
            audio.calibStop()
            calibrating = false
            pushToEngine()
            if let r, r.conf >= 0.5, r.ms > 1, r.ms < 400 {
                calibrations[routeUID] = r.ms
                UserDefaults.standard.set(calibrations, forKey: "calibrations")
                audio.measuredRoundTrip = r.ms / 1000
                refreshLatency()
                calib = .done(ms: r.ms, conf: r.conf)
            } else {
                calib = .failed
            }
            releaseEngineIfIdle()
        }
    }

    func clearCalibration() {
        calibrations[routeUID] = nil
        UserDefaults.standard.set(calibrations, forKey: "calibrations")
        audio.measuredRoundTrip = nil
        calib = .idle
        refreshLatency()
    }

    // MARK: Chẩn đoán

    func diagnosticsReport() -> String {
        let d = audio.diag()
        let p = ProcessInfo.processInfo
        let thermal: String
        switch p.thermalState {
        case .nominal: thermal = "bình thường"
        case .fair: thermal = "hơi ấm"
        case .serious: thermal = "nóng"
        case .critical: thermal = "rất nóng"
        @unknown default: thermal = "?"
        }
        return """
        VocalTune chẩn đoán
        Engine: \(audio.isRunning ? "đang chạy" : "tắt")
        Sample rate: \(Int(audio.sampleRate)) Hz
        IO buffer: \(String(format: "%.1f", audio.sessionBufferMs)) ms (block \(d.lastFrames))
        Độ trễ DSP: \(String(format: "%.1f", Double(d.latencySamples) / max(1, audio.sampleRate) * 1000)) ms
        Độ trễ vòng: \(String(format: "%.1f", audio.roundTripSeconds * 1000)) ms (\(calibMs != nil ? "đã hiệu chuẩn" : "ước tính"))
        CPU DSP: \(String(format: "%.2f", d.cpuLoad * 100))% (đỉnh \(String(format: "%.2f", d.peakLoad * 100))%)
        Underrun: \(d.underruns) / \(d.blocks) block
        Nhiệt: \(thermal) · Low Power: \(p.isLowPowerModeEnabled ? "bật" : "tắt") · Tiết kiệm: \(saverMode ? "bật" : "tắt")
        Đầu ra: \(routeName.isEmpty ? route.title : routeName)
        MetricKit: \(UserDefaults.standard.string(forKey: "metrics.summary") ?? "chưa có dữ liệu (iOS gửi mỗi ngày một lần)")
        """
    }

    // MARK: Hệ thống: route, ngắt quãng, nhiệt, pin

    func sceneChanged(active: Bool) {
        if !active && !isRecording && !calibrating {
            monitorOn = false; beatPreviewing = false
            player?.stop(); playingTake = nil
            releaseEngineIfIdle()
        }
    }

    private func evaluateRoute() {
        let out = AVAudioSession.sharedInstance().currentRoute.outputs.first
        routeUID = out?.uid ?? "default"
        routeName = out?.portName ?? ""
        switch out?.portType {
        case .builtInSpeaker?, .builtInReceiver?: route = .speaker
        case .bluetoothA2DP?, .bluetoothLE?, .bluetoothHFP?: route = .bluetooth
        default: route = .wired
        }
        audio.measuredRoundTrip = calibMs.map { $0 / 1000 }
        refreshLatency()
        pushToEngine()
    }

    private func adaptPerformance() {
        let state = ProcessInfo.processInfo.thermalState
        let saver = state.rawValue >= ProcessInfo.ThermalState.serious.rawValue || ProcessInfo.processInfo.isLowPowerModeEnabled
        thermalCritical = state == .critical
        if saver != saverMode {
            saverMode = saver
            if audio.isRunning { audio.setBufferFrames(saver ? 256 : 128) }
            pushToEngine()
        }
    }

    private func observeSystem() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.evaluateRoute() }
        }
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in
                guard let self else { return }
                if self.isRecording { self.stopRecording() }
                self.monitorOn = false; self.beatPreviewing = false; self.calibrating = false
                self.releaseEngineIfIdle()
            }
        }
        nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.adaptPerformance() }
        }
        nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.adaptPerformance() }
        }
    }

    // MARK: Telemetry cho UI

    func pullTelemetry() {
        guard audio.isRunning else { return }
        history.push(audio.telemetry())
    }
}
