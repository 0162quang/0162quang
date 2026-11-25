#include "VocalDSP.h"
#include "VocalDSPCore.hpp"
#include <chrono>
#include <memory>

using namespace vt;

namespace {

constexpr int kClick = 96;      // độ dài tiếng click hiệu chuẩn (mẫu)
constexpr int kClicks = 6;

struct Engine {
    Engine(float sr, int range) : sr_(sr), mon_(1 << 15), dry_(1 << 19), wet_(1 << 19) {
        static const float fmin[3] = {80.f, 110.f, 160.f};
        tmax_ = (int)std::ceil(sr / fmin[std::max(0, std::min(2, range))]);
        det_.prepare(sr);
        psola_.prepare(tmax_);
        gate_.prepare(sr); comp_.prepare(sr); reverb_.prepare(sr); delay_.prepare(sr); deEss_.prepare(sr);
        hpf_.highpass(sr, 80.f, 0.7071f);
        hpfSib_.highpass(sr, 4500.f, 0.7071f);
        scratch_.assign(4096, 0.f);
        calBuf_.assign((size_t)(sr * 5.f), 0.f);
        vt_default_params(&slots_[0]); slots_[1] = slots_[0];
    }

    void setParams(const VTParams& in) {
        VTParams p = in;
        p.retuneMs = clampf(p.retuneMs, 0.f, 400.f);
        p.amount = clampf(p.amount, 0.f, 1.f);
        p.formant = clampf(p.formant, 0.8f, 1.26f);
        p.refA4 = clampf(p.refA4, 415.f, 466.f);
        p.deEss = clampf(p.deEss, 0.f, 1.f);
        p.eqLowDb = clampf(p.eqLowDb, -9.f, 9.f);
        p.eqPresenceDb = clampf(p.eqPresenceDb, -9.f, 9.f);
        p.eqAirDb = clampf(p.eqAirDb, -9.f, 9.f);
        const int next = 1 - active_.load(std::memory_order_relaxed);
        slots_[next] = p;
        active_.store(next, std::memory_order_release);
    }

    int latency() const { return psola_.latency(); }

    void reset() {
        det_.reset(); psola_.reset(); tuner_.reset();
        hpf_.z1 = hpf_.z2 = 0; hang_ = 0; hasLast_ = false; stable_ = 0; jump_ = 0;
    }

    void updateEq(const VTParams& p) {
        if (p.eqLowDb == eqL_ && p.eqPresenceDb == eqP_ && p.eqAirDb == eqA_) return;
        eqL_ = p.eqLowDb; eqP_ = p.eqPresenceDb; eqA_ = p.eqAirDb;
        eq_[0].lowShelf(sr_, 150.f, eqL_);
        eq_[1].peaking(sr_, 3500.f, 0.9f, eqP_);
        eq_[2].highShelf(sr_, 10000.f, eqA_);
    }

    void onHop(const Estimate& e, const VTParams& p) {
        const float minF = sr_ / (float)tmax_;
        const float hfRatio = totE_ > 1e-12f ? hfE_ / totE_ : 0.f;
        bool voiced = e.voiced && e.f0 >= minF && e.f0 <= 1000.f;
        if (voiced && hfRatio > 0.5f && e.cmnd > 0.05f) voiced = false;  // âm xì (s, sh, t)
        if (voiced) {
            const float m = 69.f + 12.f * std::log2(e.f0 / p.refA4);
            // Bước nhảy lớn (nghi lỗi octave): chờ xác nhận qua 3 hop
            if (hasLast_ && std::fabs(m - lastM_) > 6.f && jump_ < 2) { ++jump_; return; }
            jump_ = 0;
            stable_ = (hasLast_ && std::fabs(m - lastM_) < 0.25f) ? std::min(stable_ + 1, 100) : 0;
            lastM_ = m; hasLast_ = true; hang_ = 0;
            const Tuner::Out o = tuner_.update(e.f0, p, det_.hopSeconds());
            if (p.bypass) {
                psola_.setVoiced(false);
            } else {
                const float ratio = clampf(std::pow(2.f, o.shift / 12.f), 0.5f, 2.f);
                psola_.setControl(sr_ / e.f0, true, ratio, p.formant);
            }
            tIn_.store(o.inMidi, std::memory_order_relaxed);
            tOut_.store(o.inMidi + o.shift, std::memory_order_relaxed);
            tTarget_.store(o.target, std::memory_order_relaxed);
            tVoiced_.store(1, std::memory_order_relaxed);
        } else if (++hang_ > 2) {
            psola_.setVoiced(false);
            tuner_.reset();
            hasLast_ = false; stable_ = 0; jump_ = 0;
            tVoiced_.store(0, std::memory_order_relaxed);
        }
    }

