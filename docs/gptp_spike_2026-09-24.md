# gPTP bench spike: 2026-09-24 — PASS

The Genesys ZU-3EG's PS GEM0 runs 802.1AS (gPTP) with hardware timestamping against a Raspberry Pi 5 + Intel I350, as slave and as grandmaster. Over one hop the offset stays within **3–4 ns RMS, 22 ns worst case**. The agreed Phase 9 criterion is **1 µs end to end** (the AVB system budget of IEEE 802.1BA), so this passes with a lot of margin.

Getting there needed three fixes, one of them in the FPGA design: the GEM time-stamp unit was counting seconds instead of nanoseconds (§2.3). This spike is the reason it was found before Phase 9.

## 1. Setup

| | Board | Peer |
|---|---|---|
| Hardware | Genesys ZU-3EG, PS GEM0 → RGMII → TI DP83867 | Raspberry Pi 5 + Intel I350-T4 (PCIe, `igb`), port `eth4` |
| OS | EDF/Yocto, Linux 6.18.10-xilinx | Raspberry Pi OS (Debian trixie), Linux 6.18.50+rpt-rpi-2712 |
| linuxptp | 4.4 | 4.2 |
| PHC | `/dev/ptp0` (GEM0 TSU, 250 MHz IOPLL, 4 ns increment) | `/dev/ptp3` (I350) |

- **Link:** one direct Cat-6 cable, board `end0` ↔ Pi `eth4`, 1 Gbps full duplex, with no switch (gPTP is point-to-point).
- **Addresses:** static IPs, used only for SSH from the Pi to the board. gPTP itself runs at Layer 2.
  - Pi: NetworkManager profile `ptp-link`, `10.0.0.1/24` (remove with `nmcli con delete ptp-link`).
  - Board: `10.0.0.2/24`, set by hand each boot with `ip addr add`.
- **Profile:** `configs/gPTP.cfg` on both ends. The file is identical in linuxptp 4.2 and 4.4 (diffed). It is two-step (`assume_two_step 1`), L2 transport, P2P delay, Sync every 125 ms (`logSyncInterval -3`), `neighborPropDelayThresh 800`.
  - The board image gets it from `linuxptp-configs`, added to `IMAGE_INSTALL` for this spike.
  - The Pi's Debian package installs it at the same path, `/usr/share/doc/linuxptp/configs/gPTP.cfg`.
- **Roles:** `-s` (slaveOnly) on the side meant to be slave, so the other side has to be grandmaster.

**Checks that hardware timestamping is really used.**
- ptp4l selects `/dev/ptp0`, which matches `ethtool -T end0` ("PTP Hardware Clock: 0").
- No fallback warnings appear, and no `bad timestamps` once the TSU was fixed.
- macb maps ptp4l's `PTP_V2_L2_EVENT` RX filter request to `PTP_V2_EVENT` (`macb_ptp.c:445`), which ptp4l accepts.
- The board supports `HWTSTAMP_TX_ON` (two-step), which matches the profile.

## 2. What had to be fixed first

### 2.1 DP83867 driver not bound ("Generic PHY")

- **Cause:** the generated `gem0` node has no PHY child. macb therefore scans the MDIO bus (`macb_mdiobus_register()`), and the PHY device it finds has no `of_node`. `dp83867_of_init()` returns `-ENODEV` when `!of_node`, the driver core drops that silently, and phylib attaches `genphy`. `CONFIG_DP83867_PHY=y` was set all along; the kernel config was never the problem.
- **Fix:** `system-user.dtsi` adds `gem0/mdio/ethernet-phy@f`, with the values from Digilent's out-of-box BSP (`Digilent/Genesys-ZU-OOB-os`, branch `3eg-master`):
  - RX delay 2.00 ns, TX delay 1.50 ns;
  - FIFO depth 4 nibbles;
  - CLK_OUT = REF_CLK;
  - reset on MIO44 (active low), interrupt on MIO38 (level low). Both pins are GPIO in our `psu_init`.
- **Result:** `driver [TI DP83867] (irq=49)`, `rgmii-id`.

### 2.2 Random MAC every boot

- **Where the MAC lives:** Digilent programs the board's EUI-48 at **QSPI offset `0x1FFF000`** (their `zynq-MAC-in-flash.patch` for U-Boot). On this board it reads `00:18:3e:05:06:48`, the same from U-Boot (`sf probe 0 25000000 0`) and from Linux (nvmem `mtd1`). `00:18:3E` is Digilent's OUI.
- **Fix:** `local-mac-address` in the Linux device tree, hard-coded to this board's own MAC.
- **Why not read it from flash:** pointing `gem0` at an nvmem cell in a `fixed-layout` on the QSPI partition was tried first. macb then never probed: fw_devlink kept a supplier link to the cell node, which never becomes a device, and did not hand it to `spi0.0` when spi-nor bound. The cause isn't established yet (§5).
- **The QSPI node is kept.** It's read-only, covers only the last erase block, and lets Linux read the MAC.
- **Board-specific:** another Genesys ZU needs its own address in the dtsi.

