// SPDX-License-Identifier: MIT
/*
 * Unit test for bridge_rate_src.c (Phase 11, H.1), and the CPU benchmark the
 * plan asks for. Needs libsamplerate, no ALSA (bridge_log is stubbed here):
 *
 *   gcc -Wall -Wextra -O2 -o t test_bridge_rate.c bridge_rate_src.c -lsamplerate -lm && ./t
 *   ./t --bench [seconds]        # real-time factor per converter, 2 ch, 48 kHz
 *
 * Checks, at 48 kHz in blocks of one bridge period (256 frames):
 *   1. frame counts: out = in x ratio, to within the converter's delay;
 *   2. a 1 kHz tone keeps its frequency, scaled by exactly the ratio (zero
 *      crossings over 10 s, at -1000, 0 and +1000 ppm);
 *   3. a ratio step mid-stream makes no discontinuity (no sample-to-sample
 *      jump above the tone's own slope);
 *   4. a full-scale square wave's overshoot is clamped, never wrapped;
 *   5. channels stay separate (a tone on 0, silence on 1).
 */
#include "bridge_rate_src.h"

#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define FS     48000
#define BLOCK  256
#define FULL   8388607

void bridge_log(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stdout, fmt, ap);
	va_end(ap);
	fputc('\n', stdout);
}

static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL: " __VA_ARGS__); printf("\n"); } } while (0)

/* Run `seconds` of a 2-channel signal through a fresh stage at `ratio`
 * (optionally changing to `ratio2` halfway). ch0 = gen(frame), ch1 = 0.
 * Returns the output (caller frees), its frame count in *n_out. */
static int32_t *run(double ratio, double ratio2, double seconds,
		    int32_t (*gen)(long), long *n_out, long *n_in_total)
{
	struct rate_src rs = { .converter = SRC_SINC_FASTEST, .name = "test" };
	long total = (long)(seconds * FS), cap = (long)(total * 1.01) + 4096, n = 0;
	int32_t in[BLOCK * 2], *out = malloc(cap * 2 * sizeof(int32_t));

	rate_src_set_ratio(&rs, ratio);
	if (rate_src_start(&rs, 2) < 0)
		exit(2);
	for (long f = 0; f < total; f += BLOCK) {
		if (f >= total / 2)
			rate_src_set_ratio(&rs, ratio2);
		for (int i = 0; i < BLOCK; i++) {
			in[2 * i] = gen(f + i);
			in[2 * i + 1] = 0;
		}
		long m = rate_src_process(&rs, in, BLOCK, out + 2 * n, BRIDGE_RATE_MAX_OUT(BLOCK));
		if (m < 0)
			exit(3);
		n += m;
	}
	rate_src_stop(&rs);
	*n_out = n;
	*n_in_total = total - total % BLOCK + (total % BLOCK ? BLOCK : 0);
	return out;
}

static int32_t tone(long f)
{
	return (int32_t)lrint(0.5 * FULL * sin(2 * M_PI * 1000.0 * f / FS));
}

static int32_t square(long f)
{
	return ((f / 24) & 1) ? FULL : -FULL - 1;     /* 1 kHz, full scale, both rails */
}

static long crossings(const int32_t *x, long n, long skip)
{
	long c = 0;
	for (long i = skip + 1; i < n; i++)
		if ((x[2 * (i - 1)] < 0) != (x[2 * i] < 0))
			c++;
	return c;
}

static void bench(double seconds)
{
	const int conv[] = { SRC_SINC_FASTEST, SRC_SINC_MEDIUM_QUALITY, SRC_SINC_BEST_QUALITY, SRC_LINEAR };
	long total = (long)(seconds * FS);
	int32_t in[BLOCK * 2], out[BRIDGE_RATE_MAX_OUT(BLOCK) * 2];

	for (int i = 0; i < BLOCK; i++) {
		in[2 * i] = tone(i);
		in[2 * i + 1] = tone(i + 7);
	}
	for (size_t k = 0; k < sizeof conv / sizeof conv[0]; k++) {
		struct rate_src rs = { .converter = conv[k], .name = "bench" };
		struct timespec a, b;
		rate_src_set_ratio(&rs, 1.0001);
		rate_src_start(&rs, 2);
		clock_gettime(CLOCK_MONOTONIC, &a);
		for (long f = 0; f < total; f += BLOCK)
			rate_src_process(&rs, in, BLOCK, out, BRIDGE_RATE_MAX_OUT(BLOCK));
		clock_gettime(CLOCK_MONOTONIC, &b);
		rate_src_stop(&rs);
		double cpu = (b.tv_sec - a.tv_sec) + (b.tv_nsec - a.tv_nsec) * 1e-9;
		printf("%-34s %5.1f s of 2-ch audio in %6.3f s: %5.2f %% of one core per direction\n",
		       src_get_name(conv[k]), seconds, cpu, 100.0 * cpu / seconds);
	}
}

