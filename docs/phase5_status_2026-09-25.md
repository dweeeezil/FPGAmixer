# Phase 5 status: 2026-09-25 — runtime crosspoint gains over AXI, OSC server on the board

Phase 5's goal (roadmap §3): crosspoints changeable live from the Mac app over OSC. This first step puts the matrix gains under PS control and lets the existing OSC reference server drive them on the board.

## 1. What changed

```
 Mac app ──OSC TCP/UDP──► osc_mixer_server.py --hw  (board, root)
                                │  mixer_hw.py: mmap /dev/mem @ 0x8000_0000
                                ▼
 PS M_AXI_HPM0_LPD ─► SmartConnect ─► M_AXI_CTRL (AXI4-Lite, pl_clk0 100 MHz)
                                │
                     matrix_regs_axil  (shadow bank ─COMMIT─► CDC ─► active bank)
                                │  mclk 12.288 MHz
                                ▼
                            pcm_matrix  (gains_flat is now a port)
```

| Where | What |
|---|---|
| `src/rtl/matrix_regs_axil.sv` (new) | AXI4-Lite slave. Shadow gain bank + COMMIT; toggle-handshake CDC to `mclk`; the whole bank lands on one edge, so each audio frame sees all-old or all-new gains. A COMMIT written while one is in flight is queued in hardware. Resets to the identity routing. |
| `src/rtl/pcm_matrix.sv` | `GAINS_FLAT` parameter → `gains_flat` input port. |
| `src/rtl/phase3_top.sv` | Under `INCLUDE_PS`: `ps_sys_wrapper` now has the `M_AXI_CTRL` port, `u_regs` feeds the matrix. Without it, `MATRIX_GAINS` is tied on as before. |
| `scripts/create_project.tcl` | `current_phase = phase5`. BD adds `proc_sys_reset`, a 1×1 SmartConnect, and the external `M_AXI_CTRL`/`ctrl_aclk`/`ctrl_aresetn` ports; address 0x8000_0000, 4 KB. **No PS8 setting changed.** |
| `constraints/phase5_cdc.xdc` (new, phase5 only) | `set_max_delay -datapath_only 10 ns` on the three crossings (two toggles, the 288-bit bank). |
| `src/sim/tb_matrix_regs.sv` (new), `scripts/sim.mk` (`regs`) | AXI BFM test across unrelated clocks: reset bank, no effect before COMMIT, atomicity monitor on every `mclk` edge, queued COMMIT, WSTRB lanes, matrix outputs vs a reference. |
| `tools/mixer_hw.py` (new) | `/dev/mem` backend + bring-up CLI (`info`, `dump`, `set`, `identity`). |
| `tools/osc_mixer_server.py` | `--hw` drives the PL. `inputMatrix/<in>_<out>/level` (dB) → crosspoint. Same validation with or without `--hw` (see its header). |

### Register map (0x8000_0000)

| Offset | Name | Access | |
|---|---|---|---|
| 0x000 | ID | RO | `0x4D58_5001` |
| 0x004 | CONFIG | RO | `[31:24]` outputs, `[23:16]` inputs, `[15:8]` gain width, `[7:0]` frac bits → `0x0404_1210` |
| 0x008 | CTRL | W: bit0 COMMIT · R: bit0 BUSY, bit1 QUEUED | |
| 0x00C | COMMITS | RO | commits applied |
| 0x100 + 4·(o·N+i) | GAIN[o][i] | RW | signed Q2.16, `0x10000` = 0 dB, 0 = off; reads sign-extended |

### OSC mapping

`/<name>/set/inputMatrix/<in>_<out>/level <dB>` — input `<in>` to output `<out>` (no bus layer in hardware yet, so bus = output). ≤ −90 dB is off; above +6.02 dB clamps, and the echo carries the clamped value. Out-of-range indices and non-numeric levels are ignored (no store, no echo). Missing crosspoints are seeded at startup with the reset routing (0 dB diagonal, −90 dB elsewhere).

## 2. Verification so far

