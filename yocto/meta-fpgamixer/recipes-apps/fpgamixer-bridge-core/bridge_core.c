// SPDX-License-Identifier: MIT
/*
 * bridge_core.c: see bridge_core.h. The logic (prefill, coarse fix, hold,
 * filtered queue error, 10 s log line) is the Phase 8 USB bridge's, moved
 * here unchanged except for the wait: one poll over both PCMs instead of a
 * blocking read on the capture side (the reason is in bridge_core.h).
 */
#define _GNU_SOURCE
#include "bridge_core.h"
#include "bridge_convert.h"

#include <errno.h>
#include <poll.h>
#include <sched.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define MAX_PFD    16
#define LOG_S      10.0
#define IDLE_MS    1000      /* poll timeout: an idle source sends nothing */

volatile sig_atomic_t bridge_stop;
volatile sig_atomic_t bridge_failed;
int bridge_verbose;

void bridge_log(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
}

double bridge_now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static void on_signal(int sig)
{
	(void)sig;
	bridge_stop = 1;
}

void bridge_setup_process(int prio)
{
	struct sigaction sa = { .sa_handler = on_signal };
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);

	struct sched_param sp = { .sched_priority = prio };
	if (sched_setscheduler(0, SCHED_FIFO, &sp) < 0 && bridge_verbose)
		bridge_log("SCHED_FIFO not available (%s); running at normal priority",
			   strerror(errno));
}

/* ----- formats ----- */

static int fmt_ok(snd_pcm_format_t f)
{
	return f == SND_PCM_FORMAT_S24_LE || f == SND_PCM_FORMAT_S24_3LE ||
	       f == SND_PCM_FORMAT_S24_3BE;
}

/* in (cap_fmt) -> the int32 staging buffer -> out (play_fmt) */
static void repack(const void *in, snd_pcm_format_t in_fmt, int32_t *mid,
		   void *out, snd_pcm_format_t out_fmt, size_t samples)
{
	const int32_t *src = mid;

	switch (in_fmt) {
	case SND_PCM_FORMAT_S24_3LE: s24_3le_to_s32(in, mid, samples); break;
	case SND_PCM_FORMAT_S24_3BE: s24_3be_to_s32(in, mid, samples); break;
	default: src = in; break;                      /* S24_LE already */
	}
	switch (out_fmt) {
	case SND_PCM_FORMAT_S24_3LE: s32_to_s24_3le(src, out, samples); break;
	case SND_PCM_FORMAT_S24_3BE: s32_to_s24_3be(src, out, samples); break;
	default: memcpy(out, src, samples * 4); break;
	}
}

/* ----- PCM setup ----- */