    void process(const float* in, float* out, int n) {
        const VTParams p = slots_[active_.load(std::memory_order_acquire)];
        // Hop thích ứng: ổn định thì thưa hơn để tiết kiệm CPU
        float hop = stable_ >= 4 ? 12.f : 8.f;
        if (p.lowPower) hop += 4.f;
        det_.setHopMs(hop);
        updateEq(p);
        const float inG = dbToLin(p.inputGainDb), outG = dbToLin(p.outputGainDb);
        const float gateThr = dbToLin(p.gateDb);
        const bool gateOn = p.gateDb > -80.f;
        const bool revOn = !p.lowPower && p.reverbMix > 0.002f;
        const bool dlyOn = !p.lowPower && p.delayMix > 0.002f;
        const bool eqOn = std::fabs(p.eqLowDb) > 0.1f || std::fabs(p.eqPresenceDb) > 0.1f || std::fabs(p.eqAirDb) > 0.1f;
        float peak = 0.f;
        for (int i = 0; i < n; ++i) {
            const float x = in[i] * inG;
            peak = std::max(peak, std::fabs(x));
            const float h = hpf_.process(x);
            const float g = gateOn ? gate_.process(h, gateThr) : h;
            const float hf = hpfSib_.process(g);
            hfE_ += hf * hf; totE_ += g * g;
            Estimate e;
            if (det_.push(g, e)) { onHop(e, p); hfE_ = 0.f; totE_ = 0.f; }
            float y = psola_.process1(g);
            y = deEss_.process(y, p.deEss);
            if (eqOn) y = eq_[2].process(eq_[1].process(eq_[0].process(y)));
            y = comp_.process(y, p.compAmount);
            float s = y;
            if (revOn) s += reverb_.process(y, p.reverbSize) * p.reverbMix * 2.0f;
            if (dlyOn) s += delay_.process(y, p.delayMs, p.delayFeedback) * p.delayMix;
            out[i] = softClip(s * outG);
        }
        tLevel_.store(peak, std::memory_order_relaxed);
    }

    // ---- Realtime I/O

    void capture(const float* in, int n) {
        const auto t0 = std::chrono::steady_clock::now();
        if (calActive_.load(std::memory_order_acquire)) { calCapture(in, n); return; }
        const int total = n;
        while (n > 0) {
            const int c = std::min(n, (int)scratch_.size());
            process(in, scratch_.data(), c);
            mon_.write(scratch_.data(), (size_t)c);
            if (recording_.load(std::memory_order_acquire)) {
                dry_.write(in, (size_t)c);
                const int skip = wetSkip_.load(std::memory_order_relaxed);
                if (skip > 0) {
                    const int s = std::min(skip, c);
                    wetSkip_.store(skip - s, std::memory_order_relaxed);
                    if (c > s) wet_.write(scratch_.data() + s, (size_t)(c - s));
                } else {
                    wet_.write(scratch_.data(), (size_t)c);
                }
            }
            in += c; n -= c;
        }
        const double dt = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        const float load = (float)(dt / ((double)total / (double)sr_));
        cpu_ = cpu_ * 0.95f + load * 0.05f;
        peakLoad_ = std::max(peakLoad_ * 0.998f, load);
        cpuA_.store(cpu_, std::memory_order_relaxed);
        peakA_.store(peakLoad_, std::memory_order_relaxed);
        lastFrames_.store(total, std::memory_order_relaxed);
        blocks_.fetch_add(1, std::memory_order_relaxed);
    }

    int monitor(float* out, int n) {
        if (calActive_.load(std::memory_order_acquire)) { calRender(out, n); return n; }
        const size_t avail = mon_.avail();
        if (avail > (size_t)n * 2) mon_.skip(avail - (size_t)n);
        const int got = (int)mon_.read(out, (size_t)n);
        for (int i = got; i < n; ++i) out[i] = 0.f;
        if (got < n && blocks_.load(std::memory_order_relaxed) > 3) underruns_.fetch_add(1, std::memory_order_relaxed);
        return got;
    }

