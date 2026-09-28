// SPDX-License-Identifier: MIT
/*
 * fpgamixer-usb-bridge: the USB front door's Linux half, part 2 (Phase 8).
 *
 * Moves 8 channels each way between the UAC2 gadget card (the Mac's USB
 * clock) and the PS<->PL link card (the PL's mclk), and bridges the two clocks
 * WITHOUT resampling, by steering the Mac through the gadget's pitch controls:
 *
 *   A: Mac -> PL   gadget capture -> link playback
 *                  servo on the link playback queue -> "Capture Pitch 1000000"
 *                  (the UAC2 feedback value the Mac follows for its output)
 *   B: PL -> Mac   link capture -> gadget playback
 *                  servo on the gadget playback queue -> "Playback Pitch 1000000"
 *                  (our IN packet sizing, which an async Mac input follows)
 *
 * Why not alsaloop (tried on the bench 2026-09-26, docs/phase8_status_*.md):
 * it always asks for 8 periods per buffer where the formatter allows 2..6,
 * its -B/-E short options are missing from alsa-utils 1.2.11's getopt string,
 * and plughw's S24_3LE -> S24_LE conversion onto this card fails to install
 * hw params even with a valid geometry. So both cards are opened with hw: in
 * their native formats (gadget S24_3LE, link S24_LE) and the 3 <-> 4 byte
 * repack happens here, and the geometry is chosen inside the card's limits.
 *
 * Servo: each direction's playback queue (snd_pcm_delay) is held at
 * TARGET frames by a PI loop updated every UPDATE_MS; the output is the pitch
 * in ppm of 1e6, starting from the board's nominal mclk offset (PITCH_START).
 * Signs: in A a growing queue means the Mac sends too fast, so its pitch goes
 * down; in B a growing queue means we send too slowly, so our pitch goes up.
 *
 * Since Phase 9 (P9.7, decision V1) the direction loop, the PCM setup, the
 * repack, the xrun handling and the coarse fix live in bridge_core, shared
 * with fpgamixer-avb-bridge; this file is the USB-specific part: the devices,
 * the geometry and the pitch servo. Constants, signs and behaviour are the
 * Phase 8 ones. The only change in mechanics: the core waits with one poll
 * over both PCMs instead of a blocking read (bridge_core.h says why).
 *
 * Everything is logged to stderr (journald under systemd), including the
 * full hw-params space of a device that refuses its setup.
 *
 * Usage: fpgamixer-usb-bridge [-g GADGET] [-l LINK] [-v]
 *        defaults hw:UAC2Gadget, hw:FPGAmixerLink
 */
#define _GNU_SOURCE
#include "bridge_core.h"

#include <pthread.h>
#include <stdio.h>
#include <unistd.h>

#define CHANNELS      8
#define RATE          48000
#define PERIOD        192        /* frames; 4 ms */
#define PERIODS       4          /* link allows 2..6 */
#define TARGET        (PERIOD * 2)   /* playback queue setpoint, frames */
#define UPDATE_MS     100
#define PITCH_NOMINAL 1000000
#define PITCH_START   1000011    /* mclk nominal: 25 MHz x 58/118 = +11 ppm
                                    (Phase 9 P9.4a; was 1000324 for the
                                    +324 ppm MMCM setting before it) */
#define PITCH_SPAN    1000       /* clamp: +/- 1000 ppm around nominal */
#define KP            0.5        /* ppm per frame of queue error */
#define KI            0.05       /* ppm per frame-second */
#define COARSE        PERIOD     /* queue this far off target: fix it in whole periods */
#define HOLD_S        1.0        /* servo paused this long after an xrun or coarse fix */

/* ----- the pitch control on the gadget card ----- */

struct pitch {
	const char *card;            /* ctl device of the gadget card */
	const char *name;            /* the control */
	const char *dir_name;        /* for the log */
	int sign;                    /* +1: queue high -> pitch up; -1: down */
	snd_ctl_t *ctl;
	snd_ctl_elem_value_t *val;
	long value;
	double integ;
};

static void pitch_set(struct pitch *p, long v)
{
	if (v < PITCH_NOMINAL - PITCH_SPAN) v = PITCH_NOMINAL - PITCH_SPAN;
	if (v > PITCH_NOMINAL + PITCH_SPAN) v = PITCH_NOMINAL + PITCH_SPAN;
	if (v == p->value)
		return;
	snd_ctl_elem_value_set_integer(p->val, 0, v);
	if (snd_ctl_elem_write(p->ctl, p->val) >= 0)
		p->value = v;
}

