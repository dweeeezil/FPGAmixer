#!/usr/bin/env python3
"""Mutants of bridge_watch.h against test_bridge_watch.c (hardening, H-F4).

On any Linux host, as root (the test steps the clock), in this directory:
    sudo python3 mutate_bridge_watch.py
Each mutant must make the test FAIL; work copies in /tmp/bwm.
"""
import os, subprocess, shutil, sys

SRC = open("bridge_watch.h").read()
M = [
    ("progress: any change", "consumed > s->consumed", "consumed != s->consumed"),
    ("stall: > instead of >=", "now - s->t_progress >= s->stall_s", "now - s->t_progress > s->stall_s"),
    ("inactive not reset", "if (!active || consumed", "if (consumed"),
    ("off check < 0", "if (s->stall_s <= 0)", "if (s->stall_s < 0)"),
    ("progress keeps old time", "\t\tbridge_stall_reset(s, consumed, now);\n\t\treturn 0;",
     "\t\ts->consumed = consumed;\n\t\treturn 0;"),
    ("no CANCEL_ON_SET", "TFD_TIMER_ABSTIME | TFD_TIMER_CANCEL_ON_SET", "TFD_TIMER_ABSTIME"),
    ("a step reads as 0", "\t\treturn -errno;\n\treturn 1;", "\t\treturn -errno;\n\treturn 0;"),
    ("a step reads as an error", "if (errno != ECANCELED)", "if (errno == ECANCELED)"),
    ("EAGAIN reads as a step", "if (errno == EAGAIN)\n\t\treturn 0;", "if (errno == EAGAIN)\n\t\treturn 1;"),
    ("drop: < instead of <=", "int idle = d->valid && consumed <= d->consumed;", "int idle = d->valid && consumed < d->consumed;"),
    ("drop: no valid check", "int idle = d->valid && consumed", "int idle = consumed"),
    ("drop: reset keeps the old count", "if (!d->valid || consumed > d->consumed)", "if (consumed > d->consumed)"),
    ("drop: never valid", "\td->valid = 1;\n\treturn idle;", "\treturn idle;"),
    ("drop: reset does nothing", "\td->valid = 0;\n}", "\t(void)d;\n}"),
    ("arm in the past", "now.tv_sec + ((time_t)1 << 30)", "now.tv_sec - 1"),
]
ok = True
base = subprocess.run("gcc -Wall -Wextra -O2 -o t test_bridge_watch.c && ./t", shell=True,
                      capture_output=True, text=True)
print("baseline:", base.stdout.strip().splitlines()[-1])
if base.returncode != 0:
    sys.exit("baseline fails")
for name, old, new in M:
    n = SRC.count(old)
    if n != 1:
        print(f"BAD MUTANT {name}: 'old' found {n} times"); ok = False; continue
    d = f"/tmp/bwm/{len(name)}_{abs(hash(name))}"
    shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
    open(f"{d}/bridge_watch.h", "w").write(SRC.replace(old, new))
    shutil.copy("test_bridge_watch.c", d)
    r = subprocess.run(f"cd {d} && gcc -Wall -Wextra -O2 -o t test_bridge_watch.c && timeout 20 ./t",
                       shell=True, capture_output=True, text=True)
    killed = r.returncode != 0
    ok &= killed
    first = (r.stdout + r.stderr).strip().splitlines()[:1]
    print(f"{'KILLED ' if killed else 'SURVIVED'} {name}: {first[0] if first else ''}")
print("ALL KILLED" if ok else "SURVIVORS")
sys.exit(0 if ok else 1)
