#ifndef VOCALDSP_H
#define VOCALDSP_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Tham số điều khiển. Điền mặc định bằng vt_default_params rồi sửa từng trường. */
typedef struct VTParams {
    float retuneMs;       /* 0..400, 0 = robot */
    float amount;         /* 0..1 */
    float flexCents;      /* 0..50, humanize */
    float vibratoKeep;    /* 0..1 */
    float formant;        /* tỉ lệ 0.8..1.26 */
    float transposeSemis; /* -12..12 */
    float detuneCents;    /* -50..50 */
    float refA4;          /* 415..466 */
    uint32_t noteMask;    /* bit i = pitch class i (C=0) được phép */
    int32_t manualNote;   /* -1 = tắt; >=0 = ép theo pitch class của nốt MIDI này */
    float inputGainDb;
    float gateDb;         /* <= -80 là tắt */
    float compAmount;     /* 0..1 */
    float reverbMix;      /* 0..1 */
    float reverbSize;     /* 0..1 */
    float delayMix;       /* 0..1 */
    float delayMs;        /* 20..1400 */
    float delayFeedback;  /* 0..0.9 */
    float outputGainDb;
    int32_t bypass;       /* 1 = chỉ trễ, không tune */
    int32_t lowPower;     /* 1 = tiết kiệm pin */
    float deEss;          /* 0..1 */
    float eqLowDb;        /* kệ trầm 150 Hz, -9..9 */
    float eqPresenceDb;   /* đỉnh 3.5 kHz, -9..9 */
    float eqAirDb;        /* kệ cao 10 kHz, -9..9 */
} VTParams;

typedef struct VTDiag {
    float cpuLoad;        /* thời gian xử lý / thời lượng buffer (trung bình trượt) */
    float peakLoad;       /* đỉnh gần đây */
    int32_t underruns;    /* số lần ring monitor bị thiếu mẫu */
    int32_t blocks;       /* số block đã xử lý */
    int32_t lastFrames;   /* kích thước block gần nhất */
    int32_t latencySamples;
} VTDiag;

typedef struct VTTelemetry {
    float inMidi;      /* cao độ gốc (nốt MIDI, thập phân) */
    float outMidi;     /* cao độ sau chỉnh */
    float targetMidi;  /* nốt đích */
    float level;       /* đỉnh tín hiệu vào của block gần nhất */
    int32_t voiced;
} VTTelemetry;

/* rangePreset: 0 = trầm (>=80Hz), 1 = trung (>=110Hz), 2 = cao (>=160Hz) */
void*   vt_create(float sampleRate, int32_t rangePreset);
void    vt_destroy(void* h);
void    vt_default_params(VTParams* p);
void    vt_set_params(void* h, const VTParams* p);
int32_t vt_latency(void* h);
void    vt_reset(void* h);

/* Realtime: mic -> DSP -> ring monitor (và ring ghi âm nếu đang thu) */
void    vt_capture(void* h, const float* in, int32_t frames);
int32_t vt_monitor(void* h, float* out, int32_t frames);

/* Ghi âm */
void    vt_set_recording(void* h, int32_t on);
int32_t vt_read_dry(void* h, float* dst, int32_t maxFrames);
int32_t vt_read_wet(void* h, float* dst, int32_t maxFrames);

/* Ngoại tuyến (studio render, test). out có độ trễ vt_latency mẫu. */
void vt_process(void* h, const float* in, float* out, int32_t frames);
void vt_get_telemetry(void* h, VTTelemetry* t);

void vt_get_diag(void* h, VTDiag* d);

/* Hiệu chuẩn độ trễ vòng: phát 6 tiếng click ra tai nghe, mic thu lại. Cần ~4 giây. */
void    vt_calib_start(void* h);
void    vt_calib_stop(void* h);
float   vt_calib_progress(void* h);                       /* 0..1 */
int32_t vt_calib_result(void* h, float* ms, float* conf); /* 1 nếu có kết quả */

/* Nhận nhịp (BPM) của nhạc nền (mono). */
int32_t vt_detect_bpm(const float* mono, int32_t frames, float sampleRate, float* bpm, float* confidence);

/* Nhận key từ nhạc nền (mono). Trả 1 nếu thành công. root 0..11 (C=0), isMinor 0/1, confidence ~0..1. */
int32_t vt_detect_key(const float* mono, int32_t frames, float sampleRate, float refA4,
                      int32_t* root, int32_t* isMinor, float* confidence);

#ifdef __cplusplus
}
#endif
#endif
