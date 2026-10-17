// SPDX-License-Identifier: MIT
/*
 * Unit test for bridge_watch.h (no ALSA needed). Any Linux host; the clock
 * steps need root (they step CLOCK_REALTIME by +-1 ms and back):
 *   gcc -Wall -Wextra -O2 -o t test_bridge_watch.c && sudo ./t
 * Without root the clock-step part prints SKIPPED and the test FAILS, so a
 * run that didn't check the steps can't pass for one that did.
 *
 * Checks:
 *   1. the stall watchdog: off never fires; steady consumption never fires;
 *      no consumption fires exactly stall_s after the last progress, not a
 *      period before; an idle (inactive) PCM never fires and its time
 *      doesn't count once it is active again; a reset restarts the count;
 *      a consumed count that goes back doesn't count as progress;
 *   2. the drop classifier: an idle run (nothing consumed) is one coarse fix
 *      then idle drops; drops while consuming are coarse fixes; a count that
 *      went back is idle; a reset makes the next drop a coarse fix;
 *   3. the clock-step detector: quiet without a step; a step forward and a
 *      step back each wake poll() and read as one step, after which it is
 *      quiet again and still sees the next step; a slew (adjtime) is not a
 *      step.
 */
#define _GNU_SOURCE
#include "bridge_watch.h"

#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/timex.h>

static int fails;

#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL: " __VA_ARGS__); printf("\n"); } } while (0)

#define P (1.0 / 512)            /* ~ one AVB bridge period (2 ms); exact in binary */

static void test_stall(void)
{
	struct bridge_stall s = { .stall_s = 0 };
	double t;
	long c;
	int fired;

	/* off */
	bridge_stall_reset(&s, 0, 0);
	fired = 0;
	for (t = 0; t < 10; t += P)
		fired |= bridge_stall_check(&s, 1, 0, t);
	CHECK(!fired, "stall_s 0 fired");

	/* steady consumption, 96 frames per period, 5 s */
	s.stall_s = 0.5;
	bridge_stall_reset(&s, 0, 0);
	fired = 0;
	for (t = 0, c = 0; t < 5; t += P, c += 96)
		fired |= bridge_stall_check(&s, 1, c, t);
	CHECK(!fired, "steady consumption fired");

	/* consumption stops after 1 s (the last progress at t_last) */
	bridge_stall_reset(&s, 0, 0);
	double t_last = 0;
	for (t = 0, c = 0; t < 1.0; t += P, c += 96) {
		CHECK(!bridge_stall_check(&s, 1, c, t), "fired while consuming at %.3f", t);
		t_last = t;
	}
	long frozen = c - 96;
	CHECK(!bridge_stall_check(&s, 1, frozen, t_last + 0.5 - P),
	      "fired a period before stall_s");
	CHECK(bridge_stall_check(&s, 1, frozen, t_last + 0.5),
	      "didn't fire at stall_s without consumption");
	CHECK(bridge_stall_check(&s, 1, frozen, t_last + 0.7),
	      "stopped firing while still stalled");

	/* a reset (the caller restarted it) counts from there */
	bridge_stall_reset(&s, 0, 10.0);
	CHECK(!bridge_stall_check(&s, 1, 0, 10.4), "fired 0.4 s after a reset");
	CHECK(bridge_stall_check(&s, 1, 0, 10.5), "didn't fire 0.5 s after a reset");

	/* inactive (drained, xrun): never fires; active again, counts from then */
	bridge_stall_reset(&s, 0, 20.0);
	fired = 0;
	for (t = 20.0; t <= 30.0; t += P)          /* last seen inactive at 30.0 */
		fired |= bridge_stall_check(&s, 0, 0, t);
	CHECK(!fired, "an inactive PCM fired");
	CHECK(!bridge_stall_check(&s, 1, 0, 30.0 + 0.5 - P),
	      "the inactive time counted once active");
	CHECK(bridge_stall_check(&s, 1, 0, 30.0 + 0.5),
	      "didn't fire stall_s after becoming active");

	/* a count that goes back is no progress */
	bridge_stall_reset(&s, 1000, 40.0);
	fired = 0;
	for (t = 40.0, c = 900; t < 40.6; t += P, c = c == 900 ? 950 : 900)
		fired |= bridge_stall_check(&s, 1, c, t);
	CHECK(fired, "a count below the last progress counted as progress");
}

