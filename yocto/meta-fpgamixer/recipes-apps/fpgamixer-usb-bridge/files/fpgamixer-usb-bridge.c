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
 * in ppm of 1e6, starting from the board's known mclk offset (+324 ppm).
 * Signs: in A a growing queue means the Mac sends too fast, so its pitch goes
 * down; in B a growing queue means we send too slowly, so our pitch goes up.
 *
 * Everything is logged to stderr (journald under systemd), including the
 * full hw-params space of a device that refuses its setup.
 *
 * Usage: fpgamixer-usb-bridge [-g GADGET] [-l LINK] [-v]
 *        defaults hw:UAC2Gadget, hw:FPGAmixerLink
 */
#define _GNU_SOURCE
#include <alsa/asoundlib.h>
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define CHANNELS      8
#define RATE          48000
#define PERIOD        192        /* frames; 4 ms */
#define PERIODS       4          /* link allows 2..6 */
#define TARGET        (PERIOD * 2)   /* playback queue setpoint, frames */
#define UPDATE_MS     100
#define PITCH_NOMINAL 1000000
#define PITCH_START   1000324    /* measured mclk: 12.2919 MHz = +324 ppm */
#define PITCH_SPAN    1000       /* clamp: +/- 1000 ppm around nominal */
#define KP            0.5        /* ppm per frame of queue error */
#define KI            0.05       /* ppm per frame-second */

static volatile sig_atomic_t stop;
static volatile sig_atomic_t failed;   /* a direction could not start */
static int verbose;

static void logmsg(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
}

static double now_s(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec * 1e-9;
}

/* ----- one PCM, opened in its native format with our geometry ----- */

static int open_pcm(snd_pcm_t **h, const char *dev, snd_pcm_stream_t dir,
		    snd_pcm_format_t fmt, snd_pcm_uframes_t *period,
		    snd_pcm_uframes_t *buffer)
{
	snd_pcm_hw_params_t *hw;
	snd_pcm_sw_params_t *sw;
	const char *what = dir == SND_PCM_STREAM_PLAYBACK ? "playback" : "capture";
	unsigned int rate = RATE;
	int err;

	if ((err = snd_pcm_open(h, dev, dir, 0)) < 0) {
		logmsg("%s %s: open: %s", what, dev, snd_strerror(err));
		return err;
	}
	snd_pcm_hw_params_alloca(&hw);
	snd_pcm_hw_params_any(*h, hw);
	if ((err = snd_pcm_hw_params_set_access(*h, hw, SND_PCM_ACCESS_RW_INTERLEAVED)) < 0 ||
	    (err = snd_pcm_hw_params_set_format(*h, hw, fmt)) < 0 ||
	    (err = snd_pcm_hw_params_set_channels(*h, hw, CHANNELS)) < 0 ||
	    (err = snd_pcm_hw_params_set_rate_near(*h, hw, &rate, 0)) < 0 ||
	    (err = snd_pcm_hw_params_set_period_size_near(*h, hw, period, 0)) < 0 ||
	    (err = snd_pcm_hw_params_set_buffer_size_near(*h, hw, buffer)) < 0 ||
	    (err = snd_pcm_hw_params(*h, hw)) < 0) {
		snd_output_t *out;
		logmsg("%s %s: hw params refused: %s; the device allows:",
		       what, dev, snd_strerror(err));
		snd_output_stdio_attach(&out, stderr, 0);
		snd_pcm_hw_params_any(*h, hw);
		snd_pcm_hw_params_dump(hw, out);
		snd_output_close(out);
		snd_pcm_close(*h);
		*h = NULL;
		return err;
	}
	snd_pcm_hw_params_get_period_size(hw, period, NULL);
	snd_pcm_hw_params_get_buffer_size(hw, buffer);
	if (rate != RATE)
		logmsg("%s %s: rate %u, not %u", what, dev, rate, RATE);

	snd_pcm_sw_params_alloca(&sw);
	snd_pcm_sw_params_current(*h, sw);
	snd_pcm_sw_params_set_avail_min(*h, sw, *period);
	/* playback starts explicitly, after the prefill */
	snd_pcm_sw_params_set_start_threshold(*h, sw,
		dir == SND_PCM_STREAM_PLAYBACK ? *buffer + 1 : 1);
	snd_pcm_sw_params(*h, sw);

	logmsg("%s %s: %s, period %lu, buffer %lu frames", what, dev,
	       snd_pcm_format_name(fmt), *period, *buffer);
	return 0;
}

