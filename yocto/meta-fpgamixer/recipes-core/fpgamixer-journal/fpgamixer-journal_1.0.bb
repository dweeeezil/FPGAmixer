SUMMARY = "FPGAmixer: keep the systemd journal across reboots, on the SD card"
DESCRIPTION = "Hardening (H-F7, docs/hardening_status_2026-10-10.md sec. 8.3): the \
image keeps /var/log in RAM (VOLATILE_LOG_DIR), so a hang that needed a reboot \
left no evidence. A bind mount puts the journal's directory on the root \
filesystem and journald stores persistently, capped at 64 MB. Changing \
VOLATILE_LOG_DIR instead would repackage every recipe in the image."
LICENSE = "CLOSED"

SRC_URI = " \
    file://var-volatile-log-journal.mount \
    file://50-fpgamixer.conf \
"

S = "${WORKDIR}"

inherit systemd allarch

SYSTEMD_SERVICE:${PN} = "var-volatile-log-journal.mount"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    install -d ${D}${localstatedir}/lib/fpgamixer/journal
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${S}/var-volatile-log-journal.mount ${D}${systemd_system_unitdir}/
    install -d ${D}${systemd_unitdir}/journald.conf.d
    install -m 0644 ${S}/50-fpgamixer.conf ${D}${systemd_unitdir}/journald.conf.d/
}

FILES:${PN} += "${localstatedir}/lib/fpgamixer/journal ${systemd_unitdir}/journald.conf.d"