int main(int argc, char **argv)
{
	if (argc > 1 && !strcmp(argv[1], "--bench")) {
		bench(argc > 2 ? atof(argv[2]) : 20.0);
		return 0;
	}

	/* 1 + 2: frame counts and frequency at -1000, 0, +1000 ppm */
	const double ppm[3] = { -1000, 0, 1000 };
	long c_ref = 0;
	for (int k = 0; k < 3; k++) {
		double r = 1.0 + ppm[k] * 1e-6;
		long n, n_in;
		int32_t *y = run(r, r, 10.0, tone, &n, &n_in);
		double want = n_in * r;
		CHECK(fabs(n - want) < 200, "ratio %+.0f ppm: %ld frames out, want %.0f", ppm[k], n, want);
		long c = crossings(y, n, 4800);
		/* crossings per input second are the tone's: per OUTPUT frame they
		 * scale by 1/ratio, so over the output they stay ~= 2 x 1000 x 9.9 s */
		double per_out = (double)c / (n - 4800 - 1);
		double want_per_out = 2.0 * 1000.0 / FS / r;
		CHECK(fabs(per_out / want_per_out - 1.0) < 2e-4,
		      "ratio %+.0f ppm: %.6f crossings per output frame, want %.6f",
		      ppm[k], per_out, want_per_out);
		if (k == 1)
			c_ref = c;
		printf("  %+5.0f ppm: %ld in -> %ld out (want %.0f), %ld zero crossings\n",
		       ppm[k], n_in, n, want, c);
		free(y);
	}
	CHECK(c_ref > 19000, "too few crossings at 0 ppm (%ld): the tone didn't get through", c_ref);

	/* 3: a ratio step mid-stream: no jump above the tone's own slope */
	{
		long n, n_in;
		int32_t *y = run(1.0, 1.0 + 500e-6, 2.0, tone, &n, &n_in);
		double slope = 0.5 * FULL * 2 * M_PI * 1000.0 / FS;     /* max |dy| per sample */
		long worst = 0;
		for (long i = 4801; i < n; i++) {
			long d = labs((long)y[2 * i] - (long)y[2 * (i - 1)]);
			if (d > worst)
				worst = d;
		}
		CHECK(worst < slope * 1.05, "ratio step: jump %ld > slope %.0f", worst, slope);
		printf("  ratio step 0 -> +500 ppm: largest sample step %ld (the tone's slope %.0f)\n",
		       worst, slope);
		free(y);
	}

	/* 4: overshoot clamped, never wrapped: a full-scale square (whose
	 * resampled version overshoots, Gibbs) against a float reference, a
	 * second libsamplerate fed the same blocks; every output must equal the
	 * reference rounded and clamped. 5: channel 1 stays silent. */
	{
		long n, n_in, bad = 0, over = 0, leak = 0, k = 0;
		const double r = 1.0 + 100e-6;
		int32_t *y = run(r, r, 1.0, square, &n, &n_in);
		int err;
		SRC_STATE *ref = src_new(SRC_SINC_FASTEST, 1, &err);
		float fin[BLOCK], fout[BRIDGE_RATE_MAX_OUT(BLOCK)];
		for (long f = 0; f < n_in; f += BLOCK) {
			SRC_DATA d = { 0 };
			for (int i = 0; i < BLOCK; i++)
				fin[i] = (float)square(f + i) / RATE_SRC_SCALE;
			d.data_in = fin; d.data_out = fout; d.input_frames = BLOCK;
			d.output_frames = BRIDGE_RATE_MAX_OUT(BLOCK); d.src_ratio = r;
			src_process(ref, &d);
			for (long i = 0; i < d.output_frames_gen && k < n; i++, k++) {
				long want = lrintf(fout[i] * RATE_SRC_SCALE);
				if (want > FULL) { want = FULL; over++; }
				if (want < -FULL - 1) { want = -FULL - 1; over++; }
				if (y[2 * k] != want)
					bad++;
				if (y[2 * k + 1] != 0)
					leak++;
			}
		}
		src_delete(ref);
		CHECK(k == n, "square: reference made %ld frames, the stage %ld", k, n);
		CHECK(over > 100, "square: only %ld overshooting samples; the clamp wasn't exercised", over);
		CHECK(bad == 0, "square: %ld samples differ from the clamped reference (wrap?)", bad);
		CHECK(leak == 0, "channel 1: %ld nonzero samples (channels mixed)", leak);
		printf("  full-scale square: %ld frames, %ld overshoots clamped, %ld mismatches\n", n, over, bad);
		free(y);
	}

	printf(fails ? "FAIL test_bridge_rate (%d)\n" : "PASS test_bridge_rate\n", fails);
	return fails != 0;
}