/* ----- the pitch control on the gadget card ----- */

struct pitch {
	snd_ctl_t *ctl;
	snd_ctl_elem_value_t *val;
	long value;
};

static int pitch_open(struct pitch *p, const char *card, const char *name)
{
	snd_ctl_elem_id_t *id;
	int err;

	if ((err = snd_ctl_open(&p->ctl, card, 0)) < 0) {
		logmsg("ctl %s: %s", card, snd_strerror(err));
		return err;
	}
	snd_ctl_elem_id_malloc(&id);
	snd_ctl_elem_id_set_interface(id, SND_CTL_ELEM_IFACE_PCM);
	snd_ctl_elem_id_set_name(id, name);
	snd_ctl_elem_value_malloc(&p->val);
	snd_ctl_elem_value_set_id(p->val, id);
	snd_ctl_elem_id_free(id);
	if ((err = snd_ctl_elem_read(p->ctl, p->val)) < 0) {
		logmsg("ctl %s: '%s': %s", card, name, snd_strerror(err));
		return err;
	}
	p->value = snd_ctl_elem_value_get_integer(p->val, 0);
	return 0;
}

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

/* ----- one direction ----- */

struct dir {
	const char *name;            /* for the log */
	const char *cap_dev, *play_dev;
	snd_pcm_format_t cap_fmt, play_fmt;
	const char *pitch_name;      /* control on the gadget card */
	int sign;                    /* +1: queue high -> pitch up; -1: down */
	const char *gadget_ctl;      /* ctl name of the gadget card */
};

/* S24_3LE <-> S24_LE (24 bits LSB-justified in 32, sign-extended) */
static void s24_3_to_4(const uint8_t *in, int32_t *out, size_t samples)
{
	for (size_t i = 0; i < samples; i++, in += 3) {
		int32_t v = in[0] | (in[1] << 8) | (in[2] << 16);
		out[i] = (v << 8) >> 8;
	}
}

static void s24_4_to_3(const int32_t *in, uint8_t *out, size_t samples)
{
	for (size_t i = 0; i < samples; i++, out += 3) {
		out[0] = in[i];
		out[1] = in[i] >> 8;
		out[2] = in[i] >> 16;
	}
}

static int prefill(snd_pcm_t *play, snd_pcm_format_t fmt, snd_pcm_uframes_t frames)
{
	size_t bytes = frames * CHANNELS * snd_pcm_format_physical_width(fmt) / 8;
	void *z = calloc(1, bytes);
	int err = snd_pcm_writei(play, z, frames);
	free(z);
	if (err >= 0)
		err = snd_pcm_start(play);
	return err;
}

