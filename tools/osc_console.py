#!/usr/bin/env python3
"""
Interactive OSC console for the FPGA mixer protocol — type an address and
optional value, hit enter, it's sent immediately. Works against either the
real hardware or osc_mixer_server.py; nothing here assumes which.

Incoming traffic (echoes, broadcasts from other controllers) prints
asynchronously in a different color as it arrives, from a background thread,
while you can keep typing.

The OSC codec and the TCPLink/UDPLink transport classes are the shared
osc_codec.py (next to this file), so every tool speaks identically. TCP
framing must match the mixer's (--tcp-framing; the board's default is len32).

Usage:
    python3 osc_console.py --host 192.168.1.50 --tcp-port 8000 --udp-port 8001
    python3 osc_console.py --host 127.0.0.1 --tcp-port 9000   # TCP only
    python3 osc_console.py --host 127.0.0.1 --tcp-port 9000 --tcp-framing none   # older firmware

At the prompt:
    /mixer/set/inputChannel/0/level -6.0     send a set (TCP by default, or
                                              UDP if --tcp-port wasn't given)
    /mixer/get/inputChannel/0/level          bare address = no value (a get)
    :udp /mixer/set/inputChannel/0/level -6.0   send this one over UDP
    :reconnect                               reconnect the TCP connection
    :help                                    show all commands
    :quit                                    exit

Value types are inferred — a number becomes an OSC float, anything else an
OSC string. Force a type explicitly with i:<int>, f:<float>, or s:<string>.
Quote a value that has spaces: /mixer/set/system/deviceName/ "FOH mixer"

KNOWN LIMITATION: an incoming message that arrives while you're mid-way
through typing a line will interrupt the terminal's display of what you've
typed so far (it moves to a fresh line and reprints the prompt, but can't
restore your partially-typed text). This is a basic REPL, not a full TUI —
if that's disruptive, a real terminal will show it as an extra blank prompt
line above your still-intact input.

No dependencies beyond the standard library.
"""

import argparse
import shlex
import sys
import threading
import time

# The codec and the client links are shared with the server (osc_codec.py).
from osc_codec import (FRAMINGS, DEFAULT_FRAMING, FramingLost, OSCMalformed, TCPLink,
                       UDPLink, encode_message)


# ---------------------------------------------------------------------------
# Value parsing / formatting
# ---------------------------------------------------------------------------

def parse_value_token(token: str):
    """Numbers -> float, everything else -> string, with an explicit
    i:<int> / f:<float> / s:<string> override."""
    if len(token) >= 2 and token[1] == ":" and token[0] in "ifs":
        prefix, rest = token[0], token[2:]
        if prefix == "i":
            return int(rest)
        if prefix == "f":
            return float(rest)
        return rest  # 's' — rest may be an empty string
    try:
        return float(token)
    except ValueError:
        return token


def format_args(args) -> str:
    parts = []
    for a in args:
        if isinstance(a, str):
            parts.append(f'"{a}"' if (" " in a or a == "") else a)
        else:
            parts.append(str(a))
    return " ".join(parts)


# ---------------------------------------------------------------------------
# Terminal colors
# ---------------------------------------------------------------------------

RESET = "\033[0m"
CYAN = "\033[36m"    # sent
GREEN = "\033[32m"   # received
RED = "\033[31m"     # errors
YELLOW = "\033[33m"  # connection status
DIM = "\033[2m"       # help text


# ---------------------------------------------------------------------------
# Console
# ---------------------------------------------------------------------------

