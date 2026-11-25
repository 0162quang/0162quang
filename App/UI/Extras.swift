import SwiftUI

// MARK: Chế độ thu tối: màn hình gần như đen để tiết kiệm pin khi hát lâu

struct DarkRecordView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { model.wake() }
            VStack(spacing: 28) {
                Spacer()
                if let start = model.recordStart {
                    TimelineView(.periodic(from: start, by: 1)) { ctx in
                        let s = max(0, Int(ctx.date.timeIntervalSince(start)))
                        Text(String(format: "%02d:%02d", s / 60, s % 60))
                            .font(.system(size: 56, weight: .light, design: .rounded)).monospacedDigit()
                            .foregroundStyle(Theme.rec.opacity(0.75))
                    }
                }
                // Mức mic, cập nhật 4 lần/giây
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    let lv = CGFloat(min(1, model.audio.telemetry().level))
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.08))
                            Capsule().fill(lv > 0.95 ? Theme.rec : Theme.good.opacity(0.7)).frame(width: max(4, g.size.width * lv))
                        }
                    }
                    .frame(width: 220, height: 6)
                }
                Text("Chạm vào màn hình để bật lại").font(.system(size: 14)).foregroundStyle(Color.white.opacity(0.35))
                Spacer()
                Button { model.toggleRecord() } label: {
                    Label("Dừng thu", systemImage: "stop.fill")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.rec)
                        .frame(width: 200, height: 56)
                        .overlay(Capsule().stroke(Theme.rec.opacity(0.6), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 24)
            }
        }
        .accessibilityLabel("Đang thu. Chạm để bật lại màn hình")
    }
}

// MARK: Đếm nhịp trước khi thu

struct CountInOverlay: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            if let n = model.audio.countInNumber {
                Text("\(n)")
                    .font(.system(size: 110, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Theme.gradient)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .transition(.opacity)
                    .accessibilityLabel("Đếm nhịp \(n)")
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: Lời bài hát

struct LyricsStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.sheet = .lyrics } label: {
            TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                let (cur, next) = lines()
                VStack(alignment: .leading, spacing: 3) {
                    Text(cur).font(.system(size: 19, weight: .bold, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.7)
                    Text(next).font(.system(size: 14)).foregroundStyle(Theme.textDim).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14).frame(height: 68).card()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Lời bài hát. Chạm để xem toàn bộ")
    }

    private func lines() -> (String, String) {
        guard let l = model.lyrics, !l.lines.isEmpty else { return ("", "") }
        guard l.isTimed else { return (l.lines[0].text, l.lines.count > 1 ? l.lines[1].text : "Chạm để xem toàn bộ lời") }
        let playing = model.beatPreviewing || model.isRecording
        let t = model.audio.beatTime
        guard playing, let i = l.index(at: t) else { return ("♪", l.lines[0].text) }
        return (l.lines[i].text, i + 1 < l.lines.count ? l.lines[i + 1].text : "")
    }
}

struct LyricsSheet: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: model.lyricsName ?? "Lời bài hát") { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.lyrics?.lines ?? []) { line in
                        Text(line.text).font(.system(size: 20, weight: .medium, design: .rounded)).foregroundStyle(Theme.text)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
        }
    }
}

// MARK: Chẩn đoán

struct DiagnosticsSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Chẩn đoán") { EmptyView() }
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let text = model.diagnosticsReport()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(text).font(.system(size: 14, design: .monospaced)).foregroundStyle(Theme.text)
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            .padding(14).card()
                        Text("CPU DSP là thời gian xử lý chia cho thời lượng mỗi buffer. Dưới 12% là tốt. Underrun tăng nghĩa là âm thanh bị rè hoặc ngắt.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                        ShareLink(item: text) {
                            Chip(icon: "square.and.arrow.up", text: "Chia sẻ báo cáo", tint: Theme.accent)
                        }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 24)
                }
            }
        }
    }
}

// MARK: Hiệu chuẩn độ trễ

struct CalibrationSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Hiệu chuẩn độ trễ").font(.system(size: 22, weight: .bold, design: .rounded)).padding(.top, 14)
                Text("Để giọng khớp đúng nhịp beat khi mix, app cần biết thật chính xác từ lúc phát âm đến lúc mic nghe được.")
                    .font(.system(size: 15)).foregroundStyle(Theme.textDim)

                VStack(alignment: .leading, spacing: 10) {
                    step("1", "Đeo tai nghe đang dùng để hát và tăng âm lượng vừa phải.")
                    step("2", "Áp loa tai nghe sát micro dưới của điện thoại (hoặc để điện thoại phát ra loa ngoài).")
                    step("3", "Bấm Bắt đầu. App phát 6 tiếng click trong khoảng 4 giây, giữ yên.")
                }
                .padding(14).card()

                Text("Đầu ra: \(model.routeName.isEmpty ? model.route.title : model.routeName)")
                    .font(.system(size: 13)).foregroundStyle(Theme.textDim)

                switch model.calib {
                case .idle:
                    if let ms = model.calibMs {
                        Label("Đã lưu: \(String(format: "%.1f", ms)) ms cho đầu ra này", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.good).font(.system(size: 15, weight: .semibold))
                    }
                case .running(let p):
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: p).tint(Theme.accent)
                        Text("Đang đo… giữ yên điện thoại").font(.system(size: 14)).foregroundStyle(Theme.textDim)
                    }
                case .done(let ms, let conf):
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Độ trễ vòng \(String(format: "%.1f", ms)) ms", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.good).font(.system(size: 17, weight: .bold))
                        Text("Độ tin cậy \(Int(conf * 100))%. Đã lưu cho đầu ra này.").font(.system(size: 13)).foregroundStyle(Theme.textDim)
                    }
                case .failed:
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Không nghe thấy tiếng click", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warn).font(.system(size: 16, weight: .bold))
                        Text("Tăng âm lượng, áp loa tai nghe sát micro hơn và đo ở nơi yên tĩnh.").font(.system(size: 13)).foregroundStyle(Theme.textDim)
                    }
                }

                HStack(spacing: 10) {
                    Button { model.startCalibration() } label: {
                        Chip(icon: "metronome", text: model.calibMs == nil ? "Bắt đầu đo" : "Đo lại", tint: Theme.accent, filled: true)
                    }
                    .buttonStyle(.plain).disabled(model.calibrating || model.isRecording)
                    if model.calibMs != nil {
                        Button { model.clearCalibration() } label: { Chip(icon: "arrow.uturn.backward", text: "Dùng số ước tính", tint: Theme.textDim) }
                            .buttonStyle(.plain).disabled(model.calibrating)
                    }
                }
                Text("Mỗi loại tai nghe có độ trễ khác nhau, hãy đo lại khi đổi tai nghe.").font(.system(size: 12)).foregroundStyle(Theme.textDim)
            }
            .padding(.horizontal, 20).padding(.bottom, 24)
        }
    }

    private func step(_ n: String, _ t: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(n).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(.black)
                .frame(width: 24, height: 24).background(Theme.accent, in: Circle())
            Text(t).font(.system(size: 15)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
