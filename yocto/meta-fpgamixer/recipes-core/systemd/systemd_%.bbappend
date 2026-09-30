# FPGAmixer (Phase 10): no systemd-timesyncd. The board's time comes from
# gPTP (ptp4l + phc2sys, fpgamixer-gptp), and on the AVB bench that is the
# grandmaster's timescale (a Mac's: seconds since its boot, so 1970), not
# UTC. A second time service can only fight phc2sys; on the bench it was
# running while phc2sys failed to step (docs/phase10_status_2026-09-29.md
# sec. 13-14), whether or not it was the cause. Decided 2026-09-30.
PACKAGECONFIG:remove = "timesyncd"
