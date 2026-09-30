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
 * Users: fpgamixer-usb-bridge (Phase 8), fpgamixer-avb-bridge (Phase 9).
 */
#ifndef BRIDGE_CORE_H
#define BRIDGE_CORE_H

#include <alsa/asoundlib.h>
#include <signal.h>

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

struct bridge_dir {
	const char *name;                  /* for the log */
	const char *cap_dev, *play_dev;
	snd_pcm_format_t cap_fmt, play_fmt;   /* S24_LE, S24_3LE or S24_3BE */
	unsigned int channels, rate;
	snd_pcm_uframes_t period;          /* frames, both PCMs */
	unsigned int periods;              /* per buffer, both PCMs */
	snd_pcm_uframes_t target;          /* playback queue setpoint, frames */
	snd_pcm_uframes_t coarse;          /* this far off target: fix in whole periods */
	double hold_s;                     /* servo paused after an xrun or coarse fix */
	double update_s;                   /* servo update interval */
	const struct bridge_servo *servo;  /* NULL: none */
};

/* Thread body: runs one direction until bridge_stop. */
void *bridge_run(void *dir);

#endif
