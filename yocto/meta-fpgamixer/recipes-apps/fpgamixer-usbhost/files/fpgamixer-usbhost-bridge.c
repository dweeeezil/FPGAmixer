// SPDX-License-Identifier: MIT
/*
 * fpgamixer-usbhost-bridge: the USB-host front door's Linux half (Phase 11).
 * Moves audio both ways between a class-compliant USB interface plugged into
 * the board's Type-A port (the MOTU M2: 2 x 2, S32_LE / 24 bits, its own
 * clock) and a PS<->PL link card (8 ch, S24_LE, mclk time):
 *
 *   A  interface capture -> [resample] -> link playback   (interface ins -> core)
 *   B  link capture      -> [resample] -> interface playback (core -> its outs)
 *
 * The two clocks are unrelated (the interface's crystal vs mclk, which is
 * locked to gPTP), and neither can be steered from here, so each direction
 * resamples (bridge_rate_src, libsamplerate). Its ratio is set by a PI servo
 * on that direction's playback queue, the shape of the USB bridge's pitch
 * servo with a different actuator: a queue above target means too many
 * frames are produced, so the ratio goes down (both directions alike, since
 * the resampler always sits before the playback queue).
 *
 * Only the interface's channels are resampled (2); the link card always
 * opens at 8 and the other 6 get zeros (bridge_core's channel remap).
 *
 * Hot plug: at start the bridge waits for the interface (a 1 s check of its
 * card id, logged once); it exits when the interface goes away and systemd
 * restarts it after RestartSec, back into that wait, so plugging the
 * interface in starts the audio. An unplugged interface is silence on its
 * core channels (pcm_link plays zeros when starved).
 *
 * Usage: fpgamixer-usbhost-bridge [-c CARD_ID] [-l LINK] [-n CHANNELS]
 *                                 [-q fastest|medium|best|linear] [-v]
 *        defaults M2, hw:FPGAmixerLink3, 2, fastest
 * (H.2 ran it against hw:FPGAmixerLink with the USB bridge stopped.)
 */
#define _GNU_SOURCE
#include "bridge_core.h"
#include "bridge_rate_src.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define LINK_CHANNELS 8
#define RATE          48000
#define PERIOD        192        /* frames; 4 ms (the USB bridge's) */
#define PERIODS       4          /* the link allows 2..6 */
#define TARGET        (PERIOD * 2)
#define UPDATE_MS     100
#define RATIO_SPAN    1000.0     /* ppm: clamp around 1 (crystals are +/- 100) */
#define KP            0.5        /* ppm per frame of queue error */
#define KI            0.05       /* ppm per frame-second */
#define COARSE        PERIOD
#define HOLD_S        1.0

/* ----- the servo: queue error -> resampler ratio ----- */

struct ratio_servo {
	const char *dir_name;
	struct rate_src *rs;
	double integ, ppm;
};

static int servo_start(void *ctx)
{
	struct ratio_servo *s = ctx;
	s->integ = 0;
	s->ppm = 0;
	rate_src_set_ratio(s->rs, 1.0);
	return 0;
}

static void servo_update(void *ctx, double err_avg, double dt)
{
	struct ratio_servo *s = ctx;
	s->integ += err_avg * dt;
	/* anti-windup: the integral alone may not exceed the span */
	if (KI * s->integ >  RATIO_SPAN) s->integ =  RATIO_SPAN / KI;
	if (KI * s->integ < -RATIO_SPAN) s->integ = -RATIO_SPAN / KI;
	double ppm = KP * err_avg + KI * s->integ;
	if (ppm >  RATIO_SPAN) ppm =  RATIO_SPAN;
	if (ppm < -RATIO_SPAN) ppm = -RATIO_SPAN;
	s->ppm = ppm;
	rate_src_set_ratio(s->rs, 1.0 - ppm * 1e-6);    /* queue high -> fewer frames */
}

static void servo_describe(void *ctx, char *buf, size_t n)
{
	snprintf(buf, n, "integral %.0f", ((struct ratio_servo *)ctx)->integ);
}

static void servo_stop(void *ctx)
{
	(void)ctx;
}