static int open_pcm(snd_pcm_t **h, const struct bridge_dir *d, const char *dev,
		    snd_pcm_stream_t dir, snd_pcm_format_t fmt,
		    snd_pcm_uframes_t *period, snd_pcm_uframes_t *buffer)
{
	snd_pcm_hw_params_t *hw;
	snd_pcm_sw_params_t *sw;
	const char *what = dir == SND_PCM_STREAM_PLAYBACK ? "playback" : "capture";
	unsigned int rate = d->rate;
	int err;

	if ((err = snd_pcm_open(h, dev, dir, SND_PCM_NONBLOCK)) < 0) {
		bridge_log("%s %s: open: %s", what, dev, snd_strerror(err));
		return err;
	}
	snd_pcm_hw_params_alloca(&hw);
	snd_pcm_hw_params_any(*h, hw);
	if ((err = snd_pcm_hw_params_set_access(*h, hw, SND_PCM_ACCESS_RW_INTERLEAVED)) < 0 ||
	    (err = snd_pcm_hw_params_set_format(*h, hw, fmt)) < 0 ||
	    (err = snd_pcm_hw_params_set_channels(*h, hw, d->channels)) < 0 ||
	    (err = snd_pcm_hw_params_set_rate_near(*h, hw, &rate, 0)) < 0 ||
	    (err = snd_pcm_hw_params_set_period_size_near(*h, hw, period, 0)) < 0 ||
	    (err = snd_pcm_hw_params_set_buffer_size_near(*h, hw, buffer)) < 0 ||
	    (err = snd_pcm_hw_params(*h, hw)) < 0) {
		snd_output_t *out;
		bridge_log("%s %s: hw params refused: %s; the device allows:",
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
	if (rate != d->rate)
		bridge_log("%s %s: rate %u, not %u", what, dev, rate, d->rate);

	snd_pcm_sw_params_alloca(&sw);
	snd_pcm_sw_params_current(*h, sw);
	/*
	 * Capture wakes the poll per period. Playback only matters to the poll
	 * when it is (nearly) empty: with avail_min = buffer a hw playback PCM
	 * doesn't wake it all the time; an ioplug (AAF) PCM's descriptor is its
	 * own timer, whatever avail_min says.
	 */
	snd_pcm_sw_params_set_avail_min(*h, sw,
		dir == SND_PCM_STREAM_PLAYBACK ? *buffer : *period);
	/* playback starts explicitly, after the prefill */
	snd_pcm_sw_params_set_start_threshold(*h, sw,
		dir == SND_PCM_STREAM_PLAYBACK ? *buffer + 1 : 1);
	snd_pcm_sw_params(*h, sw);

	bridge_log("%s %s: %s, period %lu, buffer %lu frames", what, dev,
		   snd_pcm_format_name(fmt), *period, *buffer);
	return 0;
}

static void write_silence(snd_pcm_t *play, const struct bridge_dir *d,
			  snd_pcm_uframes_t frames)
{
	size_t bytes = frames * d->channels *
		       snd_pcm_format_physical_width(d->play_fmt) / 8;
	void *z = calloc(1, bytes);
	snd_pcm_writei(play, z, frames);
	free(z);
}

static void prefill(snd_pcm_t *play, const struct bridge_dir *d)
{
	write_silence(play, d, d->target);
	snd_pcm_start(play);
}

static void restart_play(snd_pcm_t *play, const struct bridge_dir *d, int err)
{
	snd_pcm_recover(play, err, 1);
	snd_pcm_drop(play);
	snd_pcm_prepare(play);
	prefill(play, d);
}

static void restart_cap(snd_pcm_t *cap, int err)
{
	snd_pcm_recover(cap, err, 1);
	snd_pcm_drop(cap);
	snd_pcm_prepare(cap);
	snd_pcm_start(cap);
}

/* ----- one direction ----- */

void *bridge_run(void *arg)
{
	struct bridge_dir *d = arg;
	const struct bridge_servo *sv = d->servo;
	snd_pcm_t *cap = NULL, *play = NULL;
	snd_pcm_uframes_t cp = d->period, cb = d->period * d->periods;
	snd_pcm_uframes_t pp = d->period, pb = d->period * d->periods;
	double err_avg = 0, t_last, t_log, t_hold = 0;
	long frames_moved = 0, xruns_cap = 0, xruns_play = 0, coarse = 0;
	void *inbuf = NULL, *outbuf = NULL;
	int32_t *mid = NULL;
	int servo_on = 0;

	if (!fmt_ok(d->cap_fmt) || !fmt_ok(d->play_fmt)) {
		bridge_log("%s: unsupported format", d->name);
		goto fail;
	}
	if (open_pcm(&cap, d, d->cap_dev, SND_PCM_STREAM_CAPTURE, d->cap_fmt, &cp, &cb) < 0 ||
	    open_pcm(&play, d, d->play_dev, SND_PCM_STREAM_PLAYBACK, d->play_fmt, &pp, &pb) < 0)
		goto fail;
	if (cp != pp)
		bridge_log("%s: capture period %lu != playback period %lu", d->name, cp, pp);
	if (sv) {
		if (sv->start(sv->ctx) < 0)
			goto fail;
		servo_on = 1;
	}

	inbuf  = malloc(cp * d->channels * 4);
	outbuf = malloc(cp * d->channels * 4);
	mid    = malloc(cp * d->channels * sizeof(int32_t));

	prefill(play, d);
	snd_pcm_start(cap);
	t_last = t_log = bridge_now();

	while (!bridge_stop) {
		struct pollfd pfd[MAX_PFD];
		unsigned short crev = 0, prev = 0;
		int nc, np, err;
		snd_pcm_sframes_t av, delay;

		nc = snd_pcm_poll_descriptors(cap, pfd, MAX_PFD);
		/*
		 * Playback is polled only while it runs. A drained hw playback
		 * (e.g. while the source is idle) sits in XRUN, and its
		 * descriptor would then report an error on every poll: a busy
		 * loop. Stopped, it is restarted by the next write instead, as
		 * the Phase 8 bridge did.
		 */
		np = snd_pcm_state(play) == SND_PCM_STATE_RUNNING ?
		     snd_pcm_poll_descriptors(play, pfd + nc, MAX_PFD - nc) : 0;
		if (nc < 0 || np < 0) {
			bridge_log("%s: poll descriptors: %s", d->name,
				   snd_strerror(nc < 0 ? nc : np));
			goto fail;
		}
		err = poll(pfd, nc + np, IDLE_MS);
		if (err < 0 && errno != EINTR) {
			bridge_log("%s: poll: %s", d->name, strerror(errno));
			goto fail;
		}
		if (err <= 0)
			continue;                        /* idle, or a signal */

		/* Let both PCMs handle their events: for the AAF plugin this is
		 * where a timer tick transmits a period (playback) or presents
		 * one (capture), and where received PDUs are taken in. */
		err = np > 0 ? snd_pcm_poll_descriptors_revents(play, pfd + nc, np, &prev) : 0;
		if (err < 0) {
			xruns_play++;
			if (bridge_verbose)
				bridge_log("%s: playback %s", d->name, snd_strerror(err));
			restart_play(play, d, err);
			t_hold = bridge_now() + d->hold_s;
			err_avg = 0;
			continue;
		}
		err = snd_pcm_poll_descriptors_revents(cap, pfd, nc, &crev);
		if (err < 0) {
			av = err;
			goto cap_xrun;
		}

		av = snd_pcm_avail_update(cap);
		if (av < 0)
			goto cap_xrun;

		while (av >= (snd_pcm_sframes_t)cp && !bridge_stop) {
			snd_pcm_sframes_t n, w;

			n = snd_pcm_readi(cap, inbuf, cp);
			if (n == -EAGAIN)
				break;
			if (n < 0) {
				av = n;
				goto cap_xrun;
			}
			av -= n;

			/*
			 * Coarse correction, before anything else: a queue more
			 * than `coarse` over target is drained by dropping this
			 * period; one more than `coarse` under is topped up with
			 * silence below. (The USB bridge's start-up case: the
			 * gadget's IN stream only runs once the Mac opens its
			 * inputs; Phase 8, 2026-09-26.) A servo keeps its state.
			 */
			if (snd_pcm_delay(play, &delay) == 0 &&
			    delay > (snd_pcm_sframes_t)(d->target + d->coarse)) {
				coarse++;
				t_hold = bridge_now() + d->hold_s;
				err_avg = 0;
				continue;
			}

			repack(inbuf, d->cap_fmt, mid, outbuf, d->play_fmt, n * d->channels);
			w = snd_pcm_writei(play, outbuf, n);
			if (w == -EAGAIN) {              /* no room: treat as too full */
				coarse++;
				t_hold = bridge_now() + d->hold_s;
				err_avg = 0;
				continue;
			}
			if (w < 0) {
				xruns_play++;
				if (bridge_verbose)
					bridge_log("%s: playback %s", d->name, snd_strerror(w));
				restart_play(play, d, w);
				t_hold = bridge_now() + d->hold_s;
				err_avg = 0;
				continue;
			}
			frames_moved += w;

			if (snd_pcm_delay(play, &delay) == 0 &&
			    delay < (snd_pcm_sframes_t)d->target - (snd_pcm_sframes_t)d->coarse) {
				write_silence(play, d, d->target - delay);
				coarse++;
				t_hold = bridge_now() + d->hold_s;
				err_avg = 0;
			}

			if (snd_pcm_delay(play, &delay) == 0)
				err_avg += 0.2 * ((double)(delay - (snd_pcm_sframes_t)d->target) - err_avg);
		}

		double t = bridge_now();
		/* After an xrun or a coarse fix the queue restarts near the
		 * setpoint and the filter restarts; a servo sits out hold_s so
		 * the transient isn't integrated. */
		if (t < t_hold) {
			t_last = t;
		} else if (sv && t - t_last >= d->update_s) {
			sv->update(sv->ctx, err_avg, t - t_last);
			t_last = t;
		}
		if (t - t_log >= LOG_S) {
			char extra[96] = "";
			if (sv && sv->describe)
				sv->describe(sv->ctx, extra, sizeof extra);
			bridge_log("%s: %.0f frames/s, queue %+.1f frames from target%s%s, "
				   "xruns %ld/%ld (capture/playback), coarse fixes %ld",
				   d->name, frames_moved / (t - t_log), err_avg,
				   extra[0] ? ", " : "", extra, xruns_cap, xruns_play, coarse);
			frames_moved = 0;
			t_log = t;
		}
		continue;

cap_xrun:
		xruns_cap++;
		if (bridge_verbose)
			bridge_log("%s: capture %s", d->name, snd_strerror((int)av));
		restart_cap(cap, (int)av);
		t_hold = bridge_now() + d->hold_s;
		err_avg = 0;
	}
	goto out;

fail:
	bridge_failed = 1;
	bridge_stop = 1;
out:
	if (servo_on && sv->stop)
		sv->stop(sv->ctx);
	if (cap) snd_pcm_close(cap);
	if (play) snd_pcm_close(play);
	free(inbuf);
	free(outbuf);
	free(mid);
	bridge_log("%s: stopped", d->name);
	return NULL;
}
