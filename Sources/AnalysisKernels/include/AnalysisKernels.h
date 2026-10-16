#ifndef ANALYSIS_KERNELS_H
#define ANALYSIS_KERNELS_H

// The C part of the shared analysis core (AnalysisCore): frame types and the DSP kernels that the Swift analysers
// call. No Core Audio, no AppKit, no allocation: the same code runs in Auraliscope's DSP queue and in the
// Auraliscope Bridge plugins' analysis thread.

#include <stdint.h>

typedef struct {
    float left;
    float right;
} StereoFrame;

// One frame of every speaker role, up to 9.1.6. Role indices 0–7 keep their 5.1.2 meaning so saved
// routing stays valid; 8–15 extend the layout (rear surrounds, wides, top middle, top rear).
#define CHANNEL_ROLE_COUNT 16
typedef struct {
    float left, right, center, lfe, leftSurround, rightSurround, leftTopFront, rightTopFront;
    float leftRearSurround, rightRearSurround, leftWide, rightWide;
    float leftTopMiddle, rightTopMiddle, leftTopRear, rightTopRear;
} ChannelFrame;

// Copies every `stride`-th float of `source` into `count` contiguous floats: one channel out of interleaved
// frames. vDSP_mmov with a one-float row calls memmove once per sample, which cost the DSP queue a third of its
// time with sixteen roles; this plain loop compiles to a few instructions per sample.
void audio_gather_strided(const float *source, uint32_t stride, float *destination, uint32_t count);
// True-peak refinement state of one channel (see TruePeakDetector in LoudnessAnalyzer.swift): the loudest local
// maxima of the coarse (4× or 2×) magnitudes in the current segment, each with the input the fine kernel reads
// around it, and the newest coarse point, which waits for its right-hand neighbour.
#define TRUE_PEAK_MAX_TAPS 64
#define TRUE_PEAK_MAX_REFINEMENT 8
#define TRUE_PEAK_CANDIDATES 2
typedef struct {
    float value;              // coarse magnitude; 0 = empty
    int32_t phase;            // 0 (the sample itself) ≤ phase < factor
    int64_t time;             // in coarse steps, for ties
    float taps[TRUE_PEAK_MAX_TAPS + 2];  // the window, with one sample more either side
} TruePeakCandidate;

typedef struct {
    int64_t segment;          // current segment index, or -1 before the first
    TruePeakCandidate best[TRUE_PEAK_CANDIDATES];  // loudest first
    TruePeakCandidate tail;   // the newest point (value 0: none)
    float before;             // the magnitude before `tail`
    int64_t tail_segment;
} TruePeakSegment;

typedef struct {
    const float *fine;        // (factor × refinement) filters of `taps` floats, reversed, one after another;
                              // filter q reads the window at sample taps / 2 − 1 + q / (factor × refinement)
    uint32_t taps;            // even, at most TRUE_PEAK_MAX_TAPS
    uint32_t factor;
    uint32_t refinement;
    uint32_t segment_length;
    float runner_up;          // a second local maximum at least this fraction of the first is refined too
} TruePeakKernel;

// Folds `work` coarse outputs into the segments they belong to (output i belongs to the segment of sample
// start + i), refining each finished segment into *held. The coarse outputs only choose where to refine: *held
// takes refined values alone. Output i, phase p, lies at the fine kernel's filter p × refinement over the window
// base + 1 + i; base + i … base + i + taps + 1 must be readable. `outputs` holds phase p (1 ≤ p < factor) at
// (p − 1) × stride, and `loudest` the largest magnitude at each output over those phases and the sample itself
// (phase 0, base[taps / 2 + i]).
void true_peak_scan(TruePeakSegment *state, const TruePeakKernel *kernel, const float *base, const float *outputs,
                    uint32_t stride, const float *loudest, uint32_t work, int64_t start, float *held);
// Settles the newest point as if silence followed, then refines the current segment into *held and starts
// segment `next` (−1: none). Each refined local maximum: the fine kernel at it and at fine steps either side,
// as far as the loudest of them needs neighbours, then a parabola through that one and its neighbours.
void true_peak_finish(TruePeakSegment *state, const TruePeakKernel *kernel, int64_t next, float *held);

// Splits one complex DFT of z = a + ib (n points, a and b real) into both power spectra for bins 1 … n/2 − 1:
// power_a[k] = (Zr[k] + Zr[n−k])² + (Zi[k] − Zi[n−k])², power_b[k] = (Zi[k] + Zi[n−k])² + (Zr[k] − Zr[n−k])²
// (4|A[k]|² and 4|B[k]|²). Bin 0 is left to the caller.
void packed_pair_powers(const float *real, const float *imaginary, uint32_t n, float *power_a, float *power_b);

// Twelve biquad cascades of four sections each, run on four-lane vectors: lane l reads `left` when l is even and
// `right` when odd, and writes `outputs[l]` for l < lanes. `coefficients` holds, per group of four lanes and
// section, b0 b1 b2 a1 a2 as four-lane vectors (3 × 4 × 5 × 4 floats); `state` 3 × 4 × 2 × 4 floats.
#define BAND_LANES 12
#define BAND_SECTIONS 4
void band_filter(const float *coefficients, float *state, const float *left, const float *right, float *const *outputs,
                 uint32_t lanes, uint32_t count);

// BS.1770 K-weighting (a shelf, then a high-pass: b0 b1 b2 a1 a2 each, in `coefficients`) in double precision.
// Filters `channels` planar inputs of `count` samples, with a two-lane path for mono/stereo and groups of eight otherwise; adds each one's sum of squared
// outputs to `energy[c]`. `state` holds four doubles per channel (transposed direct form II, both sections).
void k_weight_energy(const double *coefficients, double *const *state, const float *const *inputs, uint32_t channels,
                     uint32_t count, double *energy);

#endif
