// SPDX-License-Identifier: MIT
/*
 * bridge_rate_src: a bridge_rate (bridge_core.h) on libsamplerate (Phase 11,
 * decisions H3/H4). Continuous ratio changes: every process() call passes the
 * current ratio, and libsamplerate moves to it smoothly across the block
 * (no step, no click), which is what a servo-driven ratio needs.
 *
 * Kept in its own file so only the bridges that resample link libsamplerate
 * (the USB host bridge); the USB and AVB bridges don't (decision H4: trimmable).
 *
 *   struct rate_src rs = { .converter = SRC_SINC_FASTEST, .name = "A" };
 *   struct bridge_rate r = RATE_SRC_OPS(&rs);
 */
#ifndef BRIDGE_RATE_SRC_H
#define BRIDGE_RATE_SRC_H

#include "bridge_core.h"

#include <samplerate.h>

struct rate_src {
	int converter;              /* SRC_SINC_FASTEST, SRC_SINC_MEDIUM_QUALITY, ... */
	const char *name;           /* for the log */
	/* internal */
	SRC_STATE *state;
	unsigned int channels;
	double ratio;
	long cap;                   /* frames the float buffers hold */
	float *fin, *fout;
	long frames_in, frames_out; /* since start: the effective ratio is out/in */
};

int  rate_src_start(void *ctx, unsigned int channels);
long rate_src_process(void *ctx, const int32_t *in, long n_in, int32_t *out, long max_out);
void rate_src_set_ratio(void *ctx, double ratio);
void rate_src_describe(void *ctx, char *buf, size_t n);
void rate_src_stop(void *ctx);

#define RATE_SRC_OPS(rs) { (rs), rate_src_start, rate_src_process, rate_src_set_ratio, \
			   rate_src_describe, rate_src_stop }

/* 24-bit int <-> float in [-1, 1): the scale libsamplerate expects. */
#define RATE_SRC_SCALE 8388608.0f

#endif
