#!/usr/bin/env python3
"""
fpgamixer-mediaclock: locks the audio clock (mclk) to gPTP time.
Phase 9, P9.4b (docs/phase9_status_2026-09-26.md, decisions S1-S5).

Once per gPTP second the PL's media-clock meter (window "mclk") captures, on
the 1PPS from the board's own PHC:
  - the mclk cycle count  -> the frequency error over the last second,
  - the frame phase       -> where in the 256-cycle frame grid the gPTP
                             second fell.
This service turns those into a frequency correction and writes it to the
steering window ("mclkctl"), which slews mclk through the MMCM's fine phase
shift. The PL only measures and steps (decision S3); the loop lives here.

Lock target (S4): every gPTP second starts at the same frame phase (TARGET
cycles, default 0), i.e. 48,000 frames per gPTP second exactly and a fixed
alignment of the frame grid to gPTP time -- the AVB media-clock relation. It
holds in either gPTP role, because the PPS is the board's own PHC.

States:
  ACQUIRE   frequency first: take out the measured frequency error (most of
            it each second) until it is small for a few seconds.
  LOCKED    phase: a type-2 loop (PI on the phase error, time constant TAU);
            the integrator carries the frequency. TAU = 5 s by default: a
            type-2 loop holds a frequency RAMP only with a standing phase
            error of ramp x TAU x 4 TAU, and the crystals drift ~0.5 ppm/min
            after power-up (P9.3); TAU = 20 s would slip half a frame under
            that (13 us), 5 s keeps it under 1 us, while the steady phase
            noise stays at the meter's +/-1 cycle (test_mediaclock).
  HOLDOVER  the reference is gone or jumped (no PPS, an implausible interval:
            a PHC step, ptp4l restarting): the correction is FROZEN (S5),
            never stepped; back to ACQUIRE when valid intervals return.
mclk is only ever slewed, never stepped, and the correction is clamped to
what the MMCM can do (MediaClockSteerHW.max_ppm).

Sign conventions (all in ppm, + = mclk faster): the meter's error is +
when mclk runs fast; the phase error is + when the frame grid runs ahead of
gPTP; the correction written is + to speed mclk up.

    python3 mediaclock.py [--tau S] [--target CYCLES] [--dry-run] [-v]
"""

import argparse
import sys
import time

NOMINAL_HZ = 12_288_000
FRAME = 256