static void *run_dir(void *arg)
{
	struct dir *d = arg;
	snd_pcm_t *cap = NULL, *play = NULL;
	struct pitch p = { 0 };
	snd_pcm_uframes_t cp = PERIOD, cb = PERIOD * PERIODS;
	snd_pcm_uframes_t pp = PERIOD, pb = PERIOD * PERIODS;
	double integ = 0, err_avg = 0, t_last, t_log;
	long frames_moved = 0, xruns = 0;
	uint8_t *buf3 = NULL;
	int32_t *buf4 = NULL;

	if (open_pcm(&cap, d->cap_dev, SND_PCM_STREAM_CAPTURE, d->cap_fmt, &cp, &cb) < 0 ||
	    open_pcm(&play, d->play_dev, SND_PCM_STREAM_PLAYBACK, d->play_fmt, &pp, &pb) < 0 ||
	    pitch_open(&p, d->gadget_ctl, d->pitch_name) < 0) {
		failed = 1;
		stop = 1;
		goto out;
	}
	pitch_set(&p, PITCH_START);
	logmsg("%s: pitch '%s' starts at %ld", d->name, d->pitch_name, p.value);

	buf3 = malloc(cp * CHANNELS * 3);
	buf4 = malloc(cp * CHANNELS * 4);

	if (prefill(play, d->play_fmt, TARGET) < 0)
		logmsg("%s: prefill failed", d->name);
	snd_pcm_start(cap);
	t_last = t_log = now_s();

	while (!stop) {
		snd_pcm_sframes_t n, w, delay;
		int err;

		/* capture one period (wait with a timeout: an idle Mac sends nothing) */
		err = snd_pcm_wait(cap, 1000);
		if (err == 0)
			continue;
		if (d->cap_fmt == SND_PCM_FORMAT_S24_3LE)
			n = snd_pcm_readi(cap, buf3, cp);
		else
			n = snd_pcm_readi(cap, buf4, cp);
		if (n < 0) {
			xruns++;
			if (verbose)
				logmsg("%s: capture %s", d->name, snd_strerror(n));
			snd_pcm_recover(cap, n, 1);
			snd_pcm_start(cap);
			continue;
		}

		if (d->cap_fmt == SND_PCM_FORMAT_S24_3LE) {
			s24_3_to_4(buf3, buf4, n * CHANNELS);
			w = snd_pcm_writei(play, buf4, n);
		} else {
			s24_4_to_3(buf4, buf3, n * CHANNELS);
			w = snd_pcm_writei(play, buf3, n);
		}
		if (w < 0) {
			xruns++;
			if (verbose)
				logmsg("%s: playback %s", d->name, snd_strerror(w));
			snd_pcm_recover(play, w, 1);
			snd_pcm_drop(play);
			snd_pcm_prepare(play);
			prefill(play, d->play_fmt, TARGET);
			integ = 0;
			continue;
		}
		frames_moved += w;

		/* servo */
		if (snd_pcm_delay(play, &delay) == 0)
			err_avg += 0.2 * ((double)(delay - TARGET) - err_avg);
		double t = now_s();
		if (t - t_last >= UPDATE_MS / 1000.0) {
			integ += err_avg * (t - t_last);
			/* anti-windup: the integral alone may not exceed the pitch span */
			if (KI * integ >  PITCH_SPAN) integ =  PITCH_SPAN / KI;
			if (KI * integ < -PITCH_SPAN) integ = -PITCH_SPAN / KI;
			double ppm = KP * err_avg + KI * integ;
			pitch_set(&p, PITCH_START + (long)(d->sign * ppm));
			t_last = t;
		}
		if (t - t_log >= 10.0) {
			logmsg("%s: %.0f frames/s, queue %+.1f frames from target, pitch %ld, xruns %ld",
			       d->name, frames_moved / (t - t_log), err_avg, p.value, xruns);
			frames_moved = 0;
			t_log = t;
		}
	}
out:
	if (cap) snd_pcm_close(cap);
	if (play) snd_pcm_close(play);
	if (p.ctl) snd_ctl_close(p.ctl);
	free(buf3);
	free(buf4);
	logmsg("%s: stopped", d->name);
	return NULL;
}

static void on_signal(int sig)
{
	(void)sig;
	stop = 1;
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
		case 'v': verbose = 1; break;
		default:
			fprintf(stderr, "usage: %s [-g gadget] [-l link] [-v]\n", argv[0]);
			return 2;
		}
	}

	/* the ctl device of a "hw:NAME" PCM is "hw:NAME" too */
	struct dir a = { "A mac->pl", gadget, link, SND_PCM_FORMAT_S24_3LE,
			 SND_PCM_FORMAT_S24_LE, "Capture Pitch 1000000", -1, gadget };
	struct dir b = { "B pl->mac", link, gadget, SND_PCM_FORMAT_S24_LE,
			 SND_PCM_FORMAT_S24_3LE, "Playback Pitch 1000000", +1, gadget };

	struct sigaction sa = { .sa_handler = on_signal };
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);

	struct sched_param sp = { .sched_priority = 50 };
	if (sched_setscheduler(0, SCHED_FIFO, &sp) < 0 && verbose)
		logmsg("SCHED_FIFO not available (%s); running at normal priority",
		       strerror(errno));

	pthread_create(&ta, NULL, run_dir, &a);
	pthread_create(&tb, NULL, run_dir, &b);
	pthread_join(ta, NULL);
	pthread_join(tb, NULL);
	return failed ? 1 : 0;
}