class Console:
    PROMPT = "> "

    def __init__(self, host, tcp_port, udp_port, color=True, framing=DEFAULT_FRAMING):
        self.host = host
        self.tcp_port = tcp_port
        self.udp_port = udp_port
        self.framing = framing
        self.color = color
        self._lock = threading.Lock()
        self.tcp = None
        self.udp = None

        if tcp_port:
            print(f"Connecting to {host}:{tcp_port} (TCP, framing {framing})...")
            try:
                self.tcp = TCPLink(host, tcp_port, timeout=5.0, framing=framing).connect()
            except OSError as e:
                print(f"Could not connect: {e}", file=sys.stderr)
                sys.exit(1)
            print(self._c(f"Connected (TCP) to {host}:{tcp_port}", YELLOW))
            self._start_recv_thread(self.tcp)

        if udp_port:
            self.udp = UDPLink(host, udp_port)
            print(self._c(f"UDP sender ready for {host}:{udp_port} (write-only, no replies)", YELLOW))

    # -- color helper --------------------------------------------------

    def _c(self, text, color):
        return f"{color}{text}{RESET}" if self.color else text

    # -- output -----------------------------------------------------------

    def _timestamp(self):
        return time.strftime("%H:%M:%S") + f".{int(time.time() * 1000) % 1000:03d}"

    def _print_sent(self, address, args, via):
        text = f"{self._timestamp()} -> [{via}] {address} {format_args(args)}".rstrip()
        print(self._c(text, CYAN))

    def _print_received(self, msg, via="TCP"):
        text = f"{self._timestamp()} <- [{via}] {msg.address} {format_args(msg.args)}".rstrip()
        self._print_async(self._c(text, GREEN))

    def _print_async(self, text):
        """For output from the background thread: move to a fresh line so it
        doesn't get spliced into whatever the user is mid-typing, then
        reprint the prompt (see the KNOWN LIMITATION note at the top of this
        file — partially-typed input isn't restored)."""
        with self._lock:
            sys.stdout.write("\n" + text + "\n" + self.PROMPT)
            sys.stdout.flush()

    def _print_error(self, text):
        print(self._c(f"! {text}", RED))

    def _print_help(self):
        print(self._c(
            "Commands:\n"
            "  <address> [value ...]       send an OSC message, e.g. /mixer/set/inputChannel/0/level -6.0\n"
            "                               (no value -> empty-args message, e.g. a 'get')\n"
            "  :udp <address> [value ...]  send one message over UDP instead of the default transport\n"
            "  :reconnect                  reconnect the TCP connection\n"
            "  :help                       show this help\n"
            "  :quit                       exit\n"
            "Value types are inferred: numbers -> float, everything else -> string.\n"
            "Force a type explicitly with i:<int>, f:<float>, or s:<string>.\n"
            'Quote a value with spaces: /mixer/set/system/deviceName/ "FOH mixer"',
            DIM))

    # -- receiving ----------------------------------------------------------

    def _start_recv_thread(self, link):
        threading.Thread(target=self._recv_loop, args=(link,), daemon=True).start()

    def _recv_loop(self, link):
        # `link` is captured once at thread start, not re-read from self.tcp
        # each iteration — so after :reconnect swaps self.tcp to a new
        # TCPLink, this (old) thread keeps reading the old, now-closed
        # socket, gets an OSError on its next read, and exits on its own,
        # rather than racing the new thread on the same socket.
        while True:
            try:
                msg = link.read_message(timeout=1.0)
            except TimeoutError:
                continue
            except OSCMalformed as e:   # the link already dropped the bad bytes
                self._print_async(self._c(f"! malformed data received and dropped: {e}", RED))
                continue
            except (OSError, ConnectionResetError, FramingLost) as e:
                self._print_async(self._c(f"TCP connection lost: {e}", YELLOW))
                return
            self._print_received(msg)

    def _reconnect(self):
        if not self.tcp_port:
            self._print_error("no --tcp-port given at startup")
            return
        if self.tcp:
            self.tcp.close()
        try:
            new_link = TCPLink(self.host, self.tcp_port, timeout=5.0, framing=self.framing).connect()
        except OSError as e:
            self._print_error(f"reconnect failed: {e}")
            return
        self.tcp = new_link
        self._start_recv_thread(new_link)
        print(self._c(f"Reconnected (TCP) to {self.host}:{self.tcp_port}", YELLOW))

    # -- sending --------------------------------------------------------

    def _send(self, link, address, args, via):
        if link is None:
            self._print_error(f"no {via} connection available")
            return
        try:
            data = encode_message(address, args)
        except TypeError as e:
            self._print_error(f"couldn't encode message: {e}")
            return
        try:
            link.send_packet(data)      # framed on TCP (--tcp-framing), as is on UDP
        except OSError as e:
            hint = " — try :reconnect" if via == "TCP" else ""
            self._print_error(f"send failed ({via}): {e}{hint}")
            return
        self._print_sent(address, args, via)

    def _handle_send(self, line):
        try:
            tokens = shlex.split(line)
        except ValueError as e:
            self._print_error(f"couldn't parse line: {e}")
            return
        if not tokens:
            return
        address = tokens[0]
        try:
            args = [parse_value_token(t) for t in tokens[1:]]
        except ValueError as e:
            self._print_error(f"bad value: {e}")
            return
        link, via = (self.tcp, "TCP") if self.tcp is not None else (self.udp, "UDP")
        self._send(link, address, args, via)

    def _handle_meta(self, line):
        try:
            parts = shlex.split(line[1:])
        except ValueError as e:
            self._print_error(f"couldn't parse command: {e}")
            return None
        if not parts:
            return None
        cmd = parts[0].lower()
        if cmd in ("q", "quit", "exit"):
            return "quit"
        if cmd in ("h", "help", "?"):
            self._print_help()
        elif cmd == "udp":
            if self.udp is None:
                self._print_error("no --udp-port given at startup")
            elif len(parts) < 2:
                self._print_error("usage: :udp <address> [value ...]")
            else:
                address = parts[1]
                try:
                    args = [parse_value_token(t) for t in parts[2:]]
                except ValueError as e:
                    self._print_error(f"bad value: {e}")
                else:
                    self._send(self.udp, address, args, "UDP")
        elif cmd == "reconnect":
            self._reconnect()
        else:
            self._print_error(f"unknown command: {cmd!r} (try :help)")
        return None

    # -- main loop --------------------------------------------------------

    def run(self):
        default_via = "TCP" if self.tcp is not None else "UDP"
        print("Type an OSC address and optional value(s), e.g.:")
        print("  /mixer/set/inputChannel/0/level -6.0")
        print(f"Sends over {default_via} by default. :help for commands, :quit to exit.\n")
        while True:
            try:
                line = input(self.PROMPT).strip()
            except (EOFError, KeyboardInterrupt):
                print()
                break
            if not line:
                continue
            if line.startswith(":"):
                if self._handle_meta(line) == "quit":
                    break
                continue
            self._handle_send(line)
        return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_arg_parser():
    p = argparse.ArgumentParser(
        description="Interactive console for sending/receiving OSC messages against the FPGA "
                    "mixer — real hardware or osc_mixer_server.py, either one."
    )
    p.add_argument("--host", required=True, help="IP or hostname of the mixer")
    p.add_argument("--tcp-port", type=int, help="TCP OSC port (two-way; default transport if given)")
    p.add_argument("--udp-port", type=int, help="UDP OSC port (write-only; default transport if --tcp-port isn't given)")
    p.add_argument("--tcp-framing", choices=FRAMINGS, default=DEFAULT_FRAMING,
                   help="TCP framing the mixer uses: len32 (default) or none (older firmware)")
    p.add_argument("--no-color", action="store_true", help="disable ANSI colors")
    return p


def main():
    args = build_arg_parser().parse_args()
    if not args.tcp_port and not args.udp_port:
        print("error: give at least one of --tcp-port or --udp-port", file=sys.stderr)
        return 2
    color = (not args.no_color) and sys.stdout.isatty()
    console = Console(args.host, args.tcp_port, args.udp_port, color=color, framing=args.tcp_framing)
    return console.run()


if __name__ == "__main__":
    sys.exit(main())
