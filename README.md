# VocalTune

Auto-tune thu âm hát cho iPhone (iOS 18, tối ưu XS Max). Kế hoạch chi tiết nằm trong Doc đi kèm.

## Chạy test DSP (không cần Mac/Xcode)
    g++ -std=c++17 -O2 Tests/dsp_test.cpp App/DSP/VocalDSP.cpp App/DSP/KeyDetect.cpp -I App/DSP -o dsp_test && ./dsp_test

## Build
Codemagic: dùng `codemagic.yaml` (xcodegen sinh project, archive không ký, ra `VocalTune.ipa` để bạn tự ký).
Đổi `com.example.vocaltune` trong `project.yml` thành bundle id của bạn.

## Trạng thái (v0.2)
- DSP C++ đã test trên host (13 nhóm test): snap nốt, vibrato, nhảy nốt, âm xì, EQ, de-esser, hiệu chuẩn độ trễ, BPM, key, chẩn đoán, CPU.
- Mã Swift/SwiftUI viết thêm ở v0.2 CHƯA được biên dịch trong môi trường tạo ra nó. Build đầu có thể cần sửa lỗi nhỏ.
- Chưa đo độ trễ, pin, nhiệt trên máy thật. Dùng màn Chẩn đoán và Hiệu chuẩn để lấy số đo.
- Chưa có: sửa từng nốt (Studio), video cover, Control Center, Live Activity, Harmony/Double, đa ngôn ngữ.
