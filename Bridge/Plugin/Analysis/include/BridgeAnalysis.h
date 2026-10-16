#ifndef AURALISCOPE_BRIDGE_ANALYSIS_H
#define AURALISCOPE_BRIDGE_ANALYSIS_H

// The plugins' narrow C interface to the shared analysis core (Sources/AnalysisCore, Swift). The build compiles
// the core's sources together with BridgeAnalysisABI.swift into each plugin binary, under a Swift module name of
// its own per format, so a host that loads both the VST3 and the AU never sees two definitions of one Swift type.
//
// Threading: every function below is called from the plugin's analysis thread only (BridgeAnalysisHub.cpp), never
// from a host's audio thread: they allocate, and the Swift runtime may take locks.

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AbrAnalyzer AbrAnalyzer;

// What the plugin window shows of its own measurement: plain values, copied out.
typedef struct {
    uint32_t generation;
    uint32_t measuring;          // 1 measuring, 0 paused
    uint32_t channels;
    uint32_t breaks;
    uint64_t ticks;
    uint64_t frames_analysed;
    double seconds_analysed;
    float peak[2];               // linear, the newest 1/30 s (channels 1 and 2)
    float held_true_peak[2];     // linear
    float loudest_peak;          // linear: the loudest channel's, the newest 1/30 s (every channel of an immersive bus)
    float loudest_held_true_peak;
    uint32_t loudest_peak_role;  // its speaker role (ABR_ROLE_*)
    uint32_t loudest_held_true_peak_role;
    float momentary;             // LUFS, -100: no value
    float short_term;
    float integrated;
    float loudness_range;        // LU, -1: none
} AbrAnalysisSummary;

// A new analysis (generation `generation`) of `channels` channels at `sample_rate`, channel c carrying speaker role
// `roles[c]` (ABR_ROLE_*, BridgeProtocol.h): mono [L], stereo [L R], or an immersive bus of up to 16 distinct roles
// including L and R. NULL for anything else.
AbrAnalyzer *abr_analyzer_create(double sample_rate, uint32_t channels, const uint8_t *roles, uint32_t generation,
                                 uint32_t format_epoch);
void abr_analyzer_destroy(AbrAnalyzer *analyzer);
// `frames` interleaved frames whose first is at stream position `position`; `now` in seconds (monotonic).
void abr_analyzer_consume(AbrAnalyzer *analyzer, const float *interleaved, uint32_t frames, uint64_t position, double now);
// A break before the next audio (ABR_AUDIO_AFTER_* reasons).
void abr_analyzer_interrupt(AbrAnalyzer *analyzer, uint64_t lost_frames, uint32_t idle_ms, uint32_t reasons);
// No audio this pass: returns 1 when an idle tick was published.
int abr_analyzer_idle(AbrAnalyzer *analyzer, double now);
void abr_analyzer_set_measuring(AbrAnalyzer *analyzer, int measuring);
void abr_analyzer_reset_true_peaks(AbrAnalyzer *analyzer);
// The waterfall's analysis for the columns from now on: 0 Classic, 1 Enhanced (others are Classic).
void abr_analyzer_set_spectrogram_mode(AbrAnalyzer *analyzer, uint32_t mode);
// What the spectrum and the waterfall sum: 0 L and R, 1 every channel (ABR_SUBSCRIBE_SPECTRUM).
void abr_analyzer_set_spectrum_channels(AbrAnalyzer *analyzer, uint32_t channels);
// The spatial field's coherence threshold in thousandths (ABR_SUBSCRIBE_COHERENCE); 0 is the default (300).
void abr_analyzer_set_spatial_coherence(AbrAnalyzer *analyzer, uint32_t thousandths);
// Ticks published so far (a new result is ready when this grows).
uint64_t abr_analyzer_ticks(const AbrAnalyzer *analyzer);
// Writes a RESULT payload (Bridge/PROTOCOL.md) into `buffer`; returns its size, 0 when there is nothing yet or it
// does not fit. `*spectrogram_through` / `*waveform_through` receive the newest column serials it carries.
uint32_t abr_analyzer_encode(AbrAnalyzer *analyzer, void *buffer, uint32_t capacity, uint32_t subscription,
                             uint32_t layout, uint64_t after_spectrogram, uint64_t after_waveform,
                             uint64_t *spectrogram_through, uint64_t *waveform_through);
void abr_analyzer_summary(const AbrAnalyzer *analyzer, AbrAnalysisSummary *summary);

#ifdef __cplusplus
}
#endif

#endif
