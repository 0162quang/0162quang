// Nhận key bằng chroma (Goertzel trên 36 nốt C3..B5) + hồ sơ Krumhansl-Schmuckler.
#include "VocalDSP.h"
#include <cmath>
#include <vector>

extern "C" int32_t vt_detect_key(const float* x, int32_t n, float sr, float refA4,
                                 int32_t* root, int32_t* isMinor, float* confidence) {
    if (!x || sr < 8000.f) return 0;
    const int dec = sr >= 32000.f ? 2 : 1;
    const float fs = sr / (float)dec;
    const int B = 4096;
    const int m = n / dec;
    if (m < B * 4) return 0;

    std::vector<float> d((size_t)m);
    for (int i = 0; i < m; ++i) {
        float s = 0; for (int k = 0; k < dec; ++k) s += x[i * dec + k];
        d[(size_t)i] = s / (float)dec;
    }
    std::vector<float> win(B), blk(B);
    const float kPi = 3.14159265358979f;
    for (int i = 0; i < B; ++i) win[(size_t)i] = 0.5f - 0.5f * std::cos(2.f * kPi * (float)i / (float)(B - 1));

    float coef[36];
    for (int k = 0; k < 36; ++k) {
        const float f = refA4 * std::pow(2.f, ((float)(48 + k) - 69.f) / 12.f);
        coef[k] = 2.f * std::cos(2.f * kPi * f / fs);
    }
    double chroma[12] = {0};
    for (int s = 0; s + B <= m; s += B) {
        double e = 0;
        for (int i = 0; i < B; ++i) { blk[(size_t)i] = d[(size_t)(s + i)] * win[(size_t)i]; e += (double)d[(size_t)(s + i)] * d[(size_t)(s + i)]; }
        const float rms = (float)std::sqrt(e / B);
        if (rms < 1e-4f) continue;
        for (int k = 0; k < 36; ++k) {
            float s1 = 0, s2 = 0;
            for (int i = 0; i < B; ++i) { const float s0 = blk[(size_t)i] + coef[k] * s1 - s2; s2 = s1; s1 = s0; }
            const float p = s1 * s1 + s2 * s2 - coef[k] * s1 * s2;
            const float mag = std::sqrt(p > 0 ? p : 0.f);
            chroma[(48 + k) % 12] += std::log1p(60.0 * mag / (rms * (float)B * 0.5f + 1e-9f));
        }
    }
    static const double maj[12] = {6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88};
    static const double mnr[12] = {6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17};
    auto corr = [&](const double* prof, int rot) {
        double mc = 0, mp = 0;
        for (int i = 0; i < 12; ++i) { mc += chroma[i]; mp += prof[i]; }
        mc /= 12; mp /= 12;
        double sxy = 0, sxx = 0, syy = 0;
        for (int i = 0; i < 12; ++i) {
            const double a = chroma[(i + rot) % 12] - mc, b = prof[i] - mp;
            sxy += a * b; sxx += a * a; syy += b * b;
        }
        return sxx > 0 && syy > 0 ? sxy / std::sqrt(sxx * syy) : 0.0;
    };
    double best = -2; int br = 0, bm = 0;
    for (int r = 0; r < 12; ++r) {
        const double a = corr(maj, r), b = corr(mnr, r);
        if (a > best) { best = a; br = r; bm = 0; }
        if (b > best) { best = b; br = r; bm = 1; }
    }
    *root = br; *isMinor = bm; *confidence = (float)best;
    return 1;
}

// ---- Nhận nhịp (BPM): đường onset (chênh lệch bậc nhất) + tự tương quan + ưu tiên vùng 115 BPM.
#include <algorithm>
extern "C" int32_t vt_detect_bpm(const float* x, int32_t n, float sr, float* bpm, float* confidence) {
    if (!x || sr < 8000.f) return 0;
    const int hop = std::max(64, (int)(sr * 0.0058f));
    n = std::min<int32_t>(n, (int32_t)(sr * 60.f));
    const int m = n / hop;
    if (m < 1000) return 0;
    const float dt = (float)hop / sr;
    std::vector<float> e((size_t)m), o((size_t)m, 0.f);
    for (int i = 0; i < m; ++i) {
        double s = 0;
        for (int j = 0; j < hop; ++j) {
            const int k = i * hop + j;
            const float d = k > 0 ? x[k] - x[k - 1] : 0.f;
            s += (double)d * d;
        }
        e[(size_t)i] = (float)std::sqrt(s / hop);
    }
    double mean = 0;
    for (int i = 1; i < m; ++i) { o[(size_t)i] = std::max(0.f, e[(size_t)i] - e[(size_t)i - 1]); mean += o[(size_t)i]; }
    mean /= m;
    for (int i = 0; i < m; ++i) o[(size_t)i] -= (float)mean;
    const int lagMin = std::max(2, (int)std::floor(60.f / (200.f * dt)));
    const int lagMax = std::min(m / 2, (int)std::ceil(60.f / (60.f * dt)));
    std::vector<double> acf((size_t)lagMax + 2, 0.0);
    double acf0 = 0;
    for (int i = 0; i < m; ++i) acf0 += (double)o[(size_t)i] * o[(size_t)i];
    acf0 /= m;
    if (acf0 <= 1e-12) return 0;
    for (int l = lagMin - 1; l <= lagMax + 1 && l < m; ++l) {
        double s = 0;
        for (int i = 0; i + l < m; ++i) s += (double)o[(size_t)i] * o[(size_t)(i + l)];
        acf[(size_t)l] = s / (m - l);
    }
    int best = -1; double bv = -1e30;
    for (int l = lagMin; l <= lagMax; ++l) {
        if (!(acf[(size_t)l] >= acf[(size_t)l - 1] && acf[(size_t)l] >= acf[(size_t)l + 1])) continue;
        const double b = 60.0 / (l * dt);
        const double z = std::log2(b / 115.0) / 0.7;
        const double v = acf[(size_t)l] * std::exp(-0.5 * z * z);
        if (v > bv) { bv = v; best = l; }
    }
    if (best < 0) return 0;
    double lf = best;
    const double a = acf[(size_t)best - 1], b0 = acf[(size_t)best], c = acf[(size_t)best + 1], den = a + c - 2 * b0;
    if (std::fabs(den) > 1e-12) lf += std::max(-1.0, std::min(1.0, 0.5 * (a - c) / den));
    *bpm = (float)(60.0 / (lf * dt));
    *confidence = (float)std::max(0.0, std::min(1.0, acf[(size_t)best] / acf0));
    return 1;
}
