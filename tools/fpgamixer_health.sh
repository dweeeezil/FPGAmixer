#!/bin/sh
# fpgamixer-health -- one summary of the board's health (hardening T4,
# docs/hardening_status_2026-10-10.md): run it at the start and the end of a
# soak and compare the two. Counters are cumulative (the PL's since power-up,
# a bridge's since its process started: compare NRestarts too).
#
#   sudo fpgamixer-health
#
# Installed by the fpgamixer-osc recipe as /usr/bin/fpgamixer-health; it
# needs root for /dev/mem (mixer_hw.py) and the journal.

LIB=/usr/lib/fpgamixer
[ -f "$LIB/mixer_hw.py" ] || LIB=$(dirname "$0")

echo "== $(hostname) $(date -u +%Y-%m-%dT%H:%M:%SZ), up $(cut -d' ' -f1 /proc/uptime | cut -d. -f1) s, $(cat "$LIB/VERSION" 2>/dev/null)"
echo "== load $(cut -d' ' -f1-3 /proc/loadavg), mem free $(awk '/MemAvailable/ {print int($2/1024) " MB"}' /proc/meminfo)"

echo "== services (state, restarts since boot)"
for u in fpgamixer-osc fpgamixer-ptp4l fpgamixer-phc2sys fpgamixer-mediaclock \
         fpgamixer-usb-gadget fpgamixer-usb-bridge fpgamixer-usbhost-bridge \
         fpgamixer-avb-net fpgamixer-avb-entity fpgamixer-avb-bridge; do
    systemctl show "$u" -p ActiveState -p SubState -p NRestarts 2>/dev/null |
        tr '\n' ' ' | sed "s/^/  $u: /; s/ActiveState=//; s/SubState=//; s/NRestarts=/restarts /"
    echo
done

echo "== gPTP (last 60 ptp4l offsets, ns)"
journalctl -u fpgamixer-ptp4l -b -n 400 --no-pager -o cat 2>/dev/null |
    awk '/master offset/ { for (i = 1; i <= NF; i++) if ($i == "offset") v = $(i + 1);
                           a[n++ % 60] = v < 0 ? -v : v; last = v; s = $0 }
         END { if (!n) { print "  no offsets logged"; exit }
               m = 0; k = n < 60 ? n : 60
               for (i = 0; i < k; i++) if (a[i] > m) m = a[i]
               print "  last " last ", max |offset| " m " over " k " samples" }'
journalctl -u fpgamixer-ptp4l -b --no-pager -o cat 2>/dev/null |
    grep -ciE 'timed out|fault|UNCALIBRATED' | sed 's/^/  faults\/timeouts\/uncalibrated since boot: /'

echo "== bridges (latest status line: cumulative since the process started)"
for u in fpgamixer-usb-bridge fpgamixer-usbhost-bridge fpgamixer-avb-bridge; do
    l=$(journalctl -u "$u" -b -n 200 --no-pager -o cat 2>/dev/null | grep 'xruns' | tail -1)
    echo "  $u: ${l:-no status line}"
done
l=$(journalctl -u fpgamixer-mediaclock -b -n 50 --no-pager -o cat 2>/dev/null | tail -1)
echo "  fpgamixer-mediaclock: ${l:-nothing logged}"

echo "== PL"
python3 "$LIB/mixer_hw.py" health 2>&1 | sed 's/^/  /'