- XSim: `tb_matrix_regs` PASS; regressions `tb_pcm_matrix`, `tb_phase3_datapath`, `tb_phase3_dynamic` PASS. (Icarus isn't installed on the Windows host; `make -f scripts/sim.mk regs` is the Icarus path.)
- `osc_mixer_test.py` against the simulator: 18/19. The failure is `truncated_argument_then_recovery`, the known consequence of unframed TCP that the server header documents; unchanged by this work.
- Vivado 2026.1, full build: synthesis, implementation, bitstream and the methodology gate are all clean. **WNS +2.296 ns** (the intentional codec RX-sampling razor, +2.421 in Phase 3.5), **WHS +0.029 ns**, 0 failing endpoints. `build/fpgamixer_phase5.xsa`, reports `build/p5_*.rpt`.
  - The CDC report lists exactly the designed crossings: 2 × CDC-3 (the toggle synchronizers, ASYNC_REG) and 288 × CDC-15 (the enable-captured gain bank, the expected MCP pattern). All of them are covered by the max-delay; the worst bank bit has 9.23 ns slack against 10 ns.
  - 16 DSP48E2 (one per crosspoint, as expected now that the gains aren't constants), 955 LUTs, 1711 FFs.

### SDT diff against Phase 4

`psu_init.*`, `zynqmp*.dtsi` and `zynqmp-u-boot.dtsi` are byte-identical: the PS configuration really didn't change. The only differences:

- `pl.dtsi`: `firmware-name` → `fpgamixer_phase5.bit.bin`.
- `pcw.dtsi`: a new node `M_AXI_CTRL@80000000` (`compatible = "M_AXI_CTRL"`, `reg = <0x0 0x80000000 0x0 0x1000>`). No kernel driver matches that compatible, so the region stays unclaimed and `/dev/mem` can map it. (That node is also where a `generic-uio` override would go later.)
- `system-top.dts`: the matching `address-map` entries for the new window.

## 3. Board bring-up (not yet done)

**Do not run `mixer_hw.py` or `--hw` on a Phase 4 image**: nothing answers at 0x8000_0000 there, and the first access hangs the interconnect.

1. Rebuild chain: `build/fpgamixer_phase5.xsa` → `sdtgen` (**done 2026-09-25**, `build/sdt`, Phase 4's kept as `build/sdt.pre-phase5`; call it with forward-slash paths, since backslashes are eaten by Tcl) → VM (copied and `dos2unix`'d 2026-09-25 via the `edfvm` alias in `~/.ssh/config`; `rocin-ubuntu.mshome.net` resolves even after the Default Switch IP changes, and was 172.31.211.37 that day) → `gen-machine-conf` → `bitbake edf-linux-disk-image xilinx-bootbin` (as in `setup_edf_hyperv_vm.md`). Python 3 must be in the image: the EDF image already ships **Python 3.12.12** (checked on the board 2026-09-25), so no `local.conf` change was needed.
   **Built 2026-09-25:** `gen-machine-conf` + `bitbake edf-linux-disk-image xilinx-bootbin`, 14,492 tasks, 13,046 from cache, all succeeded. The 22 warnings are the known "image not supported on genesys-zu3eg" one plus bitbake multiconfig "Runqueue deadlocked on deferred tasks" notices (FSBL/PMU sub-builds sharing native recipes; bitbake resolves them itself). The deployed `download-genesys-zu3eg.bit` has the same MD5 as `build/sdt/fpgamixer_phase5.bit` (`773077de…`). Image copied to `build/sd/phase5-20260925.wic.xz`.
   **First boot, 2026-09-25: no Ethernet link until a full power cycle.** After flashing and booting, `end0` stayed `NO-CARRIER` even when set up, although the DP83867 driver had bound, answered over MDIO and advertised 10/100/1000 (`ethtool end0`: `Link detected: no`, board jack LEDs dark). The Pi side was proven by moving the same cable to the Pi's own `eth0`, which linked with I350 `eth4` immediately. **Switching the board off for ~10 s and back on** fixed it: 1000 Mb/s, link detected. A warm reset doesn't reset the PHY's analog state; the DT's MIO44 PHY reset evidently doesn't clear it either. If it recurs, look at whether the PHY reset GPIO actually pulses at probe. Unrelated to the Phase 5 changes (GEM0 is on MIO; the PS config is identical to Phase 4).
2. Before any software: read ID and CONFIG. **Done 2026-09-25: `0x4d585001`, `0x04041210`, correct.** The EDF image has no `devmem`, so it was read with Python instead:
   ```
   sudo python3 -c "import mmap,os;f=os.open('/dev/mem',os.O_RDWR|os.O_SYNC);v=memoryview(mmap.mmap(f,4096,offset=0x80000000)).cast('I');print(hex(v[0]),hex(v[1]))"
   ```
3. Copy the scripts to the board through the Pi, from Windows: `scp -J user@akPi5.local tools\mixer_hw.py tools\osc_mixer_server.py amd-edf@10.0.0.2:` (the board is only reachable on the Pi's 10.0.0.x link); `python3 mixer_hw.py info`, `dump`, then e.g. `set 1 0 0` (JB_L in → JB_R out) and listen.
   **Done 2026-09-25, PASS by ear.** `info` and `dump` showed the identity reset bank. `set 2 0 0` (JB_L in → JC_L out) mixed the JB source into JC_L; `set 2 2 -90` removed JC_L's own input; summing two sources at 0 dB audibly clipped (the matrix saturates, as designed); level changes were audible; `identity` restored passthrough. **Bench limitation:** only mono cables are available for the Pmods, so only the left channels (ch0 = JB_L, ch2 = JC_L) can be driven and heard; the right channels (ch1, ch3) are covered by simulation only.
4. `python3 osc_mixer_server.py --tcp-port 8000 --udp-port 8001 --hw`, then from the Mac `osc_mixer_test.py --host <board> --inputs 4 --buses 4`, then the Mac app.

### OSC server on the board, 2026-09-25

`sudo python3 osc_mixer_server.py --tcp-port 8000 --udp-port 8001 --hw --verbose` on the board; `osc_mixer_test.py --host 10.0.0.2 --inputs 4 --buses 4` run **on the Pi** (the board is only reachable over the Pi's 10.0.0.x link).

- **18/19 PASS**, the same result as against the simulator on Windows. The one failure is again `truncated_argument_then_recovery` (unframed TCP, by design of the current protocol; see the server header).
- `matrix_crosspoint_set_echo` and `invalid_matrix_index_handling` exercise the hardware path: crosspoint 0_0 echoed −24 dB then −3 dB as applied to the PL; the out-of-range crosspoint was ignored with no echo and the connection recovered.
- Round trip over TCP, Pi → board → Pi, including the AXI write and commit: **min 1.3 ms, mean 2.0 ms, max 8.5 ms** (n = 30).
- Side effect: the suite leaves `inputMatrix/0_0/level` at −3 dB, and it's saved in the board's `~/mixer_state.json`, so a restarted server restores it.

**Phase 5 exit criterion status:** crosspoints are changeable live over OSC, verified by the test suite, by ear through `mixer_hw.py`, and through the server. What's still missing is the Mac app itself, which needs a network path from the Mac to the board (§5).

### State file restructured to mirror the OSC tree (2026-09-25)

The server used to save `{"mixer_name": ..., "values": {"zone/index/module": v}}`, a flat dict that also held the device name twice. It now saves the OSC address tree itself (format and rules in `architecture_modules.md` §4.2 and the server header):

- `system/deviceName/` and `system/deviceName` are the same node. Setting either one renames the mixer, and a non-string name is ignored. Before, only the trailing-slash spelling renamed, while the other just stored a value.
- The rename test (`--include-destructive`) now also passes: **19/20** against the simulator, and the only failure is the known unframed-TCP case.
- Old flat files are converted on load, and the original is kept as `mixer_state.json.flat.bak`. The board's current `~/mixer_state.json` is in the flat format and converts itself on the next server start; nothing needs doing by hand.

## 4. Decisions (2026-09-25)

| Question | Decision |
|---|---|
| Bus layer now? | **No.** `inputMatrix/<in>_<out>` maps input → output directly. Keep it easy to add later: see `architecture_modules.md` §6 (second matrix instance + second register window + `busMatrix` zone; depends on the non-square matrix, debt D3). |
| OSC server implementation | **Python is fine for now.** The final server is a separate design; the part meant to carry over is the backend ↔ register-window split. |
| Clicks on gain changes | **Deferred.** Will be a lowpass on the gain inside the matrix block, which doesn't change any interface. |
| Quick USB audio path for testing | **Not done.** It needs a PS ↔ PL PCM stream bridge plus clock-rate adaptation; a shortcut would wire USB into the core. Reasoning in `architecture_modules.md` §6. Testing stays on the Pmods. |
| Modularity | Module boundaries and interface contracts are now written down in **`architecture_modules.md`**, including the four places this Phase 5 change isn't clean yet (D1–D4), to be refactored after the Pmod bring-up proves this build. |

## 5. Open / next

- **Mac app: a separate subproject, deferred** (decided 2026-09-25). OSC control is exercised with the user's existing tools (TouchDesigner, Python, Ableton), so the Mac app isn't a Phase 5 blocker. Those tools still need a network path to the board, whose single Ethernet port is on the Pi's private 10.0.0.x gPTP link. The options are to route through the Pi, move the board onto the LAN, or add a USB-Ethernet adapter; this is decided whenever it's needed.
- ~~**Non-finite values in the state file.**~~ **Resolved 2026-09-25 (user decision):** the server remaps non-finite floats on the way in, before they're applied, stored or echoed: **NaN and −inf → −99.9** (which reads as off, since the matrix mutes ≤ −90 dB), **+inf → +99.9** (a crosspoint then clamps to +6.02 dB). The echo carries the remapped value; a hand-edited file with `NaN`/`Infinity` is remapped on load; the file is written with `allow_nan=False`, so it's always strict JSON. Checked: the suite's `out_of_range_numeric_values` echoes −99.9 / +99.9 / −99.9, and the saved file has no `NaN`/`Infinity`. (+inf → +99.9 was my choice for the symmetric case; the user specified NaN and −inf.)
- **Refactor D1–D4** (`architecture_modules.md` §5) once the Phase 5 bitstream is proven on hardware.
- **Zipper noise** (deferred, see §4).
- **`/dev/mem` → UIO.** A `generic-uio` node in `system-user.dtsi` would drop the root/`/dev/mem` requirement; needs `CONFIG_UIO_PDRV_GENIRQ` and the `of_id` bootarg checked in the EDF kernel.
- **Service + boot restore** (Phase 6): a recipe in `meta-fpgamixer` installing the server and a systemd unit. Persistence already works in the server (`mixer_state.json`, pushed to the PL at startup).
