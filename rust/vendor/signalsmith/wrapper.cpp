// A C face for Signalsmith Stretch (MIT, vendored from github.com/Signalsmith-Audio),
// just what Halcyn's engine uses: rust/src/engine/stretch.rs declares these.
#include <signalsmith-stretch/signalsmith-stretch.h>

#include <cstddef>
#include <vector>

struct halcyn_stretch {
    signalsmith::stretch::SignalsmithStretch<float> stretch;
    int channels;
    // Channel-major copies: the library takes one buffer per channel.
    std::vector<std::vector<float>> in, out;
};

static void split(halcyn_stretch *h, std::vector<std::vector<float>> &to, const float *from, size_t frames) {
    for (int c = 0; c < h->channels; c++) {
        to[c].resize(frames);
        for (size_t i = 0; i < frames; i++) to[c][i] = from[i * h->channels + c];
    }
}

static void join(halcyn_stretch *h, float *to, size_t frames) {
    for (int c = 0; c < h->channels; c++) {
        for (size_t i = 0; i < frames; i++) to[i * h->channels + c] = h->out[c][i];
    }
}

extern "C" {

halcyn_stretch *halcyn_stretch_new(int channels, float rate) {
    auto h = new halcyn_stretch;
    h->channels = channels;
    h->stretch.presetDefault(channels, rate);
    h->in.resize(channels);
    h->out.resize(channels);
    return h;
}

void halcyn_stretch_free(halcyn_stretch *h) { delete h; }

size_t halcyn_stretch_input_latency(halcyn_stretch *h) { return h->stretch.inputLatency(); }

size_t halcyn_stretch_output_latency(halcyn_stretch *h) { return h->stretch.outputLatency(); }

void halcyn_stretch_set_semitones(halcyn_stretch *h, float semitones) {
    h->stretch.setTransposeSemitones(semitones);
}

// Interleaved: `in_frames` in, `out_frames` out; their ratio is the speed.
void halcyn_stretch_process(halcyn_stretch *h, const float *in, size_t in_frames, float *out, size_t out_frames) {
    split(h, h->in, in, in_frames);
    for (int c = 0; c < h->channels; c++) h->out[c].assign(out_frames, 0.0f);
    h->stretch.process(h->in, int(in_frames), h->out, int(out_frames));
    join(h, out, out_frames);
}

// Primes it with audio from before the start, so the first output isn't a fade-in.
void halcyn_stretch_seek(halcyn_stretch *h, const float *in, size_t in_frames, double speed) {
    split(h, h->in, in, in_frames);
    h->stretch.seek(h->in, int(in_frames), speed);
}

// What's still inside, once the input has ended.
void halcyn_stretch_flush(halcyn_stretch *h, float *out, size_t out_frames) {
    for (int c = 0; c < h->channels; c++) h->out[c].assign(out_frames, 0.0f);
    h->stretch.flush(h->out, int(out_frames));
    join(h, out, out_frames);
}

}
