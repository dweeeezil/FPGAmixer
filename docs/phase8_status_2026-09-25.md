# Phase 8 status: 2026-09-25 — PS ↔ PL audio link, first user USB audio (device mode)

Phase 8 was pulled ahead of Phase 7 (DSP): the Pmod bench only has mono cables, so only the two left channels can be driven or heard, and the user wants multichannel audio from the Mac for testing. The work has two parts:

- a **generic PS ↔ PL PCM link**: a front door that moves PCM between Linux and the core, shared later by Phase 9 AVB;
- its **first user, USB audio**: the board as a USB soundcard for the Mac.

**Status: §1–§8 are a design proposal. Nothing is built yet.** The open questions in §9 need the user's decisions before any code is written. Everything marked *checked* below was read from the actual tools, sources or board files on 2026-09-25, not recalled.

---

## 1. What was checked, and what it says

| Fact | Source | Consequence |
|---|---|---|
| The **Type-C port J6 is on PS USB0**: ULPI USB3320 PHY on MIO 52–63, USB 3 on **PS-GTR lane 1** (`PSU__USB3_0__PERIPHERAL__IO = GT Lane1`). Data role DRD, power role DRP; the board stays self-powered as UFP. Role/orientation chip: **TI TUSB322I** (I2C 0x47, mux branch 3). | Genesys ZU reference manual §8.1; our XSA (`.hwh`) | Device mode is physically supported on USB0. (The ZynqMP boot ROM's USB boot mode also uses USB0 as a device.) |
| **USB1** (MIO 64–75) goes to the USB2513B hub: 2 × Type-A + the Mini PCIe slot. Host only. | manual §8.2; `.hwh` | Unaffected. It must be pinned to `dr_mode = "host"` once the kernel is dual-role (below). |
| The generated device tree has **no `dr_mode` and no USB 3 `phys`** on `dwc3_0`. Digilent's own BSP sets `dr_mode = "host"` on both controllers, plus the lane-1 USB 3 PHY. | `build/sdt/pcw.dtsi`, `zynqmp.dtsi`; Digilent `Genesys-ZU-OOB-os` `system-user.dtsi` | We add `dr_mode` ourselves. USB 2.0 High Speed is plenty for 8 + 8 channels (§4), so the USB 3 PHY isn't needed. |
| EDF kernel is **6.18.10** (linux-xlnx v2026.1). *Read from the generic `amd_cortexa53_mali_common` kernel build on the VM; the board kernel builds in `tmp/work/genesys_zu3eg-amd-linux/`, from the same defconfig and layers. Its pre-P8.1 `.config` wasn't captured separately; the post-P8.1 one is in §10.* **`CONFIG_USB_DWC3_HOST=y`, `CONFIG_USB_GADGET=m`**: DWC3 is built **host-only**; its gadget/dual-role modes need `USB_GADGET=y` (DWC3 is built in). `USB_F_UAC2=m` exists but **`CONFIG_USB_CONFIGFS_F_UAC2` is not set**. `EXTCON_USBC_TUSB320` not set. | kernel `.config` on the build VM | A kernel config fragment is needed (§3.2). Today the board **cannot** be a USB device. |
| `CONFIG_SND_SOC_XILINX_AUDIO_FORMATTER=y`, `…_I2S=y`, `…_PL_SND_CARD=y`; `SND_SIMPLE_CARD` not set. `UIO_PDRV_GENIRQ=m`. `PREEMPT_NONE`, `HZ=250`. | same | The Audio Formatter's ALSA driver is already in the kernel. |
| **Audio Formatter v1.0** ships with Vivado 2026.1 (`data/ip/xilinx/audio_formatter_v1_0`), "provided at no additional cost … under the terms of the Xilinx End User License". Max **2/4/6/8 channels per direction**; PCM or AES; interleaved or not; S2MM tolerates channels in any order and zero-fills missing ones; MM2S sample rate = `aud_mclk` / Fs multiplier. | Vivado install; PG330 | Option (a) is available and free, capped at 8 channels per direction per instance. |
| The formatter's Linux driver registers an ASoC **platform component with no DAI**. It only becomes a sound card through `xlnx_pl_snd_card`, and that machine driver only accepts an AMD I2S / HDMI / SDI / SPDIF / DP IP as the other end (`xlnx,tx` / `xlnx,rx` phandles, matched by compatible string). The MM2S Fs multiplier is written from `set_sysclk()`, which only that machine driver calls. Formats S8/S16_LE/S24_LE (no S32), 2–8 channels, 2–6 periods of 192 B–50 KB. | `sound/soc/xilinx/xlnx_formatter_pcm.c`, `xlnx_pl_snd_card.c` (linux-xlnx master) | Using the formatter with *our own* PL endpoint needs either AMD I2S IP as a stand-in or **a small machine driver of our own** (§3.1). |
| `f_uac2` (mainline) has **"Capture Pitch 1000000"** (steers the explicit feedback endpoint the host follows for OUT data) and **"Playback Pitch 1000000"** (sets the IN packet sizing) ALSA controls, range set by `fb_max`. | `drivers/usb/gadget/function/u_audio.c` | The Mac can be slaved to the board's clock with no resampling (§5). |
| **Corrected during P8.1:** the **genesys-zu3eg image ships no ALSA userspace at all** (no `libasound`, no `alsa-utils`; 1162 packages). The `alsa-utils` 1.2.11 / PulseAudio seen first came from the *generic* `amd-cortexa53-mali-common` smoke-build manifest. `alsaloop` gained UAC2-gadget pitch support (`-x/--prateshift`) in 1.2.6. | both rootfs manifests on the VM; alsa-utils 1.2.6 changelog | P8.1 adds `alsa-utils-{alsaloop,aplay,amixer,speakertest}` to the image. There is no PulseAudio on the board to grab the cards. |
| Side find: the board has an on-board **ADAU1761 codec** on PL pins (line in/out, headphone, mic, I2C-configured). | manual §9.5 | Not part of this phase. Worth noting as a future stereo I2S front door with real stereo jacks. |

---

## 2. Proposed architecture (one picture)

```
  Mac ══USB 2.0 HS══ Type-C J6 ─ USB0 (DWC3, dr_mode=peripheral)
                                     │  f_uac2 gadget: 8 out + 8 in, 48 kHz, async + feedback
                                     ▼
  Linux ── "USB front door, Linux half" ──────────────────────────────────────────
     gadget ALSA card (USB host time)  ◄─ bridge service (alsaloop or ours) ─►  link ALSA card (mclk time)
                   ▲ pitch control (steers the Mac to mclk)                         │
  ─────────────────┼────────────────────────────────────────────────────────────────┼──
                   │                                  "PS↔PL link": generic, not USB-specific
                   │                                  Audio Formatter (DMA, DDR ring buffers)
                   │                                    │ AXI4-Stream audio (TDATA+TID), pl_clk0
  PL               │                                    ▼
                   │                         pcm_link (front door, PL half)
                   │                           async FIFO pl_clk0 → mclk, frame assembly,
                   │                           underrun/overrun handling + counters
                   │                                    │ PCM contract on mclk (8 ch in, 8 ch out)
                   │                                    ▼
                   │            core: pcm_matrix 12 × 12  (ch0–3 Pmods, ch4–11 link)
                   │
                   └── status: link counters → axil_stat_window (new generic RO window) → mixer_hw
```

The key property: **the link's ALSA card runs on `mclk` time.** The formatter's MM2S emits one frame per `mclk`/256 (its `aud_mclk` input is our `mclk`), and the PL side pushes one capture frame per core `valid`. So the link itself never adapts rates; it only needs to survive underruns and overruns. Whatever feeds it from Linux (the USB gadget now, AVB later) has to deliver audio at `mclk` rate, which is where clock bridging belongs (§5).

---

## 3. Question 1 + 2: USB role and the link

### 3.1 The PS ↔ PL link: options compared

| | (a) **Audio Formatter + our ASoC machine driver** (recommended) | (a′) Audio Formatter + AMD I2S TX/RX IP as stand-ins | (b) AXI DMA / AXI-Stream FIFO + UIO or `u-dma-buf`, userspace ring handling | (c) our own RTL DMA master + UIO |
|---|---|---|---|---|
| What Linux sees | a real ALSA card `fpgamixerlink`, 8 ch playback + 8 ch capture | a real ALSA card, via the stock `xlnx_pl_snd_card` | no ALSA card: a daemon owns the buffers | no ALSA card |
| Kernel code of ours | one small out-of-tree module (~150 lines): a card with one DAI link (dummy CPU/codec DAI, the formatter as platform) that calls `set_sysclk(12.288 MHz)` → Fs multiplier 256 | none | none (UIO), but `u-dma-buf` isn't in the image | none, but the most RTL |
| PL | formatter (AMD, free) + `pcm_link` | formatter + I2S TX + I2S RX (AMD, free) + 4 × our `i2s_receiver` / `i2s_transmitter` + a frame re-aligner. Audio is serialised to I2S **inside the FPGA** only to satisfy a driver | AXI DMA + `pcm_link` | DMA master + ring logic + `pcm_link` |
| Who can use the link | anything that speaks ALSA: the gadget bridge, `aplay`/`arecord` for tests, a Phase 9 1722 talker/listener | same | only our daemon; every new user has to learn its API | same as (b) |
| Risk | the machine-driver module (standard ASoC pattern), a kernel recipe in the layer | a pointless I2S hop; channel pairs and frame phase to re-align; the I2S IP's own clocking | we write ring/period/IRQ handling ourselves, plus PIO or cache management | we write a DMA engine |

**Recommendation: (a).** The ALSA card is the right seam: the link knows nothing about USB, and Phase 9 plugs into the same card. The one piece of kernel code is small, standard and isolated. (a′) avoids kernel code only by adding hardware whose sole job is to satisfy a driver's compatible-string check, which is the kind of reach-around `architecture_modules.md` §1 rules out.

**Fallback if the module becomes a sink:** (a′) is the no-custom-kernel route.

Details of (a):

- **BD:** `audio_formatter_0` with 8 + 8 channels, interleaved, PCM mode, 32-bit addresses. AXI-Lite on a second SmartConnect master (from `M_AXI_HPM0_LPD`, like the matrix window); AXI-MM on **`S_AXI_HPC0_FPD`** (already enabled by the preset, clocked from `pl_clk0`, unused today); `irq_mm2s` / `irq_s2mm` → `pl_ps_irq0` (`PSU__USE__IRQ0 = 1` already). `aud_mclk` = our `mclk`, exported into the BD as a clock input. AXIS clocks = `pl_clk0`.
- **Address:** the formatter is a *driver-owned* device, not one of our control windows (no ID/CONFIG header). Proposal: driver-owned devices at **0x8010_0000+**, keeping 0x8000_x000 for our self-describing windows.
- **Device tree:** sdtgen emits the formatter node. We add the card node in `system-user.dtsi` (`compatible = "fpgamixer,pcm-link-card"`, a phandle to the formatter, `mclk-frequency = <12288000>`). The nominal 12.288 MHz makes the multiplier exactly 256; the real clock is 12.2919 MHz, so the card's true rate is 48.016 kHz while ALSA calls it 48000. That is correct: the rate servo (§5) deals with the real rate.
- **Sample format:** S24_LE (24 in 32, LSB-justified) in memory; the formatter has no S32_LE. The gadget uses S24_3LE or S32_LE, so the bridge opens both cards through `plughw`, which only repacks (no resampling).

### 3.2 USB role: device mode (to confirm)

The roadmap's Decision 3 recommended **host mode** first (a class-compliant interface plugged into the board). The user's goal is to play and record multichannel audio **from the Mac**, which is **device mode**: the board enumerates as a UAC2 soundcard. Device mode is also better on clocks: the board can steer the Mac with the feedback endpoint, so audio arrives bit-exact, whereas host mode has to resample in software (a USB interface's clock can't be steered). **Recommendation: device mode now.** Host mode stays possible later over the same link (a `snd-usb-audio` card ↔ link bridge with resampling). This merges the roadmap's Phase 8 and Phase 11 rows; the roadmap will be updated once decided.

What device mode needs (checked against the kernel config and DT above):

1. **Kernel fragment** (new `linux-xlnx_%.bbappend` + `.cfg` in `meta-fpgamixer`): `CONFIG_USB_GADGET=y`, `CONFIG_USB_DWC3_DUAL_ROLE=y`, `CONFIG_USB_CONFIGFS=y`, `CONFIG_USB_CONFIGFS_F_UAC2=y` (pulls in `U_AUDIO`/`F_UAC2`). Built-in rather than modules, so no module-loading order matters at boot.
2. **DT** (`system-user.dtsi`): `&dwc3_0 { dr_mode = "peripheral"; maximum-speed = "high-speed"; snps,dis_u2_susphy_quirk; snps,dis_u3_susphy_quirk; }` (the quirks as in Digilent's BSP) and `&dwc3_1 { dr_mode = "host"; }`. With `DUAL_ROLE` built in, an unset `dr_mode` would default to OTG, so USB1 must be pinned.
3. **Gadget setup at boot:** a configfs script + systemd unit in a new recipe `fpgamixer-usb-gadget`: UAC2 function, `c_chmask`/`p_chmask` = 0xff (8 ch), `c_srate`/`p_srate` = 48000, `c_sync` = async, `fb_max` sized for ±1000 ppm, product name "FPGAmixer". A second recipe, not part of `fpgamixer-osc`: USB is a front door, the OSC server is control plane.
4. **Type-C role:** ~~the TUSB322I powers up in its default mode (DRP). A Mac is always a source/DFP, so the board should attach as UFP with no driver.~~ **Wrong, found on the bench (§10, S1):** the chip comes up DRP with Try.SRC and wins against a Mac as the source, so the gadget script forces it to UFP over I2C at every start. **Risk:** device mode also needs the controller to see VBUS through the USB3320 (session valid). If enumeration fails, the fallbacks are the mainline `extcon-usbc-tusb320` driver (TUSB322I compatibility unverified) or forcing UFP over I2C. This is exactly what bench step S1 (§8) tests first, before any PL work depends on it.

---

## 4. Question 4: channel counts, channel map, OSC indices and state

**Proposal: 8 link channels each way, core 12 × 12.**

| Core ch | In (source) | Out (sink) |
|---|---|---|
| 0–3 | JB_L, JB_R, JC_L, JC_R (unchanged) | JB_L, JB_R, JC_L, JC_R (unchanged) |
| 4–11 | link capture-from-PS ch 0–7 = **Mac playback** ch 1–8 | link playback-to-PS ch 0–7 = **Mac recording** ch 1–8 |

- **Existing indices keep their meaning.** The Pmods stay at 0–3, so every `inputMatrix/<in>_<out>` in a saved state file still means the same crosspoint. New channels are appended, never interleaved.
- **Migration is free:** `MatrixBackend.seed_and_push` already fills only *missing* crosspoints and reads `N_IN`/`N_OUT` from the window's CONFIG. An old 16-entry file keeps its 16 values and gets the 128 new ones seeded. The only software change is the constant in `fpgamixer_top` (the window reports 12 × 12 by itself). A test for exactly this migration goes into `test_mixer_hw.py`.
- **Seeding rule for the new crosspoints:** today "diagonal 0 dB, rest off", i.e. identity, so Mac out *k* → Mac in *k* (a loopback the Mac can record). Question 4 in §9.
- **Resources:** `pcm_matrix` uses one DSP48E2 per crosspoint → **144 of the 3EG's 360**, with Phase 7 still to come. Acceptable now. If DSP gets tight, the matrix can be time-multiplexed (256 `mclk` cycles per frame) with no interface change; noted as future work, not done now.
- Gain bank 144 × 18 = 2592 bits through `coef_bank_handoff`: registers only, no timing concern (same MCP formulation, same scoped XDC).
- `osc_mixer_test.py` is run with `--inputs 12 --buses 12`.
- USB bandwidth check: 8 ch × 4 B × 48 kHz ≈ 1.5 MB/s per direction, about 200 B per 125 µs microframe: far inside USB 2.0 HS isochronous limits.

The link's channel count is a parameter of `pcm_link` (`N_CH`, 2–8, even, matching the formatter). The platform layer owns the map, as today.

---

## 5. Question 3: clock-domain bridging

Three independent clocks: the **Mac's USB clock** (SOF), **`mclk`** (12.2919 MHz, +324 ppm), and later the **network media clock**.

| Option | Where | Bit-exact | Verdict |
|---|---|---|---|
| **UAC2 feedback steered by buffer fill** | Linux half of the USB front door | **yes** | **Recommended.** The Mac follows the feedback endpoint for its OUT stream (`Capture Pitch`) and accepts the device's IN packet sizing (`Playback Pitch`). A servo holds the link-side buffer fill at its setpoint; the starting pitch is +324 ppm, the known offset. |
| ALSA-side adaptive resampling (`alsaloop -S` samplerate mode) | Linux half | no | Needed only for host mode (a USB interface can't be steered). Not needed here. |
| ASRC in the PL | PL half of a front door | no | Heavy (filter banks, DSP). The Phase 9 candidate if the media clock can't be steered; not needed for USB. |

**Where the bridging lives:** in the **USB front door's Linux half** (the bridge service), which is inside the front door as `architecture_modules.md` §2 rule 1 requires. The link doesn't bridge anything: its card is already on `mclk` time. The core never sees a foreign clock.

**The link's own safety net (PL):** if the PS-to-PL FIFO runs dry, `pcm_link` outputs **zeros** for that frame (never stale or garbage samples) and counts an underrun; a full PL-to-PS FIFO drops the frame and counts an overrun. Channel alignment uses TID, so a lost beat can't rotate channels.

**Servo implementation:** first try the stock `alsaloop` (1.2.11 has `-x/--prateshift` for the gadget's pitch control). If it can't drive the gadget's controls the way we need (both directions, setpoint on the link side), write a small C bridge (one thread, `snd_pcm_readi`/`writei`, a PI loop on `snd_pcm_delay`, pitch written with `snd_ctl_elem_write`). Either way it runs as the `fpgamixer-usb-bridge` systemd service. This is the only USB-specific software, and the AVB bridge later sits beside it with the same shape.

---

## 6. Question 5: control and status plane

`axil_coef_window` is write-oriented (shadow bank + COMMIT). Status is the opposite: counters produced in `mclk`, read by software. **Proposal: a new generic window type, `axil_stat_window`**, with the same header convention:

| Offset | Register | |
|---|---|---|
| 0x000 | ID | block type + version (link: `0x4C4B_5001`, "LK" v1) |
| 0x004 | CONFIG | block geometry (link: channels in, channels out, FIFO depth) |
| 0x008 | CTRL | ~~bit0 CLEAR~~ reads 0. **Changed in P8.3:** no CLEAR; counters are free-running, software takes differences (§12) |
| 0x00C | SNAPSHOTS | snapshots taken (so software can tell a stale read from a live one) |
| 0x100… | counters | block-specific, read-only |

- The counters live in `mclk`. They reach AXI as one **consistent snapshot** by reusing **`coef_bank_handoff` in the reverse direction** (src = `mclk`, dst = `pl_clk0`, a commit every *N* frames). The module is already direction-agnostic and its scoped XDC covers any instance, so no new CDC primitive and no new constraint. CLEAR goes the other way as a toggle synchronizer. (If a reverse instance would need XDC changes, that is flagged at implementation time, not patched around.)
- Link counters: frames in/out, underruns, overruns, FIFO fill (current, min, max since clear), TID errors.
- Binding `pcm_link_stat_regs.sv` (ID, CONFIG, counter list), same pattern as `matrix_regs_axil`. Address: **0x8000_1000**, the first free window slot. The bus-matrix/DSP reservations move up one slot, and §4.1's table is updated.
- Software: `mixer_hw.WINDOWS` entry + a `LinkStatHW` reader and a `mixer_hw.py link` CLI command. OSC exposure (read-only `get`) is optional and can wait; the bridge service can also log the counters.

---

## 7. Question 6: verification plan

**Simulation (XSim, kept in step in `scripts/sim.mk`):**

1. `tb_pcm_link`: an AXIS model of the formatter (TDATA/TID, random back-pressure and gaps, **both clocks unrelated**, `pl_clk0` ≠ `mclk` with a ppm offset) ↔ PCM contract. Checks: bit-exact samples on all 8 channels both ways; an underrun gives zeros and counts one; overruns count; a dropped beat doesn't rotate channels.
2. `tb_stat_window`: header, snapshot consistency (no torn reads across counter updates), CLEAR.
3. `tb_pcm_matrix_rect` at 12 × 12, and the existing TBs (all must still pass).
4. Software: `test_mixer_hw.py` + a 16 → 144 state-migration test; `osc_mixer_test.py --inputs 12 --buses 12`.

**Hardware, in this order (each step stands alone):**

- **S1 USB only, no PL change:** new kernel + DT + gadget. Mac sees "FPGAmixer", 8 in / 8 out, in Audio MIDI Setup. In Linux, `alsaloop` gadget capture → gadget playback: the Mac records what it plays. Proves the USB role, VBUS and the Type-C attach before anything depends on them.
- **S2 Link only, no USB:** new bitstream. `speaker-test -D plughw:fpgamixerlink -c 8` into the link; routed to JB_L/JC_L by OSC and heard on the Pmods, one channel at a time. `arecord` from the link while the Pmod ADC feeds the matrix. Status counters: no underruns at steady state.
- **S3 End to end:** the bridge service. Mac plays 8 channels (a different tone per channel); each routed to the Pmod left channels one by one and heard; Mac records the Pmod inputs back. Servo check: link FIFO fill stays flat over **≥ 30 min**, zero underruns/overruns, pitch settles near +324 ppm.
- **S4 Phase 6 follow-up:** a distinct, non-default level on **every** crosspoint (all 144), with real multichannel audio from the Mac. **Power pull**, boot, nothing typed: every crosspoint back, checked by `mixer_hw.py dump` against the saved file, and by ear/recording through the Mac (the Mac can now *record* all outputs, so the right channels are finally checked too).

---

## 8. Implementation steps (after the decisions in §9)

Each step is committed separately and verified before the next. The status doc and `architecture_modules.md` are updated in the same commit.

| Step | Content | Verified by |
|---|---|---|
| P8.1 | kernel fragment + DT (`dr_mode`) + `fpgamixer-usb-gadget` recipe | bench S1 |
| P8.2 | `pcm_link.sv` (front door, PL half) + `tb_pcm_link` | XSim |
| P8.3 | `axil_stat_window.sv` + `pcm_link_stat_regs.sv` + TB | XSim |
| P8.4 | BD: formatter, HPC0, IRQ, `aud_mclk`; `fpgamixer_top`: 12 × 12, channel map; Vivado build, timing and CDC report | Vivado reports; all TBs |
| P8.5 | ASoC machine driver module + recipe; DT card node; SDT → image | bench S2 |
| P8.6 | `mixer_hw` window + reader; migration test; OSC suite at 12 × 12 | Linux tests; board suite |
| P8.7 | `fpgamixer-usb-bridge` (alsaloop or C servo) + unit | bench S3, S4 |

---

## 9. Decisions needed from the user

| # | Question | Recommendation |
|---|---|---|
| 1 | **USB role:** device mode (the Mac sees the board as a soundcard) rather than the roadmap's host mode? | **Device mode.** It is what the Mac test needs, and it is bit-exact through the feedback endpoint. Host mode can come later over the same link. |
| 2 | **Link implementation:** (a) Audio Formatter + our own small ASoC machine driver, or (a′) no custom kernel code but AMD I2S IP as in-fabric stand-ins? | **(a).** |
| 3 | **Channels:** 8 in + 8 out over USB, core 12 × 12 (Pmods stay 0–3)? | **Yes.** 144 of 360 DSP48E2s. |
| 4 | **Seeding the new crosspoints:** identity (Mac out *k* → Mac in *k*, a loopback), all off, or Mac 1/2 → JB_L/JC_L? | **Identity:** one rule for the whole matrix, and the reset bank stays "identity". Saved state overrides it anyway. |
| 5 | **Status window:** new generic `axil_stat_window` (RO counters, same header) at 0x8000_1000? Exposed over OSC now or later? | **New window; OSC later.** |
| 6 | **Clock bridging:** feedback-endpoint servo in Linux, trying stock `alsaloop` first? | **Yes.** ASRC stays a Phase 9 question. |

### 9.1 Decisions (user, 2026-09-25)

| # | Decision |
|---|---|
| 1 | **Device mode**, and **also host mode**: the board should be able to host a class-compliant USB audio device and route its audio through the matrix. See §9.2. |
| 2 | **(a)** Audio Formatter + our own ASoC machine driver. |
| 3 | **8 + 8** link channels for the Mac, core **12 × 12**, Pmods stay 0–3. |
| 4 | New crosspoints seeded as **identity** (Mac out *k* → Mac in *k*). |
| 5 | New generic **`axil_stat_window`** at 0x8000_1000; OSC exposure later. |
| 6 | **Feedback-pitch servo in Linux**, trying stock `alsaloop` first. |

### 9.2 Host mode as well: what it means for the design

- **No role switching is needed.** Host mode uses **USB1** (the Type-A ports via the USB2513B hub), which is a separate controller and stays `dr_mode = "host"`. Device mode uses **USB0** (Type-C). So the Mac on Type-C and an interface on Type-A can be connected **at the same time**. `CONFIG_SND_USB_AUDIO=y` is already in the kernel.
- **It is a second front door, so it gets its own link.** A second `pcm_link` + formatter instance gives a second ALSA card; nothing in the first changes. `pcm_link` and the machine driver are written for *N* instances from the start (a parameter and a DT node each, no USB-specific code).
- **Clock bridging differs:** an interface's clock can't be steered, so its bridge resamples in Linux (`alsaloop` samplerate mode, or the C bridge with a resampler). That is still inside that front door's Linux half.
- **The DSP budget is the real constraint.** 4 + 8 + 8 = 20 channels fully parallel = 400 crosspoints > 360 DSP48E2s. So host mode arrives together with a **time-multiplexed `pcm_matrix`** (256 `mclk` cycles per frame are available; same ports and coefficient contract, so nothing around it changes), or with a smaller host link (the formatter supports 2/4/6/8). **Decided when that step is reached**; the device-mode steps below don't depend on it.
- New step **P8.8** (after P8.7): host-mode link instance + resampling bridge + the matrix-size decision.

---

## 10. P8.1: USB device mode (no PL change)

| File (`yocto/meta-fpgamixer/`) | What |
|---|---|
| `recipes-kernel/linux-xlnx/linux-xlnx_%.bbappend` + `files/fpgamixer-usb.cfg` (new) | `USB_GADGET=y`, `USB_DWC3_DUAL_ROLE=y`, `USB_CONFIGFS=y`, `USB_CONFIGFS_F_UAC2=y` (+ `LIBCOMPOSITE`, `U_AUDIO`, `F_UAC2`), all built in. Same SRC_URI + KERNEL_FEATURES pattern as `meta-embedded-plus`. The first kernel change in this layer. |
| `recipes-bsp/device-tree/files/system-user.dtsi` | `&dwc3_0`: `dr_mode = "peripheral"`, `maximum-speed = "high-speed"`, Digilent's susphy quirks. `&dwc3_1`: `dr_mode = "host"` (an unset dr_mode means OTG once DUAL_ROLE is built in). |
| `recipes-apps/fpgamixer-usb-gadget/` (new) | `fpgamixer-usb-gadget.sh start\|stop` (configfs: UAC2, 8 + 8 ch, 48 kHz, S24_3LE, async OUT with feedback, self-powered, VID:PID 1d6b:0104, product "FPGAmixer") + a oneshot unit, enabled. Installed to `/usr/lib/fpgamixer/`. |
| `recipes-extended/images/edf-linux-disk-image.bbappend` | + `fpgamixer-usb-gadget`, + `alsa-utils-{alsaloop,aplay,amixer,speakertest}` |

Design notes:

- **S24_3LE** on the wire (24-bit resolution, honest about the data path); the bridge opens the link card through `plughw`, which repacks to S24_LE.
- **`bcdDevice`** has to be bumped whenever the descriptors change, because macOS caches them per VID/PID/bcdDevice (script header).
- **No PL change**, so this image can run on the current bitstream. The bench test (S1) is independent of all later steps.

**Build check (VM, 2026-09-25):** `bitbake linux-xlnx fpgamixer-usb-gadget virtual/dtb`, all tasks succeeded. `bitbake-layers show-appends` lists our `linux-xlnx_%.bbappend`. The **board** kernel's `.config` (`tmp/work/genesys_zu3eg-amd-linux/…/.config`) now has `USB_DWC3_DUAL_ROLE=y` (HOST and GADGET "not set"), `USB_GADGET=y`, `USB_CONFIGFS=y`, `USB_CONFIGFS_F_UAC2=y`, `USB_U_AUDIO=y`, `USB_F_UAC2=y`. `SND_USB_AUDIO=y` and `SND_SOC_XILINX_AUDIO_FORMATTER=y` are unchanged. The deployed `system.dtb` has `dr_mode = "peripheral"` + `maximum-speed = "high-speed"` on `usb@fe200000` and `dr_mode = "host"` on `usb@fe300000`, plus the quirks.

**Pitfall recorded:** the VM has two kernel work directories. `amd_cortexa53_mali_common-amd-linux` is the stale generic smoke build and `genesys_zu3eg-amd-linux` is the board's. Always check the board one.

### Bench test S1: first result, 2026-09-25: the Type-C role, found and fixed

The first boot of the P8.1 image showed the gadget half working (service active, `UAC2Gadget` card present) but **the Mac saw nothing**: `ioreg -p IOUSB` listed only its own controllers, and `/sys/class/udc/fe200000.usb/state` stayed `not attached`. (Ethernet also had no link until a full power-off, the known DP83867 behaviour.)

**Cause: the Type-C chip made the board the *source*.** The TUSB322I, read over I2C (bus `i2c-1` = PS I2C at 0xff020000, TCA9548A mux at 0x70, branch 3 → chip at 0x47):

| Reg | Read | Meaning |
|---|---|---|
| 0x00–0x07 | `223BSUT` | device ID "TUSB322", reversed |
| 0x09 | `0x50` | ATTACHED_STATE = `01`, **Attached.SRC**: the board is DFP/host and drives VBUS |
| 0x0A | `0x06` | MODE_SELECT = `00` (follow the PORT strap: DRP here), SOURCE_PREF = `11` (**Try.SRC**) |

A Mac's port is dual-role too, so with Try.SRC the board won the negotiation as the host side. Both ends then wait for the other to be the device. The §3.2 assumption "a Mac is always the source, so the board attaches as UFP" was wrong for this board's strap. Other USB audio devices worked with the same cable because they are device-only.

**Fix, by hand first:** terminations off, MODE_SELECT = `01` (UFP), terminations on: REG 0x0A `0x07` → `0x17` → `0x16` (the TUSB32x sequence). Afterwards: 0x09 = `0x90` (**Attached.SNK**), 0x08 = `0x30` (the Mac advertises 3 A), UDC state **`addressed`**, and **"FPGAmixer" appears in Audio MIDI Setup.**

**Made permanent:** `fpgamixer-usb-gadget.sh` now calls `typec_ufp()` before binding the UDC. It finds the I2C bus by controller name (not number), selects the mux branch, applies the same sequence (keeping the other bits), and releases the mux. A failure is a warning, not fatal. The setting lasts until power-off, so it's written at every start. Recipe: `RDEPENDS = i2c-tools` (already in the image, now declared). Linux has no driver on the mux, so selecting a branch disturbs nothing.

Noted, harmless at high speed: at boot the gadget logs `FS Playback/Capture: Req. wMaxPacketSize 1176 … > max ISOC 1023`. Eight channels of 3-byte samples don't fit a full-speed isochronous packet; on the Mac's high-speed link each microframe carries ~6 frames (~150 B).

### Two devices on the Mac (open, user decision 2026-09-25)

macOS lists the gadget as **two** devices: "Playback Inactive" (0 in / 8 out) and "Capture Inactive" (8 in / 0 out). Cause, from the `f_uac2` source: the function always describes **two clock sources** ("Output Clock" for the Mac's playback, "Input Clock" for its capture) and points each direction at its own, with no option to share. macOS makes one device per clock domain. The names are `f_uac2`'s hard-coded strings for the streaming interfaces' idle settings.

**Decision:** an Aggregate Device on the Mac for now; **later, one 8 × 8 device**: a carried `f_uac2` patch in `meta-fpgamixer` that lets both directions share one clock source when the rates match (true here, since both run on `mclk` through the link) and makes the interface names configurable. Scheduled before the S3 end-to-end test.

### Bench login (user request, 2026-09-25)

EDF's distro config creates `amd-edf` with an **empty, immediately expired** password (`useradd -p '' amd-edf; passwd-expire amd-edf`, `?=` in `amd-edf.conf`), so every freshly flashed card needed a serial-console login before SSH worked. The image bbappend now replaces `EXTRA_USERS_PARAMS` when `FPGAMIXER_BENCH = 1`: `amd-edf` gets the password the user chose (as a SHA-512 crypt hash with a fixed salt, for reproducible builds) and no forced change. EDF's groups and sudoers rule are kept. A non-bench build keeps EDF's behaviour. It is a bench convenience, not security: the hash is in the repo and the password is short.

**Image rebuilt 2026-09-26** (Type-C UFP in the gadget script + bench login): 14,739 tasks, all succeeded, 22 warnings (the usual set). Checked in the rootfs tarball: `amd-edf`'s `/etc/shadow` entry has the fixed-salt hash and a normal last-change date (so no forced change); groups `aie,audio,video,wayland` and `/etc/sudoers.d/99-amd-edf` are unchanged; the packaged gadget script has `typec_ufp`; `i2cget`/`i2cset` are present. Copied to **`build/sd/p8-usb-20260926.wic.xz`** (MD5 `fef80c61…`).

### Bench test S1: PASS, 2026-09-26 (image `p8-usb-20260926`)

- Flash, power-off, boot: **SSH worked straight away with the bench login**; no serial console.
- `journalctl -u fpgamixer-usb-gadget -b`: `Type-C: TUSB322 mode register 0x06 -> 0x16 (UFP)`, `gadget bound to fe200000.usb`, so the boot sequence does the UFP switch by itself.
- The Mac lists the gadget (as two devices, see above; the user uses an Aggregate Device for now).
- **Loopback in Linux:** `alsaloop -C hw:UAC2Gadget -P hw:UAC2Gadget -f S24_3LE -c 8 -r 48000 -t 20000`, and audio played to FPGAmixer comes back on its inputs. The first try without `-f/-c/-r` failed with "Sample format not available for playback": alsaloop defaults to S16_LE stereo, and the gadget offers only S24_3LE × 8.
- Side check: OSC sets for crosspoints with USB indices (`4_4`, `4_0`, …) are logged by the server as `outside the 4x4 matrix, ignored` (no echo), as designed until P8.4. An earlier "connection reset by peer" in the console came from the board rebooting under an open session, not from a server fault (the server journal for the boot is clean).

### Bench test S1: original plan

**Image built 2026-09-25:** `bitbake edf-linux-disk-image xilinx-bootbin`, 14,739 tasks, all succeeded, the usual 22 warnings. The manifest has `fpgamixer-usb-gadget`, `libasound2` and `alsa-utils-{alsaloop,aplay,amixer,speakertest}`. The package holds the script, the unit and a `98-fpgamixer-usb-gadget.preset` (enabled). Copied to **`build/sd/p8-usb-20260925.wic.xz`** (MD5 `b3604ac9…`, same on both ends). Reflashing resets `/var/lib/fpgamixer/mixer_state.json`, as noted in Phase 6.

Needs that image flashed, then a full power-off. The existing bitstream is fine: no PL change. Expected on the board: `/sys/class/udc/fe200000.usb`, `systemctl status fpgamixer-usb-gadget` active, `aplay -l` / `arecord -l` list `UAC2Gadget`. On the Mac: "FPGAmixer" in Audio MIDI Setup, 8 in / 8 out at 48 kHz. Loopback: `alsaloop -C hw:UAC2Gadget -P hw:UAC2Gadget` on the board; the Mac records what it plays.

---

## 11. P8.2: `pcm_link`, the link's PL front door (simulation)

| File | What |
|---|---|
| `src/rtl/async_fifo.sv` (new, generic) | dual-clock FIFO: Gray pointers, 2FF syncs, power-of-two depth, first-word-fall-through, a level on each side. Plain SV (no XPM), so Icarus and XSim both run it. |
| `constraints/async_fifo.xdc` (new) | scoped to the module like `coef_bank_handoff.xdc`: 10 ns `-datapath_only` on both Gray crossings and on the LUTRAM read path. **Hooked into `create_project.tcl` (SCOPED_TO_REF) in P8.4**, when the module first enters the build. |
| `src/rtl/pcm_link.sv` (new, front door) | formatter AXIS ↔ PCM contract, `N_CH` 2–8, one frame strobe for both directions, zeros on underrun, whole-frame drop on overrun, TID sequencing with hunt-for-TID-0 recovery, status counters (mclk). Header documents the AXIS format, timing and counters. |
| `src/sim/tb_pcm_link.sv` (new) + `scripts/sim.mk` target `link` | see below |

**AXIS sample position:** `[27:4]`, the AES3-subframe layout PG330 gives for 24-bit data (Table 1), with sideband bits zero. It is a parameter (`SAMPLE_LSB`). Bench S2 confirms it with a known pattern through `arecord`; a wrong position shows up as a factor of 16 in level.

**`tb_pcm_link` (XSim), unrelated clocks (aclk 100 MHz, mclk 12.2919 MHz), 8 channels, each sample tagged {channel, frame number}: PASS.**

| Phase | Result |
|---|---|
| A paced (like the formatter's `aud_mclk` pacing) | 58 frames, consecutive, channels correct; 1 zero frame at start-up |
| B burst (source flat out) | FIFO full (64 words), TREADY back-pressure, **no frame lost**, 0 underruns |
| C source paused | zeros delivered (never stale), `starved` +32, **`underruns` +1** (one interruption), resumes in sequence |
| D out-of-range TID in one frame | `tid_errors` +6 (the bad beat + the 5 discarded after it), exactly that frame lost, **no channel rotation** |
| S2MM sink stalled for 40 frames | `overruns` +33, one gap in the stream, resumes on TID 0; `TDATA[31:28]` and `[3:0]` always zero |

**Mutation check:** swapping channel pairs in the assembler and the serializer (`tid ^ 1`) makes the TB fail with 3616 errors, so a PASS does exercise the channel mapping.

---

## 12. P8.3: the link's read-only status window (simulation)

| File | What |
|---|---|
| `src/rtl/axil_stat_window.sv` (new, generic) | read-only AXI4-Lite window: ID / CONFIG / CTRL (0) / SNAPSHOTS header, `N_STAT` words at 0x100. Writes accepted and ignored. The counterpart of `axil_coef_window`. |
| `src/rtl/pcm_link_stat_regs.sv` (new, binding) | ID `0x4C4B_5001`, CONFIG `[31:24]` ch PL→PS, `[23:16]` ch PS→PL, `[15:0]` FIFO words; ten words (FRAMES_RX/TX, UNDERRUNS, STARVED, OVERRUNS, TID_ERRORS, RX_FILL, RX_FILL_LOW/HIGH since the stream last started, FLAGS.RX_RUNNING). Map in its header. |
| `coef_bank_handoff` | **reused unchanged, in reverse** (src = `mclk`, dst = AXI clock): one snapshot per frame, all words from one `mclk` edge. Its scoped XDC covers the instance (the captured bank is held ≥ 2 destination periods, the same argument as forward). |
| `src/sim/tb_link_stat_regs.sv` + `sim.mk` target `linkstat` | below |

**Design change against §6: no CLEAR.** Counters are free-running and wrap, and software takes differences (like network interface counters). That needs no second CDC path, and two readers (the CLI, a bridge service's log) can't reset each other's view. The fill watermarks restart by themselves whenever the stream starts running.

**`tb_link_stat_regs` (XSim), unrelated clocks: PASS.** Header and write-ignoring; SNAPSHOTS +10 in 10 frames; live counters; watermarks (low 12 / high 50 across a dip and a peak, restart at 25 after a stop/start). **Atomicity:** every counter input changes on every `mclk` edge, each a different function of one cycle count; the monitor decodes the AXI-side bank on every AXI edge: **4975 banks, 0 torn.** Mutation: feeding one word from the previous `mclk` edge → 4975 of 4975 torn, FAIL. So the monitor does see a two-edge snapshot.

---

## 13. P8.4: the link in the bitstream, core 12 × 12

**`scripts/create_project.tcl`**, new `current_phase = phase8` (phase5 = the same without the link; it stays selectable):

| BD piece | What |
|---|---|
| `link_formatter` (Audio Formatter v1.0) | 8 ch each way, interleaved; formats left at the IP defaults, **MM2S PCM→AES, S2MM AES→PCM** (PCM in memory, AES3-subframe layout on the stream, sample at `[27:4]`); all AXI/AXIS clocks `pl_clk0` |
| registers | control SmartConnect grows to 3 masters: M00 matrix window (0x8000_0000), **M01 link status window (0x8000_1000)**, **M02 formatter (0x8010_0000, 64K)**. Driver-owned devices go at 0x801x_xxxx; 0x8000_x000 stays for our self-describing windows. |
| DMA | `m_axi_mm2s` + `m_axi_s2mm` → `link_dma_smc` → **`S_AXI_HPC0_FPD`** (enabled and clocked by the preset since Phase 4, unused until now). Mapped: HPC0 DDR_LOW / DDR_HIGH / … as usual. **No PS8 setting changed.** |
| IRQs | `irq_mm2s`, `irq_s2mm` → `xlconcat` → `pl_ps_irq0` (already enabled) |
| ports | `M_AXIS_LINK_MM2S`, `S_AXIS_LINK_S2MM` (AXIS, TDATA 32, TID 8, on `ctrl_aclk`); `M_AXI_LINKSTAT` (AXI4-Lite); `link_mclk` (the RTL's `mclk`, BD frequency 12.288 MHz nominal); `link_mreset` (active-high, `!rst_n`) |
| defines | `INCLUDE_PS INCLUDE_LINK`; `constraints/async_fifo.xdc` scoped to `async_fifo` |

BD notes (warnings accepted): BD 41-3281 (the PS and the formatter sit between SmartConnects, so Vivado won't auto-tune their AXI settings; the defaults are what we want); BD 41-237 AxUSER 4 → 1 bits into HPC0 (the formatter's user bits are dropped; HPC0 coherency uses AxCACHE/AxDOMAIN, not AxUSER). Two warnings were fixed on the way: `ASSOCIATED_BUSIF` named the link ports before they existed, and `link_mclk` needed `-freq_hz` at creation.

**`src/rtl/fpgamixer_top.sv`:** `N = N_PMOD + N_LINK = 4 + 8 = 12`. Channel map `core_in = {link_rx, jc_rx, jb_rx}`: Pmods stay 0–3, link 4–11 appended. Reset bank = identity (a function, replacing the hand-written 4 × 4 literal). Under `INCLUDE_LINK`: `pcm_link u_link` (frame strobe = the matrix's `jb_rx_valid`, AXIS on `ctrl_aclk`) and `pcm_link_stat_regs u_link_stat`. Without the link (non-PS builds, the integration TBs) the link inputs are zero, so the core is 12 × 12 in every build.

**`scripts/build.tcl` (new):** the batch build that used to be typed by hand. Synthesis, implementation, bitstream, methodology gate, then the timing / utilization / CDC / clock-interaction / exceptions reports and the XSA (`build/fpgamixer_<tag>.xsa`); exits non-zero on negative slack.

**Regression before the build (XSim):** `tb_phase3_datapath`, `tb_phase3_dynamic` (the whole non-PS top, now 12 × 12), `tb_pcm_matrix`, `tb_pcm_matrix_rect`: all PASS.

### First build: stopped by the methodology gate. A real CDC hole, fixed

The first full build failed the post-route methodology gate: **TIMING-6/7/8, `clk_out1_clk_wiz_audio` (mclk) and `clk_pl_0` timed together**. Listing every timed path between the two clocks from the routed checkpoint: all the LUTRAM read paths were covered by `async_fifo.xdc` (10 ns, ~6.5 ns slack). **Four paths had no exception, at −3.8 to −4.3 ns:** `u_link/u_{rx,tx}_fifo/{w,r}ptr_bin_reg[6]` → `{rsync_wptr1,wsync_rptr1}_reg[6]`.

**Cause:** a Gray code's MSB *is* the binary MSB, so synthesis merged `*ptr_gray_reg[6]` into `*ptr_bin_reg[6]` (and phys-opt even replicated one). The XDC names `*ptr_gray_reg[*]`, so the MSB of every Gray pointer crossed **with no bound**. Logically it's the same signal, but an unbounded bit in a Gray-pointer crossing is exactly how a FIFO pointer goes wrong on hardware. No simulation can see this.

**Fix:** `(* DONT_TOUCH = "TRUE" *)` on `wptr_gray` / `rptr_gray` (what AMD's XPM FIFOs do), so every launch register the XDC names survives synthesis. `tb_pcm_link` still passes. The gate was added in Phase 3 for exactly this kind of catch.

### Build result (Vivado 2026.1, `build.tcl p8`): clean

| | Phase 6 bitstream (D1+D2) | **Phase 8 (`fpgamixer_p8.xsa`)** |
|---|---|---|
| WNS / WHS | +2.282 / +0.032 ns | **+1.628 / +0.010 ns**, 0 failing endpoints, methodology gate clean, 0 critical warnings |
| worst setup path | codec RX-sampling check | `pl_clk0`: SmartConnect write address → `u_regs` shadow bank (the 144-way coefficient decode), not a clock crossing |
| LUTs / FFs | 955 / 1711 | 8453 (12%) / 19505 (14%): formatter, 2 SmartConnects, the 144-gain bank and its CDC copy |
| DSP48E2 | 16 | **144 (40%)**, one per crosspoint as planned |
| BRAM | 0 | 0 (the link FIFOs are LUTRAM) |

**CDC report, all 4193 crossings reviewed; every one carries an exception:**

| Structure | Count | Type |
|---|---|---|
| matrix gain bank (`u_regs/u_handoff`, 144 × 18 bits) | 2592 | CDC-15, the Phase 5 enable-captured bank |
| link status snapshot (`u_link_stat/u_handoff`, reverse) | 247 | CDC-15 |
| `async_fifo` LUTRAM read paths (both FIFOs; the TX one ends inside the formatter's S2MM input, since our FWFT output feeds it directly) | ~1200 | CDC-1 "unknown circuitry" + CDC-15. Vivado doesn't recognise a LUTRAM-read FIFO as a synchronizer. Safe by design (a word is read only after its pointer crossed), bounded to 10 ns, slack ~6.5 ns |
| Gray pointers, 7 bits each (4 buses) | 4 | CDC-6, ASYNC_REG, now all 7 bits |
| handoff toggles | 4 | CDC-3 |
| formatter internals (Fs multiplier, sample pulse) | 2 | AMD's `xpm_cdc`, its own false paths |

Reports: `build/p8_{timing,util,cdc,clocks,exceptions}.rpt`.

## 14. P8.5: the ALSA card (`fpgamixer-link-card`)

`yocto/meta-fpgamixer/recipes-kernel/fpgamixer-link-card/`: an out-of-tree ASoC machine driver (~140 lines) + `inherit module` recipe. One DAI link: ASoC's dummy DAI as CPU and codec (`snd_soc_dummy_dlc`), the formatter's component as platform. Its `hw_params` gives the formatter `sysclk = mclk-frequency` (12.288 MHz), so the MM2S Fs multiplier is 256 at 48 kHz. Card name `FPGAmixerLink`. Bound by DT compatible `fpgamixer,pcm-link-card` and loaded by udev from its modalias.

**A trap found by reading the formatter driver** (`xlnx_formatter_pcm.c`): on capture in AES→PCM mode (ours) its `hw_params` does `strstr(adata->nodes[XLNX_CAPTURE]->name, "hdmi")` with **no NULL check**. That node comes from the formatter's `xlnx,rx` phandle. Without that phandle, the first `arecord` would oops the kernel. So the formatter node gets `xlnx,tx` / `xlnx,rx` pointing at our card node, whose name must not contain "hdmi", "sdi" or "dp". The formatter then also spawns AMD's `xlnx_snd_card` device; its probe looks for `xlnx,snd-pcm` in our node, logs "platform node not found" and gives up (`-ENODEV`): one harmless error line, no card.

**Build check:** `bitbake fpgamixer-link-card` against the EDF 6.18.10 kernel compiles clean, no warnings; package `kernel-module-fpgamixer-link-card` → `/usr/lib/modules/6.18.10-xilinx-…/updates/fpgamixer-link-card.ko`.

**SDT (sdtgen on `fpgamixer_p8.xsa`):** the formatter node is `link_formatter: audio_formatter@80100000` with exactly what the driver asks for: clock names `aud_mclk` / `m_axis_mm2s_aclk` / `s_axi_lite_aclk` / `s_axis_s2mm_aclk`, and IRQ names `irq_mm2s` / `irq_s2mm` (GIC SPI 89/90 via `imux`). `aud_mclk` is described as `misc_clk_0`, a fixed-factor clock off `pl_clk0` (×1000/8138 = 12.288 MHz). That's only a description for the driver, since the real `mclk` comes from the PL MMCM. `M_AXI_LINKSTAT@80001000` is present (the `mixer_hw` boot guard needs it). **`psu_init.tcl` and `zynqmp.dtsi` are identical to the pre-Phase-8 SDT: the PS configuration didn't change.** The previous SDT is kept as `build/sdt.pre-phase8` (and `~/edf/sdt.pre-phase8` on the VM).

**DT + image:** `system-user.dtsi` adds the `fpgamixer-link` card node and `xlnx,tx`/`xlnx,rx` on `&link_formatter`, so this layer revision needs a Phase 8+ XSA. The image installs `kernel-module-fpgamixer-link-card`.

**Image built 2026-09-26:** `gen-machine-conf` + `bitbake edf-linux-disk-image xilinx-bootbin`, 14,802 tasks, all succeeded, the usual 22 warnings. Checked: the deployed `download-genesys-zu3eg.bit` MD5 = Vivado's `fpgamixer_p8.bit` (`8bd839eb…`); `system.dtb` has the card node (`mclk-frequency = <0xbb8000>`) and both phandles on the formatter; the rootfs has `fpgamixer-link-card.ko`. Copied to **`build/sd/p8-link-20260926.wic.xz`** (MD5 `7ef7a026…`).

## 15. P8.6: software

| File | Change |
|---|---|
| `tools/mixer_hw.py` | `LinkStatHW` (ID `0x4C4B_5001`; `read_all()` re-reads if a new snapshot lands mid-read); `WINDOWS["linkstat"] = 0x8000_1000`; CLI `link [seconds]` (counters, or deltas and rates over an interval); `info` reports windows absent from the running bitstream instead of stopping |
| `tools/osc_mixer_server.py` | simulator default `--matrix-size 12`. With `--hw` the size already comes from the window's CONFIG, so no server change was needed for 12 × 12. |
| `tools/test_mixer_hw.py` | **migration test:** a full 4 × 4 state file plus two bench routes restored onto a 12 × 12 window. The old values land at their new bank positions (`k = out·12 + in`), the 128 new crosspoints are seeded (link identity on, the rest off), the store keeps the old values, one COMMIT. Plus `LinkStat`: header/words decode, wrong-ID refusal. |

Results: `test_mixer_hw` + `test_mixer_state` on the Linux VM **28/28**; `osc_mixer_test.py --inputs 12 --buses 12` against the simulator **18/19** (the known unframed-TCP case).

---

## 17. Bench test S2 (link only): PASS, 2026-09-26 (image `p8-link-20260926`)

| Check | Result |
|---|---|
| cards | `aplay -l`: card 0 `FPGAmixerLink` ("FPGAmixer link PCM snd-soc-dummy-dai-0"), card 1 `UAC2Gadget` |
| driver | `xlnx_formatter_pcm … sound card device will use DAI link: fpgamixer-link` (tx + rx), `pcm platform device registered`; `xlnx_snd_card … platform node not found` (expected, harmless); `fpgamixer-link-card fpgamixer-link: card FPGAmixerLink on /amba_pl/audio_formatter@80100000, mclk 12288000 Hz` |
| windows | `mixer_hw.py info`: matrix **12 in × 12 out**, Q2.16; linkstat 8 + 8 ch, FIFO 64 words, snapshots advancing |
| link under `speaker-test -D plughw:FPGAmixerLink -c 8` (S16) | `mixer_hw.py link 5`: **frames_rx 48,019/s** (= mclk/256 = 48,016 Hz within a 5 s `sleep`'s precision), **starved 0, underruns 0, overruns 0, tid_errors 0**, frames_tx equal (S2MM running) |
| idle | frames_rx 0, starved 48,018/s, rx_running False: zeros into the matrix, as designed |

`rx_fill` reads 0 at every strobe. That's expected here and not a problem: the formatter delivers one frame per frame period on the same clock, and the assembler moves it to the stage register at once, so the FIFO is empty when the strobe samples it. **The health signals are `starved` / `underruns`**; the fill watermarks only mean something with a faster-than-real-time source (tb phase B).

## 18. P8.7: the bridge. alsaloop rejected, our own written

`alsaloop` (alsa-utils 1.2.11), tried on the bench, failed in three independent ways:

1. **8 periods per buffer, always** (`setparams_bufsize`: buffer = 8 × period). The formatter allows **2–6** (`PERIODS_MAX`), so hw params → `EINVAL`.
2. **`-B` / `-E` don't exist as short options:** they're missing from the `getopt_long` string in 1.2.11 (the long forms `--buffer`/`--period` work). Even then, alsaloop multiplies them (`--buffer=768` → 6144-frame buffer).
3. **`plughw:FPGAmixerLink` with S24_3LE → S24_LE conversion refuses hw params even with a valid geometry:** `aplay -D plughw:FPGAmixerLink -f S24_3LE -c 8 … --buffer-size=768 --period-size=192` → "Unable to install hw params" (4 × 6144 B, inside every limit). The same card works through `plughw` in S16 (no conversion) and through `hw:` in S24_LE. The kernel logs no error, so the refusal is in userspace. The card also advertises the newer `MSBITS_MAX` subformat, which the plug layer's conversion path in alsa-lib 1.2.11 likely mishandles. **Not proven**, and not needed: the bridge avoids plug.

`hw:FPGAmixerLink --dump-hw-params` (the real limits): S8/S16_LE/S24_LE, PERIOD_BYTES 192–51200, PERIODS 2–6, BUFFER_BYTES 192–307200. CHANNELS/RATE show the dummy DAI's wide ranges (1–384, 5512–768000); the formatter itself only accepts 2–8 channels in its `hw_params`.

**`fpgamixer-usb-bridge`** (C, ~350 lines, `yocto/meta-fpgamixer/recipes-apps/fpgamixer-usb-bridge/`):

- two threads, one per direction; both cards opened with **`hw:` in their native formats** (gadget S24_3LE, link S24_LE), the 3 ↔ 4 byte repack done in the bridge (sign-extended);
- link geometry **4 periods × 192 frames (4 ms)**, the gadget's nearest; playback prefilled to the setpoint (2 periods) and started explicitly;
- **servo**: each direction's playback queue (`snd_pcm_delay`, smoothed) is held at 384 frames by a PI loop every 100 ms (Kp 0.5 ppm/frame, Ki 0.05 ppm/frame·s, integral clamped), writing the gadget's `Capture Pitch 1000000` (A, Mac→PL, sign −) or `Playback Pitch 1000000` (B, PL→Mac, sign +). Both start at **1000324** (the measured +324 ppm) and are clamped to ±1000 ppm;
- an idle Mac: capture waits with a 1 s timeout; xruns are recovered and counted;
- logs to the journal every 10 s: frames/s, queue error, pitch, xruns. A refused setup dumps the device's full hw-params space;
- `fpgamixer-usb-bridge.service`: after the gadget, `Restart=always`, 5 s back-off, enabled. **It holds both cards while running; stop it before testing a card by hand.**

Build: `bitbake fpgamixer-usb-bridge`, and a forced recompile shows **0 warnings** under `-Wall -Wextra`.

**Image built 2026-09-26** (bridge added): 14,821 tasks, all succeeded, 22 warnings. The rootfs has `/usr/bin/fpgamixer-usb-bridge` and the enabled unit. Copied to `build/sd/p8-bridge-20260926.wic.xz` (MD5 `4a6e35e8…`), and the binary alone to `build/sd/fpgamixer-usb-bridge`, which runs on the `p8-link` image as-is for a first test without reflashing.

---

## 19. Bench test S3 (Mac ↔ matrix, clock-steered): PASS, 2026-09-26

Setup: the `p8-link` image with the bridge binary run by hand (`./fpgamixer-usb-bridge -v`); the Mac plays stereo into FPGAmixer outputs 1/2 (Aggregate Device); OSC routes USB L (in 4) → JB_L (out 0), USB R (in 5) → **JC_L** (out 2; the bench's mono cables only carry left channels), the Pmods' own inputs muted there; USB 1/2 → Mac inputs 1/2 by the identity seeding.

| Check | Result |
|---|---|
| by ear | **USB L on JB-L, USB R on JC-L: heard** |
| return path | **the Mac sees the audio coming back** on FPGAmixer inputs 1/2 |
| bridge throughput | both directions **48,016 frames/s**: the Mac runs at the board's mclk rate, not its own 48,000 |
| servo | pitch settles at **≈1000340–1000350** (+~345 ppm: the board's +324 plus the Mac's own offset); queue within a few frames of target (A −7…+3, B +17…+10 over the logged minute) |
| link counters (`mixer_hw.py link 10`) | 48,018 in and out, **starved 0, underruns 0, overruns 0, tid_errors 0** |
| xruns | A: 1, B: 68, **all at start-up**; B's (EIO / EPIPE on gadget playback) look like the Mac's input stream not running until something opens FPGAmixer's inputs (not confirmed). During them B's integrator wound up (pitch 1000718) before settling. |

Follow-ups: reset the servo's integrator and filter on every xrun (start-up overshoot); the power-cycle restore test with audio on every crosspoint (§7 S4).

---

## 20. Log

- **2026-09-25:** research + this proposal. Branch `phase8/ps-pl-audio-link`. Decisions in §9.1–9.2. Next: P8.1 (USB device mode, no PL change).
