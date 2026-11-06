// One local utterance per process. stdin: little-endian uint32 sample count,
// followed by 16 kHz mono IEEE Float32 PCM. stdout: bounded JSON lines.
// No microphone, file audio, network, codec, or image/video APIs.
#include "whisper.h"
#include "ggml-backend.h"
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

static std::string quote(const std::string &s) {
    std::string out = "\"";
    for (unsigned char c : s) {
        if (c == '"' || c == '\\') { out += '\\'; out += char(c); }
        else if (c == '\n') out += "\\n";
        else if (c == '\r') out += "\\r";
        else if (c == '\t') out += "\\t";
        else if (c < 32) { char b[7]; std::snprintf(b, sizeof(b), "\\u%04x", c); out += b; }
        else out += char(c);
    }
    return out + '"';
}
static int fail(const char *message) {
    std::cout << "{\"error\":" << quote(message) << "}\n" << std::flush;
    return 1;
}
int main(int argc, char **argv) {
    if (argc != 3 || std::strcmp(argv[1], "--model") != 0) return fail("Invalid speech runtime arguments.");
    ggml_backend_load_all();
    bool metal = false;
    for (size_t i = 0; i < ggml_backend_dev_count(); ++i) {
        auto dev = ggml_backend_dev_get(i);
        if (ggml_backend_dev_type(dev) == GGML_BACKEND_DEVICE_TYPE_GPU &&
            std::strcmp(ggml_backend_reg_name(ggml_backend_dev_backend_reg(dev)), "MTL") == 0) metal = true;
    }
    if (!metal) return fail("Metal speech recognition is unavailable on this Mac.");
    auto cp = whisper_context_default_params(); cp.use_gpu = true;
    auto *ctx = whisper_init_from_file_with_params(argv[2], cp);
    if (!ctx) return fail("The local speech model could not be loaded.");
    std::cout << "{\"ready\":true,\"protocol\":1,\"backend\":\"metal\"}\n" << std::flush;
    uint8_t header[4];
    if (!std::cin.read(reinterpret_cast<char *>(header), 4)) { whisper_free(ctx); return fail("Speech input ended before the utterance was supplied."); }
    const uint32_t count = uint32_t(header[0]) | uint32_t(header[1]) << 8 | uint32_t(header[2]) << 16 | uint32_t(header[3]) << 24;
    if (count < 160 || count > 120 * WHISPER_SAMPLE_RATE) { whisper_free(ctx); return fail("Dictation must be between 0.01 and 120 seconds."); }
    std::vector<float> samples(count);
    if (!std::cin.read(reinterpret_cast<char *>(samples.data()), count * sizeof(float))) { whisper_free(ctx); return fail("Speech input ended before all samples arrived."); }
    for (float value : samples) if (!std::isfinite(value)) { whisper_free(ctx); return fail("Speech input contains invalid samples."); }
    auto p = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH);
    p.n_threads = 4; p.language = "en"; p.no_context = true; p.no_timestamps = true;
    p.print_progress = false; p.print_realtime = false; p.print_timestamps = false;
    // Intentionally no prompt, grammar, replacement, or post-recognition repair.
    if (whisper_full(ctx, p, samples.data(), int(count)) != 0) { whisper_free(ctx); return fail("Local speech recognition failed."); }
    std::string text;
    for (int i = 0; i < whisper_full_n_segments(ctx); ++i) text += whisper_full_get_segment_text(ctx, i);
    whisper_free(ctx);
    if (text.size() > 32768) return fail("Local speech recognition returned too much text.");
    std::cout << "{\"text\":" << quote(text) << "}\n" << std::flush;
    return 0;
}
