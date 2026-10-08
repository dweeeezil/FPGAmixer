// SPDX-License-Identifier: MIT
/*
 * bridge_rate_src.c: see bridge_rate_src.h.
 *
 * Every process() call converts one block with end_of_input = 0, so the
 * converter keeps its filter state (and its few frames of look-ahead) from
 * block to block: the output is one continuous signal. The ratio given in
 * SRC_DATA is reached across the block (libsamplerate interpolates from the
 * previous call's ratio), so set_ratio() never makes a step.
 *
 * Samples: int32 holding 24-bit audio -> float / 2^23 -> converter -> back,
 * rounded and clamped to 24 bits (a resampler can overshoot full scale).
 */
#include "bridge_rate_src.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

int rate_src_start(void *ctx, unsigned int channels)
{
	struct rate_src *r = ctx;
	int err;

	r->channels = channels;
	r->ratio = r->ratio > 0 ? r->ratio : 1.0;
	r->state = src_new(r->converter, (int)channels, &err);
	if (!r->state) {
		bridge_log("%s: libsamplerate: %s", r->name, src_strerror(err));
		return -1;
	}
	r->cap = 0;
	r->fin = r->fout = NULL;
	r->frames_in = r->frames_out = 0;
	bridge_log("%s: resampler %s, %u ch", r->name, src_get_name(r->converter), channels);
	return 0;
}

static int grow(struct rate_src *r, long frames)
{
	if (frames <= r->cap)
		return 0;
	float *a = realloc(r->fin, frames * r->channels * sizeof(float));
	if (!a)
		return -1;
	r->fin = a;
	float *b = realloc(r->fout, frames * r->channels * sizeof(float));
	if (!b)
		return -1;
	r->fout = b;
	r->cap = frames;
	return 0;
}

long rate_src_process(void *ctx, const int32_t *in, long n_in, int32_t *out, long max_out)
{
	struct rate_src *r = ctx;
	long need = n_in > max_out ? n_in : max_out;
	SRC_DATA data = { 0 };
	int err;

	if (grow(r, need) < 0)
		return -1;
	for (long i = 0; i < n_in * (long)r->channels; i++)
		r->fin[i] = (float)in[i] / RATE_SRC_SCALE;

	data.data_in = r->fin;
	data.data_out = r->fout;
	data.input_frames = n_in;
	data.output_frames = max_out;
	data.src_ratio = r->ratio;
	data.end_of_input = 0;
	if ((err = src_process(r->state, &data)) != 0) {
		bridge_log("%s: libsamplerate: %s", r->name, src_strerror(err));
		return -1;
	}
	/* With room for the whole block's output, every input frame is taken. */
	if (data.input_frames_used != n_in)
		bridge_log("%s: %ld of %ld input frames used", r->name,
			   (long)data.input_frames_used, n_in);

	for (long i = 0; i < data.output_frames_gen * (long)r->channels; i++) {
		float v = r->fout[i] * RATE_SRC_SCALE;
		long s = lrintf(v);
		if (s > 8388607) s = 8388607;
		if (s < -8388608) s = -8388608;
		out[i] = (int32_t)s;
	}
	r->frames_in += data.input_frames_used;
	r->frames_out += data.output_frames_gen;
	return data.output_frames_gen;
}

void rate_src_set_ratio(void *ctx, double ratio)
{
	struct rate_src *r = ctx;
	if (src_is_valid_ratio(ratio))
		r->ratio = ratio;
}

void rate_src_describe(void *ctx, char *buf, size_t n)
{
	struct rate_src *r = ctx;
	snprintf(buf, n, "ratio %+.1f ppm", (r->ratio - 1.0) * 1e6);
}

void rate_src_stop(void *ctx)
{
	struct rate_src *r = ctx;
	if (r->state)
		src_delete(r->state);
	r->state = NULL;
	free(r->fin);
	free(r->fout);
	r->fin = r->fout = NULL;
	r->cap = 0;
}