static void test_drop(void)
{
	struct bridge_drop d = { 0 };
	int idle = 0, coarse = 0;

	/* the USB start-up case: the Mac isn't recording, every period dropped,
	 * nothing consumed (H-F1: 20,002 "coarse fixes" in 100 s) */
	bridge_drop_reset(&d);
	for (int i = 0; i < 1000; i++)
		bridge_drop_idle(&d, 192) ? idle++ : coarse++;
	CHECK(coarse == 1 && idle == 999, "an idle run: %d coarse, %d idle (want 1, 999)",
	      coarse, idle);

	/* the Mac starts recording: consumption between drops = real fixes */
	idle = coarse = 0;
	for (long c = 192 + 96; c < 192 + 96 * 11; c += 96)
		bridge_drop_idle(&d, c) ? idle++ : coarse++;
	CHECK(coarse == 10 && idle == 0, "drops while consuming: %d coarse, %d idle", coarse, idle);

	/* consumed nothing since the previous drop, a count that went back: idle */
	CHECK(bridge_drop_idle(&d, 192 + 96 * 10), "no consumption since the last drop not idle");
	CHECK(bridge_drop_idle(&d, 100), "a count that went back not idle");
	CHECK(!bridge_drop_idle(&d, 192 + 96 * 10 + 1), "one frame consumed counted idle");

	/* a restart: its first drop is a coarse fix again, whatever the count */
	bridge_drop_reset(&d);
	CHECK(!bridge_drop_idle(&d, 0), "the first drop after a reset counted idle");
	CHECK(bridge_drop_idle(&d, 0), "the second drop after a reset, no consumption, not idle");
	CHECK(!bridge_drop_idle(&d, 96), "consumed since a reset (below the old count) counted idle");
}

/* step CLOCK_REALTIME by ns (may be negative); 0 or -errno */
static int step_clock(long ns)
{
	struct timex tx = { .modes = ADJ_SETOFFSET | ADJ_NANO };
	tx.time.tv_sec = ns / 1000000000L;
	tx.time.tv_usec = ns % 1000000000L;        /* nanoseconds with ADJ_NANO */
	if (tx.time.tv_usec < 0) {
		tx.time.tv_sec -= 1;
		tx.time.tv_usec += 1000000000L;
	}
	return clock_adjtime(CLOCK_REALTIME, &tx) < 0 ? -errno : 0;
}

static int readable(int fd, int ms)
{
	struct pollfd p = { .fd = fd, .events = POLLIN };
	return poll(&p, 1, ms) == 1 && (p.revents & POLLIN);
}

static void test_clockstep(void)
{
	int fd = bridge_clockstep_open();
	CHECK(fd >= 0, "bridge_clockstep_open: %s", fd < 0 ? strerror(-fd) : "");
	if (fd < 0)
		return;

	CHECK(!readable(fd, 50), "readable without a step");
	CHECK(bridge_clockstep_check(fd) == 0, "a step reported without one");

	if (geteuid() != 0) {
		printf("SKIPPED: the clock steps (needs root)\n");
		fails++;
		close(fd);
		return;
	}

	int e = step_clock(1000000);                /* +1 ms */
	CHECK(e == 0, "step +1 ms: %s", strerror(-e));
	CHECK(readable(fd, 200), "not readable after a step forward");
	CHECK(bridge_clockstep_check(fd) == 1, "a step forward not reported");
	CHECK(!readable(fd, 50), "still readable after the check");
	CHECK(bridge_clockstep_check(fd) == 0, "one step reported twice");

	e = step_clock(-1000000);                   /* -1 ms: back where it was */
	CHECK(e == 0, "step -1 ms: %s", strerror(-e));
	CHECK(readable(fd, 200), "not readable after a step back");
	CHECK(bridge_clockstep_check(fd) == 1, "a step back not reported");
	CHECK(bridge_clockstep_check(fd) == 0, "the step back reported twice");

	/* a slew: adjtime's single-shot offset, 100 us, is not a step */
	struct timex tx = { .modes = ADJ_OFFSET_SINGLESHOT, .offset = 100 };
	CHECK(adjtimex(&tx) >= 0, "adjtime slew: %s", strerror(errno));
	CHECK(!readable(fd, 100), "a slew woke the detector");
	CHECK(bridge_clockstep_check(fd) == 0, "a slew reported as a step");

	close(fd);
}

int main(void)
{
	test_stall();
	test_drop();
	test_clockstep();
	printf(fails ? "FAIL test_bridge_watch (%d)\n" : "PASS test_bridge_watch\n", fails);
	return fails != 0;
}
