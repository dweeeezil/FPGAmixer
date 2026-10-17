// SPDX-License-Identifier: MIT
/*
 * bridge_watch.h: how the bridges notice a PCM that stops without reporting
 * an error, and recover or count it (hardening, findings H-F1, H-F4, H-F5
 * and T6; docs/hardening_status_2026-10-10.md sec. 8). No ALSA, so it is
 * unit-tested on its own (test_bridge_watch.c).
 *
 * 1. A clock-step detector. The AAF plugin's media clock is an ABSOLUTE
 *    timerfd on CLOCK_REALTIME (alsa-plugins 1.2.7.1 aaf/pcm_aaf.c:
 *    timerfd_create(CLOCK_REALTIME), aaf_mclk_start with TFD_TIMER_ABSTIME).
 *    When phc2sys steps that clock BACK by d (the grandmaster's time base
 *    changed: a Mac restarting its gPTP time after a link drop; possibly the
 *    board's first lock at boot, if it booted later than the Mac's
 *    1970-based gPTP time), the timer next fires d later: the talker sends
 *    nothing and reports no error ("no room" on every write), the listener
 *    drops every PDU as "in the past". Stepped FORWARD, it fires d's worth
 *    of periods at once and underruns, an xrun the bridge already recovers
 *    from. A timerfd with TFD_TIMER_CANCEL_ON_SET is woken by every step of
 *    CLOCK_REALTIME (clock_settime, settimeofday, adjtimex ADJ_SETOFFSET:
 *    what phc2sys and date -s use), never by slewing. The bridge then
 *    restarts the PCMs that run on that clock: stop + prepare + start re-arm
 *    the plugin's timer from the new time (aaf_stop -> aaf_mclk_reset,
 *    aaf_prepare, aaf_start).
 *
 * 2. A playback stall watchdog: a playback PCM that is started (or
 *    prepared) but consumes nothing for stall_s is restarted. The backstop
 *    for anything else that silently freezes a sink. Only for sinks that
 *    always consume while running (the AAF talker's own timer, a link card
 *    on mclk), not for the USB gadget's playback, which legitimately waits
 *    while the Mac isn't recording (H-F1).
 *
 * 3. The dropped-period classifier (all bridges): a drop while the playback
 *    consumes nothing is counted as an idle drop, not a coarse fix, so a
 *    real fix stays visible (H-F1, H-F5).
 */
#ifndef BRIDGE_WATCH_H
#define BRIDGE_WATCH_H

#include <errno.h>
#include <stdint.h>
#include <sys/timerfd.h>
#include <time.h>
#include <unistd.h>

/* ----- 1. clock steps ----- */

/* (Re)arm: absolute, ~34 years ahead, so it never expires, only gets
 * cancelled by a step. 0, or -errno. */
static inline int bridge_clockstep_arm(int fd)
{
	struct itimerspec its = { 0 };
	struct timespec now;

	if (clock_gettime(CLOCK_REALTIME, &now) < 0)
		return -errno;
	its.it_value.tv_sec = now.tv_sec + ((time_t)1 << 30);
	if (timerfd_settime(fd, TFD_TIMER_ABSTIME | TFD_TIMER_CANCEL_ON_SET, &its, NULL) < 0)
		return -errno;
	return 0;
}

/* A descriptor that polls readable (POLLIN) when CLOCK_REALTIME is stepped,
 * or -errno. */
static inline int bridge_clockstep_open(void)
{
	int fd = timerfd_create(CLOCK_REALTIME, TFD_NONBLOCK | TFD_CLOEXEC);
	int err;

	if (fd < 0)
		return -errno;
	if ((err = bridge_clockstep_arm(fd)) < 0) {
		close(fd);
		return err;
	}
	return fd;
}

/* 1 if the clock was stepped since the last call, 0 if not, -errno on an
 * error. Non-blocking. The read that returns ECANCELED also resets the
 * detector: it watches for the next step without being re-armed (the
 * kernel's timerfd_canceled; test_bridge_watch.c steps twice). */
static inline int bridge_clockstep_check(int fd)
{
	uint64_t n;

	if (read(fd, &n, sizeof n) >= 0)        /* expired, 34 years on: re-arm */
		return bridge_clockstep_arm(fd);
	if (errno == EAGAIN)
		return 0;
	if (errno != ECANCELED)
		return -errno;
	return 1;
}

/* ----- 2. playback stalls ----- */

struct bridge_stall {
	double stall_s;          /* this long without consuming: stalled. 0: off */
	long   consumed;         /* the most frames consumed seen so far */
	double t_progress;       /* when that grew last (or the PCM restarted, or idled) */
};

/* After a (re)start, with what it has consumed now (0 right after a prefill). */
static inline void bridge_stall_reset(struct bridge_stall *s, long consumed, double now)
{
	s->consumed = consumed;
	s->t_progress = now;
}

/*
 * Called every pass of the loop. active: the PCM is started or prepared (a
 * stopped or xrun PCM is restarted by the next write anyway, and an idle
 * source lets it drain: not a stall); consumed: frames written since the
 * (re)start minus its delay. 1 once it has consumed nothing for stall_s;
 * the caller restarts it and calls bridge_stall_reset.
 */
static inline int bridge_stall_check(struct bridge_stall *s, int active, long consumed,
				     double now)
{
	if (s->stall_s <= 0)
		return 0;
	if (!active || consumed > s->consumed) {
		bridge_stall_reset(s, consumed, now);
		return 0;
	}
	return now - s->t_progress >= s->stall_s;
}

/* ----- 3. dropped periods: idle or a coarse fix (H-F1, H-F5) ----- */

/*
 * The bridge drops a period when the playback queue is full. That is a real
 * coarse fix when the queue ran over while the playback consumes (a clock
 * step, a hiccup), but most drops are IDLE: the playback consumes nothing
 * because the far side isn't reading (the USB gadget while the Mac doesn't
 * record: 20,002 "coarse fixes" in 100 s, H-F1) or the sink is stalled (the
 * AAF talker, H-F5). A drop is idle when the playback consumed nothing since
 * the previous drop; the first drop of a run counts as a coarse fix.
 */
struct bridge_drop {
	long consumed;           /* the most frames consumed seen at a drop */
	int  valid;              /* a drop since the (re)start */
};

static inline void bridge_drop_reset(struct bridge_drop *d)
{
	d->valid = 0;
}

/* At a drop, with the playback's consumed count (as for bridge_stall_check):
 * 1 if idle, 0 if a coarse fix. */
static inline int bridge_drop_idle(struct bridge_drop *d, long consumed)
{
	int idle = d->valid && consumed <= d->consumed;

	if (!d->valid || consumed > d->consumed)
		d->consumed = consumed;
	d->valid = 1;
	return idle;
}

#endif