    void setRecording(int on) {
        if (on) {
            dry_.skip(dry_.avail()); wet_.skip(wet_.avail());
            wetSkip_.store(latency(), std::memory_order_relaxed);
            recording_.store(true, std::memory_order_release);
        } else {
            recording_.store(false, std::memory_order_release);
        }
    }

    // ---- Hiệu chuẩn độ trễ vòng

    void calStart() {
        calActive_.store(false, std::memory_order_release);
        std::fill(calBuf_.begin(), calBuf_.end(), 0.f);
        calCap_.store(0); calOut_ = 0;
        for (auto& v : calClickCap_) v = -1;
        calActive_.store(true, std::memory_order_release);
    }
    void calStop() { calActive_.store(false, std::memory_order_release); }
    float calProgress() const { return clampf((float)calCap_.load() / (sr_ * 3.8f), 0.f, 1.f); }

    void calCapture(const float* in, int n) {
        const int64_t idx = calCap_.load();
        const int64_t room = (int64_t)calBuf_.size() - idx;
        if (room > 0) std::memcpy(calBuf_.data() + idx, in, (size_t)std::min<int64_t>(room, n) * sizeof(float));
        calCap_.store(idx + n);
    }

    void calRender(float* out, int n) {
        const int64_t capNow = calCap_.load();
        for (int j = 0; j < n; ++j) {
            out[j] = 0.f;
            const int64_t g = calOut_ + j;
            for (int i = 0; i < kClicks; ++i) {
                const int64_t t0 = (int64_t)((0.3f + 0.5f * (float)i) * sr_);
                if (g >= t0 && g < t0 + kClick) {
                    const int k = (int)(g - t0);
                    if (k == 0) calClickCap_[i] = capNow + j;
                    const float w = 0.5f * (1.f - std::cos(2.f * kPi * (float)k / (float)(kClick - 1)));
                    out[j] = 0.9f * w * std::sin(2.f * kPi * 1500.f * (float)k / sr_);
                }
            }
        }
        calOut_ += n;
    }

    bool calResult(float* ms, float* conf) {
        const int64_t have = std::min<int64_t>(calCap_.load(), (int64_t)calBuf_.size());
        std::vector<int64_t> delays;
        // nền nhiễu: trung vị |x| trước click đầu
        std::vector<float> pre;
        const int64_t preEnd = std::max<int64_t>(256, calClickCap_[0] > 0 ? calClickCap_[0] : (int64_t)(0.25f * sr_));
        for (int64_t i = 64; i < std::min(preEnd, have); i += 4) pre.push_back(std::fabs(calBuf_[(size_t)i]));
        float noise = 0.f;
        if (!pre.empty()) { std::nth_element(pre.begin(), pre.begin() + pre.size() / 2, pre.end()); noise = pre[pre.size() / 2]; }
        const int64_t win = (int64_t)(0.25f * sr_);
        for (int i = 0; i < kClicks; ++i) {
            const int64_t c0 = calClickCap_[i];
            if (c0 < 0 || c0 + win > have) continue;
            float pk = 0.f;
            for (int64_t k = 0; k < win; ++k) pk = std::max(pk, std::fabs(calBuf_[(size_t)(c0 + k)]));
            if (pk < std::max(6.f * noise, 0.003f)) continue;
            int64_t onset = -1;
            for (int64_t k = 0; k < win; ++k) if (std::fabs(calBuf_[(size_t)(c0 + k)]) > 0.35f * pk) { onset = k; break; }
            if (onset >= 0) delays.push_back(onset - 18);   // 18 mẫu: bù đoạn tăng đầu của click
        }
        if (delays.empty()) return false;
        std::sort(delays.begin(), delays.end());
        const int64_t med = delays[delays.size() / 2];
        *ms = (float)med * 1000.f / sr_;
        *conf = (float)delays.size() / (float)kClicks;
        return true;
    }

