// SPDX-License-Identifier: MIT
/*
 * bridge_core: what the FPGAmixer front-door bridges share (Phase 9, P9.7,
 * decision V1). One direction = one capture PCM -> one playback PCM, 8
 * channels, repacked between formats, the playback queue held at a target:
 *
 *   - both PCMs opened non-blocking in their native formats, the geometry
 *     chosen inside their limits, the full hw-params space logged if a
 *     device refuses its setup;
 *   - ONE poll over both PCMs' descriptors. Both are serviced while the
 *     thread waits: the AAF plugin (alsa-plugins ioplug) only transmits a
 *     period when its timer event is handled, so a thread blocked on the
 *     other device would send late (and, while ETF was in use, see them dropped)
 *     (docs/phase9_status_2026-09-26.md sec. 6.16);
 *   - xrun recovery (restart, prefill), and a coarse fix that drops or pads
 *     whole periods when the queue is more than `coarse` frames off target;
 *     both counted and logged every 10 s;
 *   - an optional servo on the queue error (the USB bridge's pitch servo);
 *     the AVB bridge has none: both of its sides run on the PHC's time.
 *
 * Since Phase 11 a direction may also have different channel counts on its
 * two sides and an optional rate stage (struct bridge_rate) for two PCMs on
 * unrelated clocks.
 *
 * Users: fpgamixer-usb-bridge (Phase 8), fpgamixer-avb-bridge (Phase 9),
 * fpgamixer-usbhost-bridge (Phase 11, with a rate stage).
 */
#ifndef BRIDGE_CORE_H
#define BRIDGE_CORE_H

#include <alsa/asoundlib.h>
#include <signal.h>
#include <stdint.h>

extern volatile sig_atomic_t bridge_stop;     /* set by a signal: all directions end */
extern volatile sig_atomic_t bridge_failed;   /* a direction could not start */
extern int bridge_verbose;

void bridge_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
double bridge_now(void);

/* SIGINT/SIGTERM -> bridge_stop; SCHED_FIFO at `prio` if allowed. */
void bridge_setup_process(int prio);

/* An optional controller driven by the playback queue error (frames,
 * filtered). update() is called every update_s, but never during the hold
 * after an xrun or a coarse fix. */
struct bridge_servo {
	void *ctx;
	int  (*start)(void *ctx);                  /* after both PCMs are open; <0 fails */
	void (*update)(void *ctx, double queue_err, double dt);
	void (*describe)(void *ctx, char *buf, size_t n);   /* for the 10 s log line */
	void (*stop)(void *ctx);
};

/*
 * An optional rate stage (Phase 11, decision H4): between the capture and the
 * playback side, it turns n_in frames into about n_in * ratio frames, so the
 * two PCMs may run on unrelated clocks (the USB host bridge: the interface's
 * clock vs mclk). Samples are int32 holding 24-bit audio (S24_LE layout),
 * interleaved, `channels` per frame (the narrower side's count). The servo
 * sets the ratio (output rate / input rate) from the playback queue error, so
 * the queue, not a clock estimate, decides it. NULL keeps the 1:1 path.
 * One implementation: bridge_rate_src.c (libsamplerate), linked only by the
 * bridges that use it.
 */
struct bridge_rate {
	void *ctx;
	int  (*start)(void *ctx, unsigned int channels);     /* <0 fails */
	/* returns the frames written to out (<= max_out), or <0 on error */
	long (*process)(void *ctx, const int32_t *in, long n_in, int32_t *out, long max_out);
	void (*set_ratio)(void *ctx, double ratio);
	void (*describe)(void *ctx, char *buf, size_t n);    /* for the 10 s log line */
	void (*stop)(void *ctx);
};

/* Most a rate stage may produce from one period: ratios are kept within
 * +/- RATE_SPAN of 1 by its users, plus the converter's own slack. */
#define BRIDGE_RATE_MAX_OUT(n) ((n) + (n) / 50 + 64)

struct bridge_dir {
	const char *name;                  /* for the log */
	const char *cap_dev, *play_dev;
	snd_pcm_format_t cap_fmt, play_fmt;   /* S24_LE, S24_3LE, S24_3BE, S32_BE or S32_LE */
	unsigned int channels, rate;       /* channels: the capture side's */
	unsigned int play_channels;        /* 0: the same as channels. Otherwise the
					    * first min(channels, play_channels) are
					    * carried, extra playback channels get
					    * zeros (the link card always opens at 8) */
	snd_pcm_uframes_t period;          /* frames, both PCMs */
	unsigned int periods;              /* per buffer, both PCMs */
	snd_pcm_uframes_t target;          /* playback queue setpoint, frames */
	snd_pcm_uframes_t coarse;          /* this far off target: fix in whole periods */
	double hold_s;                     /* servo paused after an xrun or coarse fix */
	double update_s;                   /* servo update interval */
	const struct bridge_servo *servo;  /* NULL: none */
	const struct bridge_rate *resampler;   /* NULL: 1:1 (USB and AVB bridges) */
};

/* Thread body: runs one direction until bridge_stop. */
void *bridge_run(void *dir);

#endif