def wrap_phase(cycles, frame=FRAME):
    """A phase difference in cycles, wrapped into [-frame/2, frame/2)."""
    return ((cycles + frame // 2) % frame) - frame // 2


class MediaClockLoop:
    """The control law, with no I/O: feed it one reference second at a time.

    update(interval_cycles, phase_cycles, valid) -> correction in ppm.
      interval_cycles  mclk cycles counted over the last gPTP second
      phase_cycles     frame phase at that second (0 .. FRAME-1)
      valid            False for an implausible / missing second
    """

    ACQ_GAIN = 0.8          # share of the measured frequency error removed per second
    ACQ_DONE_PPM = 0.2      # frequency error below which acquisition ends ...
    ACQ_DONE_SECONDS = 3    # ... for this many seconds in a row

    def __init__(self, nominal_hz=NOMINAL_HZ, max_ppm=80.0, tau_s=5.0,
                 target_cycles=0, damping_tau_mult=4.0):
        self.nominal = nominal_hz
        self.max_ppm = max_ppm
        self.tau = tau_s
        self.tau_i = tau_s * damping_tau_mult
        self.target = target_cycles
        self.state = "ACQUIRE"
        self.u_int = 0.0            # the frequency part of the correction
        self.u = 0.0                # the correction applied (ppm, + = faster)
        self.acq_count = 0
        self.last_freq_ppm = None
        self.last_phase_err = None

    def _clamp(self, v):
        return max(-self.max_ppm, min(self.max_ppm, v))

    def update(self, interval_cycles, phase_cycles, valid=True):
        if not valid:
            self.state = "HOLDOVER"          # freeze: u stays what it was
            self.acq_count = 0
            return self.u

        freq_ppm = (interval_cycles / self.nominal - 1.0) * 1e6
        err_cycles = wrap_phase(phase_cycles - self.target)
        err_s = err_cycles / self.nominal
        self.last_freq_ppm, self.last_phase_err = freq_ppm, err_cycles

        if self.state == "HOLDOVER":
            self.state = "ACQUIRE"

        if self.state == "ACQUIRE":
            self.u_int = self._clamp(self.u_int - self.ACQ_GAIN * freq_ppm)
            self.u = self.u_int
            self.acq_count = self.acq_count + 1 if abs(freq_ppm) < self.ACQ_DONE_PPM else 0
            if self.acq_count >= self.ACQ_DONE_SECONDS:
                self.state = "LOCKED"
            return self.u

        # LOCKED: PI on the phase error. A phase error of e seconds is removed
        # over ~TAU seconds by a frequency offset of e / TAU.
        self.u_int = self._clamp(self.u_int - err_s / (self.tau * self.tau_i) * 1e6)
        self.u = self._clamp(self.u_int - err_s / self.tau * 1e6)
        return self.u


def run(args):
    import mixer_hw
    meter = mixer_hw.open_window("mclk")
    steer = None if args.dry_run else mixer_hw.open_window("mclkctl")
    max_ppm = steer.max_ppm * 0.95 if steer else 80.0
    loop = MediaClockLoop(nominal_hz=meter.nominal, max_ppm=max_ppm,
                          tau_s=args.tau, target_cycles=args.target)
    if steer:
        # start from whatever is set now (a restart keeps the learned frequency)
        loop.u = loop.u_int = steer.get_ppm()
    print(f"mediaclock: start, correction {loop.u:+.4f} ppm, tau {args.tau:g} s, "
          f"target phase {args.target}, max {max_ppm:.1f} ppm"
          f"{' (dry run)' if args.dry_run else ''}", flush=True)

    last = meter.read_all()
    t_log = time.monotonic()
    while True:
        time.sleep(0.2)
        v = meter.read_all()
        new = (v["pps_count"] - last["pps_count"]) & 0xFFFF_FFFF
        if new == 0:
            if last["pps_count"] and not meter.ref_alive(v) and loop.state != "HOLDOVER":
                loop.update(0, 0, valid=False)      # PPS stopped: freeze
                print("mediaclock: reference lost, HOLDOVER", flush=True)
            continue
        valid = (new == 1 and v["implausible"] == last["implausible"]
                 and last["pps_count"] != 0)
        was = loop.state
        u = loop.update(meter.interval(v), v["phase_at_pps"], valid=valid)
        if steer:
            steer.set_ppm(u)
        if loop.state != was:
            print(f"mediaclock: {was} -> {loop.state}", flush=True)
        now = time.monotonic()
        if args.verbose or now - t_log >= 10:
            t_log = now
            f = loop.last_freq_ppm
            e = loop.last_phase_err
            print(f"mediaclock: {loop.state:8} freq {f:+8.3f} ppm  "
                  f"phase {e:+4d} cycles ({e / meter.nominal * 1e9:+7.0f} ns)  "
                  f"correction {u:+8.4f} ppm", flush=True)
        last = v


def main(argv=None):
    p = argparse.ArgumentParser(description="Lock mclk to gPTP time (P9.4b)")
    p.add_argument("--tau", type=float, default=5.0,
                   help="phase-loop time constant in seconds (default 5)")
    p.add_argument("--target", type=int, default=0,
                   help="frame phase (mclk cycles, 0..255) to hold at each gPTP second")
    p.add_argument("--dry-run", action="store_true",
                   help="compute and log, but don't write the steering register")
    p.add_argument("-v", "--verbose", action="store_true", help="log every second")
    args = p.parse_args(argv)
    try:
        run(args)
    except KeyboardInterrupt:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