    float sr_;
    int tmax_ = 400;
    PitchDetector det_;
    Tuner tuner_;
    Psola psola_;
    Gate gate_; Comp comp_; Reverb reverb_; Delay delay_; DeEsser deEss_;
    Biquad hpf_, hpfSib_, eq_[3];
    float eqL_ = 0, eqP_ = 0, eqA_ = 0;
    Ring mon_, dry_, wet_;
    std::vector<float> scratch_, calBuf_;
    VTParams slots_[2];
    std::atomic<int> active_{0};
    std::atomic<bool> recording_{false};
    std::atomic<int> wetSkip_{0};
    std::atomic<float> tIn_{60.f}, tOut_{60.f}, tTarget_{60.f}, tLevel_{0.f};
    std::atomic<int> tVoiced_{0};
    int hang_ = 0, jump_ = 0, stable_ = 0;
    bool hasLast_ = false;
    float lastM_ = 60.f, hfE_ = 0.f, totE_ = 0.f;
    // chẩn đoán
    float cpu_ = 0.f, peakLoad_ = 0.f;
    std::atomic<float> cpuA_{0.f}, peakA_{0.f};
    std::atomic<int> underruns_{0}, blocks_{0}, lastFrames_{0};
    // hiệu chuẩn
    std::atomic<bool> calActive_{false};
    std::atomic<int64_t> calCap_{0};
    int64_t calOut_ = 0;
    int64_t calClickCap_[kClicks] = {-1, -1, -1, -1, -1, -1};
};

inline Engine* E(void* h) { return static_cast<Engine*>(h); }

} // namespace

extern "C" {

void* vt_create(float sr, int32_t range) { return new Engine(sr, range); }
void vt_destroy(void* h) { delete E(h); }

void vt_default_params(VTParams* p) {
    std::memset(p, 0, sizeof(VTParams));
    p->retuneMs = 80.f; p->amount = 1.f; p->flexCents = 0.f; p->vibratoKeep = 1.f;
    p->formant = 1.f; p->refA4 = 440.f; p->noteMask = 0xFFFu; p->manualNote = -1;
    p->gateDb = -80.f; p->compAmount = 0.f; p->reverbSize = 0.5f;
    p->delayMs = 320.f; p->delayFeedback = 0.3f;
}

void vt_set_params(void* h, const VTParams* p) { E(h)->setParams(*p); }
int32_t vt_latency(void* h) { return E(h)->latency(); }
void vt_reset(void* h) { E(h)->reset(); }
void vt_capture(void* h, const float* in, int32_t n) { E(h)->capture(in, n); }
int32_t vt_monitor(void* h, float* out, int32_t n) { return E(h)->monitor(out, n); }
void vt_set_recording(void* h, int32_t on) { E(h)->setRecording(on); }
int32_t vt_read_dry(void* h, float* d, int32_t m) { return (int32_t)E(h)->dry_.read(d, (size_t)m); }
int32_t vt_read_wet(void* h, float* d, int32_t m) { return (int32_t)E(h)->wet_.read(d, (size_t)m); }

void vt_process(void* h, const float* in, float* out, int32_t n) {
    Engine* e = E(h);
    int32_t done = 0;
    while (done < n) {
        const int32_t c = std::min<int32_t>(n - done, 4096);
        e->process(in + done, out + done, c);
        done += c;
    }
}

void vt_get_telemetry(void* h, VTTelemetry* t) {
    Engine* e = E(h);
    t->inMidi = e->tIn_.load(std::memory_order_relaxed);
    t->outMidi = e->tOut_.load(std::memory_order_relaxed);
    t->targetMidi = e->tTarget_.load(std::memory_order_relaxed);
    t->level = e->tLevel_.load(std::memory_order_relaxed);
    t->voiced = e->tVoiced_.load(std::memory_order_relaxed);
}

void vt_get_diag(void* h, VTDiag* d) {
    Engine* e = E(h);
    d->cpuLoad = e->cpuA_.load(std::memory_order_relaxed);
    d->peakLoad = e->peakA_.load(std::memory_order_relaxed);
    d->underruns = e->underruns_.load(std::memory_order_relaxed);
    d->blocks = e->blocks_.load(std::memory_order_relaxed);
    d->lastFrames = e->lastFrames_.load(std::memory_order_relaxed);
    d->latencySamples = e->latency();
}

void vt_calib_start(void* h) { E(h)->calStart(); }
void vt_calib_stop(void* h) { E(h)->calStop(); }
float vt_calib_progress(void* h) { return E(h)->calProgress(); }
int32_t vt_calib_result(void* h, float* ms, float* conf) { return E(h)->calResult(ms, conf) ? 1 : 0; }

} // extern "C"
