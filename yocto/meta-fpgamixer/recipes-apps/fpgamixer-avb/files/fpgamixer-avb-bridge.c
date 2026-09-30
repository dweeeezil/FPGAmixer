// SPDX-License-Identifier: MIT
/*
 * fpgamixer-avb-bridge: the AVB front door's Linux half, part 2 (Phase 9,
 * P9.7; docs/phase9_status_2026-09-26.md sec. 6.15-6.16).
 *
 * Moves 8 channels each way between the AAF devices (the alsa-plugins AAF
 * plugin, set up by fpgamixer-avb-net) and link #2 (FPGAmixerLink2):
 *
 *   A: network -> core   avb_rx capture (S24_3BE)  -> FPGAmixerLink2 playback (S24_LE)
 *   B: core -> network   FPGAmixerLink2 capture (S24_LE) -> avb_tx playback (S24_3BE)
 *
 * NO rate servo (decision V2): the AAF plugin runs on CLOCK_REALTIME, which
 * phc2sys locks to the PHC, and the link runs on mclk, which
 * fpgamixer-mediaclock locks to the same PHC. The two sides can't drift, so
 * each playback queue is simply held at a fixed target. bridge_core's coarse
 * fix and xrun recovery stay as safety nets: in steady state both counts
 * must stay at 0; a nonzero count is a fault to investigate, not to tune.
 * Expected, and logged: xruns on A when the talker stops or starts (the
 * plugin's listener overruns when no PDUs arrive), and around a gPTP
 * reference step (phc2sys steps CLOCK_REALTIME, mclk only slews).
 *
 * Latency is constant, not aligned to the AVTP presentation time (decision
 * V4: the plugin doesn't expose presentation times to the application).
 *
 * The AAF devices need root (AF_PACKET). The geometry comes from
 * /etc/fpgamixer/avb.conf [bridge] through fpgamixer-avb-net, which checks it
 * and writes the arguments to /run/fpgamixer/avb-bridge.env.
 *
 * Formats (Phase 10): the AAF devices run S24_3BE (AAF INT_24BIT) or S32_BE
 * (AAF INT_32BIT with bit_depth 24, Milan's base format), per direction, as
 * the AVDECC entity (avb_entityd) has set the stream formats.
 *
 * Usage: fpgamixer-avb-bridge [-r RX] [-t TX] [-l LINK] [-p PERIOD]
 *                             [-n PERIODS] [-q QUEUE_PERIODS]
 *                             [-F RX_FORMAT] [-G TX_FORMAT] [-v]
 *        defaults avb_rx, avb_tx, hw:FPGAmixerLink2, 96 frames, 4, 2,
 *        S24_3BE, S24_3BE
 */
#define _GNU_SOURCE
#include "bridge_core.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define CHANNELS 8
#define RATE     48000
#define HOLD_S   1.0

int main(int argc, char **argv)
{
	const char *rx = "avb_rx", *tx = "avb_tx", *link = "hw:FPGAmixerLink2";
	unsigned long period = 96, periods = 4, queue = 2;
	snd_pcm_format_t rx_fmt = SND_PCM_FORMAT_S24_3BE, tx_fmt = SND_PCM_FORMAT_S24_3BE;
	pthread_t ta, tb;
	int c;

	while ((c = getopt(argc, argv, "r:t:l:p:n:q:F:G:v")) != -1) {
		switch (c) {
		case 'r': rx = optarg; break;
		case 't': tx = optarg; break;
		case 'l': link = optarg; break;
		case 'p': period = strtoul(optarg, NULL, 0); break;
		case 'n': periods = strtoul(optarg, NULL, 0); break;
		case 'q': queue = strtoul(optarg, NULL, 0); break;
		case 'F': rx_fmt = snd_pcm_format_value(optarg); break;
		case 'G': tx_fmt = snd_pcm_format_value(optarg); break;
		case 'v': bridge_verbose = 1; break;
		default:
			fprintf(stderr, "usage: %s [-r rx] [-t tx] [-l link] [-p period] "
				"[-n periods] [-q queue_periods] [-F rx_format] [-G tx_format] "
				"[-v]\n", argv[0]);
			return 2;
		}
	}
	if ((rx_fmt != SND_PCM_FORMAT_S24_3BE && rx_fmt != SND_PCM_FORMAT_S32_BE) ||
	    (tx_fmt != SND_PCM_FORMAT_S24_3BE && tx_fmt != SND_PCM_FORMAT_S32_BE)) {
		fprintf(stderr, "%s: the AAF formats are S24_3BE or S32_BE\n", argv[0]);
		return 2;
	}
	if (period == 0 || period % 6 || periods < 2 || queue < 1 || queue >= periods) {
		fprintf(stderr, "%s: period must be a multiple of 6 frames (frames_per_pdu), "
			"periods >= 2, 1 <= queue < periods\n", argv[0]);
		return 2;
	}

	struct bridge_dir a = {
		.name = "A net->core", .cap_dev = rx, .play_dev = link,
		.cap_fmt = rx_fmt, .play_fmt = SND_PCM_FORMAT_S24_LE,
		.channels = CHANNELS, .rate = RATE, .period = period, .periods = periods,
		.target = period * queue, .coarse = period, .hold_s = HOLD_S,
		.update_s = 1.0, .servo = NULL,
	};
	struct bridge_dir b = {
		.name = "B core->net", .cap_dev = link, .play_dev = tx,
		.cap_fmt = SND_PCM_FORMAT_S24_LE, .play_fmt = tx_fmt,
		.channels = CHANNELS, .rate = RATE, .period = period, .periods = periods,
		.target = period * queue, .coarse = period, .hold_s = HOLD_S,
		.update_s = 1.0, .servo = NULL,
	};

	bridge_log("fpgamixer-avb-bridge: %s (%s) -> %s and %s -> %s (%s), period %lu "
		   "frames, %lu periods, queue %lu periods; no servo (both sides on the PHC)",
		   rx, snd_pcm_format_name(rx_fmt), link, link, tx,
		   snd_pcm_format_name(tx_fmt), period, periods, queue);
	bridge_setup_process(50);
	pthread_create(&ta, NULL, bridge_run, &a);
	pthread_create(&tb, NULL, bridge_run, &b);
	pthread_join(ta, NULL);
	pthread_join(tb, NULL);
	return bridge_failed ? 1 : 0;
}