static int pitch_start(void *ctx)
{
	struct pitch *p = ctx;
	snd_ctl_elem_id_t *id;
	int err;

	if ((err = snd_ctl_open(&p->ctl, p->card, 0)) < 0) {
		bridge_log("ctl %s: %s", p->card, snd_strerror(err));
		return err;
	}
	snd_ctl_elem_id_malloc(&id);
	snd_ctl_elem_id_set_interface(id, SND_CTL_ELEM_IFACE_PCM);
	snd_ctl_elem_id_set_name(id, p->name);
	snd_ctl_elem_value_malloc(&p->val);
	snd_ctl_elem_value_set_id(p->val, id);
	snd_ctl_elem_id_free(id);
	if ((err = snd_ctl_elem_read(p->ctl, p->val)) < 0) {
		bridge_log("ctl %s: '%s': %s", p->card, p->name, snd_strerror(err));
		return err;
	}
	p->value = snd_ctl_elem_value_get_integer(p->val, 0);
	p->integ = 0;
	pitch_set(p, PITCH_START);
	bridge_log("%s: pitch '%s' starts at %ld", p->dir_name, p->name, p->value);
	return 0;
}

/* The fine servo: ppm-level drift only (the core does xruns and coarse fixes,
 * and never calls this during the hold after one). The integral is kept
 * across them: it holds the learned clock offset. */
static void pitch_update(void *ctx, double err_avg, double dt)
{
	struct pitch *p = ctx;

	p->integ += err_avg * dt;
	/* anti-windup: the integral alone may not exceed the pitch span */
	if (KI * p->integ >  PITCH_SPAN) p->integ =  PITCH_SPAN / KI;
	if (KI * p->integ < -PITCH_SPAN) p->integ = -PITCH_SPAN / KI;
	double ppm = KP * err_avg + KI * p->integ;
	pitch_set(p, PITCH_START + (long)(p->sign * ppm));
}

static void pitch_describe(void *ctx, char *buf, size_t n)
{
	snprintf(buf, n, "pitch %ld", ((struct pitch *)ctx)->value);
}

static void pitch_stop(void *ctx)
{
	struct pitch *p = ctx;
	if (p->ctl)
		snd_ctl_close(p->ctl);
	p->ctl = NULL;
}

int main(int argc, char **argv)
{
	const char *gadget = "hw:UAC2Gadget", *link = "hw:FPGAmixerLink";
	pthread_t ta, tb;
	int c;

	while ((c = getopt(argc, argv, "g:l:v")) != -1) {
		switch (c) {
		case 'g': gadget = optarg; break;
		case 'l': link = optarg; break;
		case 'v': bridge_verbose = 1; break;
		default:
			fprintf(stderr, "usage: %s [-g gadget] [-l link] [-v]\n", argv[0]);
			return 2;
		}
	}

	/* the ctl device of a "hw:NAME" PCM is "hw:NAME" too */
	struct pitch pa = { .card = gadget, .name = "Capture Pitch 1000000",
			    .dir_name = "A mac->pl", .sign = -1 };
	struct pitch pb = { .card = gadget, .name = "Playback Pitch 1000000",
			    .dir_name = "B pl->mac", .sign = +1 };
	const struct bridge_servo sa = { &pa, pitch_start, pitch_update, pitch_describe, pitch_stop };
	const struct bridge_servo sb = { &pb, pitch_start, pitch_update, pitch_describe, pitch_stop };

	struct bridge_dir a = {
		.name = "A mac->pl", .cap_dev = gadget, .play_dev = link,
		.cap_fmt = SND_PCM_FORMAT_S24_3LE, .play_fmt = SND_PCM_FORMAT_S24_LE,
		.channels = CHANNELS, .rate = RATE, .period = PERIOD, .periods = PERIODS,
		.target = TARGET, .coarse = COARSE, .hold_s = HOLD_S,
		.update_s = UPDATE_MS / 1000.0, .servo = &sa,
	};
	struct bridge_dir b = {
		.name = "B pl->mac", .cap_dev = link, .play_dev = gadget,
		.cap_fmt = SND_PCM_FORMAT_S24_LE, .play_fmt = SND_PCM_FORMAT_S24_3LE,
		.channels = CHANNELS, .rate = RATE, .period = PERIOD, .periods = PERIODS,
		.target = TARGET, .coarse = COARSE, .hold_s = HOLD_S,
		.update_s = UPDATE_MS / 1000.0, .servo = &sb,
	};

	bridge_setup_process(50);
	pthread_create(&ta, NULL, bridge_run, &a);
	pthread_create(&tb, NULL, bridge_run, &b);
	pthread_join(ta, NULL);
	pthread_join(tb, NULL);
	return bridge_failed ? 1 : 0;
}