### 2.3 The GEM TSU counted seconds, not nanoseconds (FPGA design fix)

The first ptp4l run showed `bad timestamps in nrate calculation` every second, and the port never synchronized. linuxptp prints that when the peer-delay ingress timestamp `t4` is identical from one exchange to the next (`port.c:1259`).

Reading the GEM0 1588 timer over JTAG (a read-only `mrd` through the DAP, with the board running) showed the cause:

| Register | Before fix | After fix |
|---|---|---|
| `tsu_timer_nsec` (`0xFF0B01D4`) | always `0x00000000` | counting, wraps below 10⁹ |
| `tsu_timer_sec` (`0xFF0B01D0`) | rising **~250 M/s** (one per `tsu_clk` tick) | rising 1/s |
| `tsu_timer_incr` | `4` (correct for 250 MHz) | `4` |
| `GEM_CLK_CTRL` / `GEM_TSU_REF_CTRL` | `0x0` / `0x01010600` (internal PLL, as the TRM requires) | unchanged |

- **Cause:** setting `PSU__ENET0__TSU__ENABLE = 1` exposes the PS input `emio_enet0_tsu_inc_ctrl[1:0]`. The block design left it unconnected, so it was tied to `2'b00`.
- **What the TRM says:** UG1085 v2.5, ch. 34, "Precision Time Protocol via EMIO" (pp. 1060–1061):
  - "Whenever exposed, gem_tsu_inc_ctrl[1:0] SHOULD BE tied to 0b11 in order for GEM TSU to increment normally."
  - With `00` on GEM0 (`gem_tsu_ms = 1`), "the 'nanoseconds' timer register is cleared and the 'seconds' timer register is incremented with each clock cycle". That's exactly the measured behaviour.
- **Fix:** `scripts/create_project.tcl` adds an `xlconstant` (`tsu_inc_ctrl_normal`, 2 bits, value 3) driving `emio_enet0_tsu_inc_ctrl`.
- **Rebuild:** full chain (Vivado → XSA → `sdtgen` → `gen-machine-conf` → bitbake).
  - Timing met: WNS +2.591 ns, WHS +0.034 ns.
  - The machine config came out byte-identical.
  - The SDT gained an `amba_pl` node, because the block design now contains a PL cell. In the Linux DTB it is an empty `simple-bus`.
