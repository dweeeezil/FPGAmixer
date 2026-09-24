# =============================================================================
# jtag_boot.tcl -- boot the Genesys ZU-3EG over JTAG, no SD card involved.
#
# Usage (from repo root, board in JTAG boot mode, powered from its own supply):
#     C:\AMDDesignTools\2026.1\Vivado\bin\xsdb.bat scripts/jtag_boot.tcl
#
# xsdb starts hw_server itself. Everything is loaded into DDR, so nothing
# persists across a power cycle -- that is the point: no card swapping between
# builds. Artifacts come from the EDF build (see docs/phase4_status_*.md) and
# are staged in build/jtag/ (gitignored).
#
# Sequence, and why each step:
#   1. PMU firmware  -> power/clock management; must run before the APU.
#   2. FSBL on A53#0 -> initialises DDR and the PS peripherals from psu_init.
#                       Nothing may be written to DDR before this finishes.
#   3. payloads      -> kernel, dtb and ramdisk into DDR at U-Boot's own
#                       default addresses (read from u-boot-xlnx-initial-env,
#                       not invented): kernel_addr_r, fdt_addr_r, ramdisk_addr_r.
#   4. U-Boot        -> ELF entry 0x8000000, which matches the machine conf's
#                       TFA_BL33_LOAD, i.e. where ATF expects to find BL33.
#   5. ATF last      -> its entry (0xfffea000, OCM) becomes the PC, so `con`
#                       starts ATF, which then jumps to U-Boot.
#
# At the U-Boot prompt (serial), boot with:
#   booti ${kernel_addr_r} ${ramdisk_addr_r}:${ramdisk_size} ${fdt_addr_r}
# scripts/jtag_boot.ps1 does that automatically over the UART.
# =============================================================================

set dir      [file normalize [file dirname [info script]]/../build/jtag]
set pmu      $dir/pmu-firmware-genesys-zu3eg.elf
set fsbl     $dir/fsbl-genesys-zu3eg.elf          ;# kept for reference; psu_init.tcl is used instead
set psu_init [file normalize [file dirname [info script]]/../build/sdt/psu_init.tcl]
set atf      $dir/arm-trusted-firmware.elf
set uboot    $dir/u-boot.elf
set kernel   $dir/Image
set dtb      $dir/system.dtb
set ramdisk  $dir/core-image-minimal-genesys-zu3eg.rootfs.cpio.gz

# U-Boot's own defaults (u-boot-xlnx-initial-env)
set kernel_addr  0x18000000
set fdt_addr     0x40000000
set ramdisk_addr 0x02100000

foreach f [list $pmu $psu_init $atf $uboot $kernel $dtb $ramdisk] {
    if {![file exists $f]} {
        puts "ERROR: missing $f"
        puts "       Stage the EDF build outputs into build/jtag/ first."
        exit 1
    }
}

puts "== connecting"
connect

puts "== system reset"
targets -set -nocase -filter {name =~ "*PSU*"}
rst -system
# Target contexts are invalidated by the reset. Downloading too soon fails with
# "Invalid context" (seen 2026-09-23 with a 2 s wait); 4 s plus a re-enumeration
# is reliable.
after 4000
targets

# Disable the security gates for DAP, PLTAP and PMU. Without this the PMU
# MicroBlaze is not reachable and `dow` fails with "Invalid context" -- which is
# exactly what happened here on 2026-09-23 before adding it. Source: AMD UG1137,
# "Loading PMU Firmware in JTAG Boot Mode". That page also states it is
# mandatory to load PMU FW *before* FSBL in JTAG boot mode.
puts "== disabling security gates (UG1137)"
targets -set -nocase -filter {name =~ "*PSU*"}
mwr 0xffca0038 0x1ff
after 500

# Once the gates are open, TWO targets match "*PMU*": the PS TAP's "PMU" node
# and the actual "MicroBlaze PMU" core (which only appears after the mwr above,
# initially "Sleeping. No clock"). The firmware goes to the MicroBlaze.
puts "== PMU firmware"
targets -set -nocase -filter {name =~ "MicroBlaze PMU"}
dow $pmu
con
after 1000

# PS + DDR init. This uses psu_init.tcl from the SDT rather than running FSBL:
# psu_init.tcl IS the generated register sequence that FSBL would execute, and
# it is deterministic under xsdb. Downloading the A53 FSBL and running it left
# DDR uninitialised here (2026-09-23: "Blocked address 0x18000000. DDR
# controller is not initialized"), while psu_init brings DDR up every time.
# Nothing may be written to DDR before this completes.
puts "== PS + DDR init (psu_init.tcl from the SDT)"
targets -set -nocase -filter {name =~ "*Cortex-A53 #0*"}

# Park the core in a branch-to-self at the reset vector BEFORE resetting it.
# 0x14000000 is AArch64 "b ." -- without it the A53 comes out of reset running
# whatever happens to be in OCM, which is what xsdb's own warning is about
# ("write bootloop at reset vector address (0xffff0000)"). Symptom when this is
# missing: ATF prints its banner, then the core ends up sitting at 0xffff0000
# and U-Boot never reaches its console (seen 2026-09-23).
# Order matters: while the core sits in "APU Reset" no memory access is allowed
# through it ("Cannot write memory if not stopped"), so reset and halt first,
# then write the bootloop.
rst -processor
after 500
# Downloads must target a halted core, otherwise `dow` will not reliably set PC
# and the core can end up running from the reset vector instead of ATF.
# `stop` errors with "Already stopped" when rst -processor already halted it,
# which is the normal case here -- so tolerate that.
catch {stop}
mwr 0xffff0000 0x14000000

source $psu_init
psu_init
after 1000
psu_ps_pl_isolation_removal
psu_ps_pl_reset_config
after 500

# Prove DDR is really up before pushing 33 MB of kernel at it.
mwr 0x18000000 0xDEADBEEF
# mrd returns "18000000:   DEADBEEF" with trailing whitespace, so trim before
# splitting or the last element comes back empty.
set rb ""
regexp {([0-9A-Fa-f]{8})\s*$} [string trim [mrd 0x18000000]] -> rb
if {[string toupper $rb] ne "DEADBEEF"} {
    puts "ERROR: DDR readback was '$rb', expected DEADBEEF -- aborting."
    disconnect
    exit 1
}
puts "   DDR readback OK"

puts "== payloads into DDR"
puts "   kernel  -> $kernel_addr"
dow -data $kernel  $kernel_addr
puts "   dtb     -> $fdt_addr"
dow -data $dtb     $fdt_addr
set rsize [file size $ramdisk]
puts "   ramdisk -> $ramdisk_addr ([format 0x%x $rsize] bytes)"
dow -data $ramdisk $ramdisk_addr

puts "== U-Boot (BL33) + ATF (BL31)"
dow $uboot
dow $atf

puts "== releasing Cortex-A53 #0"
con

puts ""
puts "=================================================================="
puts " Booting. At the U-Boot prompt on the UART, run:"
puts ""
puts "   booti $kernel_addr $ramdisk_addr:[format 0x%x $rsize] $fdt_addr"
puts ""
puts " (scripts/jtag_boot.ps1 does this for you over the serial port.)"
puts "=================================================================="
disconnect