static int converter_from(const char *q)
{
	if (!strcmp(q, "fastest")) return SRC_SINC_FASTEST;
	if (!strcmp(q, "medium"))  return SRC_SINC_MEDIUM_QUALITY;
	if (!strcmp(q, "best"))    return SRC_SINC_BEST_QUALITY;
	if (!strcmp(q, "linear"))  return SRC_LINEAR;
	return -1;
}

int main(int argc, char **argv)
{
	const char *card = "M2", *link = "hw:FPGAmixerLink3", *quality = "fastest";
	unsigned int channels = 2;
	char dev[64];
	pthread_t ta, tb;
	int c, conv;

	while ((c = getopt(argc, argv, "c:l:n:q:v")) != -1) {
		switch (c) {
		case 'c': card = optarg; break;
		case 'l': link = optarg; break;
		case 'n': channels = (unsigned int)atoi(optarg); break;
		case 'q': quality = optarg; break;
		case 'v': bridge_verbose = 1; break;
		default:
			fprintf(stderr, "usage: %s [-c card id] [-l link] [-n channels] "
				"[-q fastest|medium|best|linear] [-v]\n", argv[0]);
			return 2;
		}
	}
	if ((conv = converter_from(quality)) < 0 || channels < 1 || channels > LINK_CHANNELS) {
		fprintf(stderr, "bad -q or -n\n");
		return 2;
	}
	/* Wait here for the interface, logging once, rather than exiting into a
	 * restart every RestartSec: unplugged is a normal state, not an error. */
	if (snd_card_get_index(card) < 0) {
		bridge_log("interface '%s' not present; waiting for it", card);
		while (snd_card_get_index(card) < 0)
			sleep(1);
		bridge_log("interface '%s' appeared", card);
	}
	snprintf(dev, sizeof dev, "hw:%s", card);

	struct rate_src ra = { .converter = conv, .name = "A usb->pl" };
	struct rate_src rb = { .converter = conv, .name = "B pl->usb" };
	struct ratio_servo sa = { .dir_name = "A usb->pl", .rs = &ra };
	struct ratio_servo sb = { .dir_name = "B pl->usb", .rs = &rb };
	const struct bridge_rate rra = RATE_SRC_OPS(&ra), rrb = RATE_SRC_OPS(&rb);
	const struct bridge_servo ssa = { &sa, servo_start, servo_update, servo_describe, servo_stop };
	const struct bridge_servo ssb = { &sb, servo_start, servo_update, servo_describe, servo_stop };

	struct bridge_dir a = {
		.name = "A usb->pl", .cap_dev = dev, .play_dev = link,
		.cap_fmt = SND_PCM_FORMAT_S32_LE, .play_fmt = SND_PCM_FORMAT_S24_LE,
		.channels = channels, .play_channels = LINK_CHANNELS,
		.rate = RATE, .period = PERIOD, .periods = PERIODS,
		.target = TARGET, .coarse = COARSE, .hold_s = HOLD_S,
		.update_s = UPDATE_MS / 1000.0, .servo = &ssa, .resampler = &rra,
	};
	struct bridge_dir b = {
		.name = "B pl->usb", .cap_dev = link, .play_dev = dev,
		.cap_fmt = SND_PCM_FORMAT_S24_LE, .play_fmt = SND_PCM_FORMAT_S32_LE,
		.channels = LINK_CHANNELS, .play_channels = channels,
		.rate = RATE, .period = PERIOD, .periods = PERIODS,
		.target = TARGET, .coarse = COARSE, .hold_s = HOLD_S,
		.update_s = UPDATE_MS / 1000.0, .servo = &ssb, .resampler = &rrb,
	};

	bridge_log("interface %s (%u ch) <-> %s, resampler %s", dev, channels, link, quality);
	bridge_setup_process(50);
	pthread_create(&ta, NULL, bridge_run, &a);
	pthread_create(&tb, NULL, bridge_run, &b);

	/* Unplugged while running: stop both directions; systemd restarts us. */
	while (!bridge_stop) {
		sleep(1);
		if (snd_card_get_index(card) < 0) {
			bridge_log("interface '%s' gone; stopping", card);
			bridge_failed = 1;
			bridge_stop = 1;
		}
	}
	pthread_join(ta, NULL);
	pthread_join(tb, NULL);
	return bridge_failed ? 1 : 0;
}