- An AMD forum thread ([GEM TSU nanosecond counter does not increment regardless of tsu_clk_incr_ctrl](https://adaptivesupport.amd.com/s/question/0D5Pd00001BnOkOKAV/gem-tsu-nanosecond-counter-does-not-increment-regardless-of-tsuclkincrctrl?language=en_US)) shows the same symptom and register values, and is unresolved. The TRM, not the thread, is the basis for the fix.

### 2.4 phc2sys needs the same config

`gPTP.cfg` sets `transportSpecific 0x1` under `[global]`, so it also applies to ptp4l's management socket. That socket drops messages with a different `transportSpecific` (`port.c:808`). Without `-f gPTP.cfg`, phc2sys queries with the default of 0 and waits forever ("Waiting for ptp4l..."). The correct invocation is:

```
phc2sys -f /usr/share/doc/linuxptp/configs/gPTP.cfg -s end0 -c CLOCK_REALTIME -w -m
```

## 3. Results

"Locked" means after the port reached SLAVE, with the first 20 one-second summaries dropped as settling. Offset is ptp4l's per-second `rms`/`max`, as seen by the slave.

| Run | Roles | Locked time | Offset RMS | Offset worst | Seconds > 1 µs | Path delay | Slave freq. correction | Faults |
|---|---|---|---|---|---|---|---|---|
| long1 | Pi GM → **board slave** | 1027 s | **3.0 ns** | 13 ns | 0 | 457.9 ns (456–459) | −26 065 … −25 822 ppb | 0 |
| gm2 | **board GM** → Pi slave | 1245 s | **4.1 ns** | 18 ns | 0 | 457.9 ns (456–460) | +26 080 … +26 506 ppb | 0 |
| long2 | Pi GM → **board slave** | 700 s | **3.9 ns** | 22 ns | 0 | 457.7 ns (456–459) | −28 … +450 ppb ¹ | 0 |
| long2 phc2sys | board PHC → board `CLOCK_REALTIME` | 708 s in `s2` | 21.2 ns | 66 ns | 0 | PHC read 1.31 µs | −40 … +481 ppb | 0 |

¹ ptp4l starts from whatever frequency adjustment the PHC already carries. In long2 the Pi's PHC still had the ~+26 ppm trim from its slave run, so the board needed almost nothing. Before gm2 the board's PHC was reset with `phc_ctl /dev/ptp0 freq 0`, so gm2 shows the true oscillator difference.

**Lock time:** SLAVE about 1 s after choosing the master. After the initial clock step, the first summaries show offsets up to about 1.5 µs; they were inside 10 ns within about 10 s.

**Oscillators:** the board's PS reference (via IOPLL → TSU) runs about **26 ppm slow** relative to the Pi's I350, seen consistently in both directions. It drifted about 0.2–0.4 ppm over 20 minutes, most likely warm-up.

## 4. Anomalies and what they turned out to be

- **Faults in the first grandmaster run** (`multiple peer responses`, `rogue peer delay response`, `FAULTY` three times): a **second ptp4l on the board**, started by accident. It cycled LISTENING ↔ FAULTY every 17 s and answered the Pi's Pdelay_Req during each LISTENING window. That run is discarded, and gm2 is the clean rerun. Lesson: run `pgrep -a ptp4l` before starting, and look out for `ptp41` vs `ptp4l` in narrow fonts.
- **Path delay ≈ 458 ns** on a short direct cable: stable to ±2 ns, symmetric in both roles, and below the 800 ns threshold. It is more than a cable alone would give. It probably includes the two PHYs' internal latencies, since the MACs' timestamp points don't correct for them, but that is **not verified**. What matters for sync is asymmetry, not the absolute value, and asymmetry can't be measured without an external reference (e.g. a 1PPS comparison). Open item.
- **phc2sys at 21 ns RMS** vs ptp4l at 3–4 ns: the PHC read takes about 1.3 µs over MMIO, so system time is only as good as that read window allows. That's fine for logging and scheduling. The audio path should use the PHC (or the PL-side timer, §6), not `CLOCK_REALTIME`.
- **One boot without link** (after the DP83867 change): `end0` came up NO-CARRIER. The PHY interrupt count stayed at 0 for 300 s, and `ip link set end0 down/up` brought the link up with 2 interrupts. Other boots were fine. Seen once; the cause is unknown (§5).

## 5. Open items

1. **Read the MAC from QSPI instead of hard-coding it:** find why fw_devlink doesn't hand the nvmem-cell link to `spi0.0` (next step: `dyndbg="file drivers/base/core.c +p"` on one boot).
2. **Boot-time link:** keep checking `grep -E "^ *49:" /proc/interrupts; ip -br link show end0` after each boot. If NO-CARRIER recurs, compare against polling mode (drop the PHY `interrupts`).
3. **Path-delay asymmetry:** only matters if a later phase needs absolute time better than ~100 ns across devices. The 1 µs budget doesn't need it.
4. **Longer soak and multiple hops:** this was about 20 minutes over one hop. Phase 9 should repeat it through an AVB-capable switch before relying on multi-hop numbers.

## 6. What this says about the audio media clock (not changed here)

- The gPTP-disciplined time lives in the **GEM0 TSU**. It's steered only by ptp4l's frequency and phase adjustments of `/dev/ptp0`; the audio MMCM (+324 ppm, free-running from the PHY's 25 MHz) knows nothing about it. So the roadmap's framing stands: Phase 9 needs either a media clock steered from gPTP, or an ASRC at the network boundary.
- **A lead for the steerable option:** UG1085 Table 34-16 lists a `tsu_timer_cnt[93:0]` GEM output (48-bit seconds + 46-bit ns/sub-ns). It says 1PPS can be taken from bit 45. If that count reaches the PL on this device (to be checked: the EMIO table on p. 1059 lists only `tsu_inc_ctrl` and `tsu_timer_cmp_val`), PL logic could discipline the audio clock against gPTP time directly.
- The measured 26 ppm between two ordinary crystals is a realistic idea of what a media-clock servo must absorb. The MMCM's own +324 ppm is an order of magnitude larger, and its own issue.

## 7. Where the changes are

| File | Change |
|---|---|
| `yocto/meta-fpgamixer/recipes-bsp/device-tree/files/system-user.dtsi` | DP83867 PHY node, `local-mac-address`, read-only QSPI flash node with the MAC nvmem cell |
| `scripts/create_project.tcl` | `tsu_inc_ctrl_normal` constant → `emio_enet0_tsu_inc_ctrl = 2'b11` |
| VM `conf/local.conf` | `IMAGE_INSTALL:append = " linuxptp linuxptp-configs ethtool"` (backup `local.conf.pre-linuxptp-configs`) |
| Backups | `build/fpgamixer_phase4.pre-tsuinc.xsa`, `build/sdt.pre-tsuinc/`; VM `~/edf/sdt.pre-tsuinc`, `~/edf/genesys-zu3eg.conf.pre-tsuinc` |

Logs on the devices: board `~/ptp_slave_long1.log`, `~/ptp_gm_board2.log`, `~/ptp_slave_long2.log`, `~/phc2sys_long2.log`, `~/ptpsum.sh`; Pi `~/ptp_gm_*.log`, `~/ptp_slave_pi2.log`.
