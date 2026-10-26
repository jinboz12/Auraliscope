// The capture health record across threads, as the app uses it: one thread plays the IO callback (an output tap
// whose deliveries alternately fit the storage and are cut off), another reads the record at the same time, as the
// main thread's readout does, and drains the ring, as the analysis does. Every reading must show counters that only
// grow and a run that is either over or one delivery long; once the writer stops, the record must hold exactly what
// it did. Built with -fsanitize=thread (scripts/test.sh thread, or by hand) it also shows the accesses are race-free.
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include "CaptureCallback.h"

#define ROUNDS 200000
#define STORAGE 256
#define CUT 300

static CaptureContext context;
static atomic_int finished;

static void *deliver(void *unused) {
    (void)unused;
    static float left[CUT], right[CUT];
    for (int i = 0; i < CUT; i++) { left[i] = 0.25f; right[i] = 0.5f; }
    // Two mono streams: the callback interleaves them through its storage, and cuts what does not fit.
    struct { AudioBufferList list; AudioBuffer second; } input;
    AudioTimeStamp time;
    memset(&time, 0, sizeof time);
    AudioBufferList output;
    memset(&output, 0, sizeof output);
    for (int round = 0; round < ROUNDS; round++) {
        UInt32 frames = round % 2 == 0 ? STORAGE : CUT;
        input.list.mNumberBuffers = 2;
        input.list.mBuffers[0] = (AudioBuffer){1, frames * (UInt32)sizeof(float), left};
        input.second = (AudioBuffer){1, frames * (UInt32)sizeof(float), right};
        capture_tap_io_proc(0, &time, &input.list, &time, &output, &time, &context);
    }
    atomic_store(&finished, 1);
    return NULL;
}

int main(void) {
    ChannelRing *ring = channel_ring_create(1 << 15);
    CaptureHealth *health = capture_health_create();
    static float storage[STORAGE * 2];
    if (!ring || !health) { fprintf(stderr, "FAIL: capture health concurrency: allocation\n"); return 1; }
    context.ring = ring;
    context.storage = storage;
    context.max_frames = STORAGE;
    context.channels = 2;
    for (int role = 0; role < CHANNEL_ROLE_COUNT; role++) context.source_for_role[role] = role < 2 ? role : -1;
    context.health = health;

    pthread_t writer;
    pthread_create(&writer, NULL, deliver, NULL);
    CaptureHealthReading last;
    memset(&last, 0, sizeof last);
    static ChannelFrame frames[4096];
    ChannelRingMark mark;
    int marked = 0;
    long readings = 0, errors = 0;
    while (!atomic_load(&finished)) {
        CaptureHealthReading now;
        capture_health_read(health, &now);
        if (now.delivered_slices < last.delivered_slices || now.failed_slices < last.failed_slices
            || now.delivered_frames < last.delivered_frames || now.run_slices > 1 || now.largest_slice > CUT) errors++;
        last = now;
        readings++;
        while (channel_ring_read_marked(ring, frames, 4096, &mark, &marked) > 0 || marked) {}
    }
    pthread_join(writer, NULL);
    CaptureHealthReading end;
    capture_health_read(health, &end);
    int exact = end.delivered_slices == ROUNDS / 2 && end.failed_slices == ROUNDS / 2
        && end.delivered_frames == (uint64_t)(ROUNDS / 2) * STORAGE && end.run_slices == 1
        && end.run_lost_frames == CUT - STORAGE && end.run_failures == CAPTURE_FAILURE_TRUNCATED
        && end.largest_slice == CUT && channel_ring_dropped(ring) >= (uint64_t)(ROUNDS / 2) * (CUT - STORAGE);
    channel_ring_destroy(ring);
    capture_health_destroy(health);
    if (errors || !exact) {
        fprintf(stderr, "FAIL: capture health concurrency: %ld inconsistent readings of %ld; final record %s\n", errors,
                readings, exact ? "exact" : "wrong");
        return 1;
    }
    printf("PASS: capture health record: %ld readings during %d deliveries on another thread, counters only grow, final record exact\n",
           readings, ROUNDS);
    return 0;
}
