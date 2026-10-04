#!/usr/bin/env python3
"""
Discovery (standard: "Discovery"; amendment E; controller contract F5): the
mixer advertises itself as a DNS-SD service so controllers find it without an
address. The server calls advertiser.advertise(name) once at startup and
again after every rename; it knows nothing else about how that is done.

  service type  _studiorunner._tcp, port = the OSC TCP port
  instance name the mixer name
  TXT           name=<mixer name>  v=1 (the config schema version)
                framing=len32|none (the TCP framing, so a controller can pick
                its framer without probing)

Advertisers:

  NoAdvertiser     does nothing (development, tests, --advertise none).
  DnssdAdvertiser  systemd-resolved's DNS-SD (decided 2026-10-04: the image
                   already runs resolved; no Avahi). Writes one .dnssd file
                   (systemd.dnssd(5)), atomically, and restarts resolved so
                   it publishes the new contents. Only when the contents
                   change, so an ordinary restart of the server doesn't
                   restart resolved. resolved also needs mDNS on, globally
                   (resolved.conf.d) and on the link (.network
                   MulticastDNS=yes); the image sets both.

The restart runs in a background thread: a rename never waits for it, and a
failure is logged, never fatal (discovery is a convenience; manual entry by
address always works).
"""

import os
import subprocess
import threading

from mixer_params import SCHEMA_VERSION

SERVICE_TYPE = "_studiorunner._tcp"
DNSSD_FILE = "/etc/systemd/dnssd/studiorunner.dnssd"
DNSSD_RELOAD = "systemctl restart systemd-resolved"


class NoAdvertiser:
    def advertise(self, name):
        return False


def _txt_word(text):
    """One TxtText word: quoted only if it needs to be (a stored name from
    before the name rules may contain a space)."""
    if text and not any(c in text for c in ' \t"\\\''):
        return text
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


class DnssdAdvertiser:
    def __init__(self, port, framing, path=DNSSD_FILE, reload_cmd=DNSSD_RELOAD, log=print):
        self.port = port
        self.framing = framing
        self.path = path
        self.reload_cmd = reload_cmd
        self.log = log
        self.reloads = []          # threads started (tests join them)

    def render(self, name):
        return (
            "# Written by osc_mixer_server.py (fpgamixer-osc); rewritten on rename.\n"
            "# Standard: docs/FPGA Mixer OSC Standard.md, \"Discovery\".\n"
            "[Service]\n"
            f"Name={name.replace('%', '%%')}\n"           # systemd specifiers: % is special
            f"Type={SERVICE_TYPE}\n"
            f"Port={self.port}\n"
            f"TxtText={_txt_word('name=' + name)} v={SCHEMA_VERSION} framing={self.framing}\n"
        )

    def advertise(self, name):
        """Publish `name`. Returns True if the file changed (and resolved is
        being restarted), False if it already said this."""
        text = self.render(name)
        try:
            with open(self.path) as f:
                if f.read() == text:
                    return False
        except OSError:
            pass
        try:
            os.makedirs(os.path.dirname(self.path), exist_ok=True)
            tmp = self.path + ".tmp"
            with open(tmp, "w") as f:
                f.write(text)
            os.replace(tmp, self.path)
        except OSError as e:
            self.log(f"Discovery: could not write {self.path} ({e}); not advertised")
            return False
        self.log(f"Discovery: {SERVICE_TYPE} '{name}' on port {self.port} ({self.path})")
        if self.reload_cmd:
            t = threading.Thread(target=self._reload, name="dnssd-reload", daemon=True)
            self.reloads.append(t)
            t.start()
        return True

    def _reload(self):
        try:
            r = subprocess.run(self.reload_cmd.split(), capture_output=True, text=True, timeout=30)
            if r.returncode != 0:
                self.log(f"Discovery: '{self.reload_cmd}' failed ({r.returncode}): {r.stderr.strip()}")
        except Exception as e:     # no systemctl, a timeout: logged, never fatal
            self.log(f"Discovery: '{self.reload_cmd}' failed: {e}")


def make_advertiser(kind, port, framing, path=DNSSD_FILE, reload_cmd=DNSSD_RELOAD, log=print):
    if kind == "none":
        return NoAdvertiser()
    if kind == "dnssd":
        return DnssdAdvertiser(port, framing, path, reload_cmd, log)
    raise ValueError(f"unknown advertiser {kind!r}")
