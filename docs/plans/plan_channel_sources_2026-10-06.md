# Plan: channel sources (generic channels, I/O patching)

**Written:** 2026-10-06 17:40 PDT (2026-10-07 00:40 UTC), at the end of Phase 13, on branch `phase13-metering` (commit `d3c1587`).
**Status:** plan only, nothing built. Order agreed in principle: **snapshots → virtual groups → channel sources**, after Phase 11 (USB host mode), which the user put first on 2026-10-06, together with **retiring the Pmods** ("I think it's time to ditch the pmods", 2026-10-06).
**Companions:** `plan_snapshots_2026-10-06.md`, `plan_virtual_groups_2026-10-06.md`; session prompt `docs/prompt_phase14_qol.md`.

---

## The request (user, 2026-10-06)

> "Having Analog, USB, and AVB is great, but I rarely need all at once, and finding the right channel is a pain. I'd like to be able to configure the mixer to N×Y×Z channels, with each channel being generic. I'd like to then be able to assign input channel sources and output channel destinations in the UI. For example, I could go in and assign inputs 1–5 to AVB 4–9, and then set output channels 1–3 to USB 1–3."

## Today

Core channel k **is** physical port k (`fpgamixer_top`'s channel map `{link2, link, jc, jb}`: 0–3 Pmod, 4–11 USB, 12–19 AVB; Phase 11 appends the MOTU at 20–27). Every saved index follows that map ("appended, never interleaved").

## Shape (recommended; to be decided in a proposal)

- **A patch on each side of the core, in the PL**, as selectors (one source per destination; no mixing):
  - before the core: **input channel k ← physical input `src[k]`** (or none);
  - after it: **physical output p ← output channel `sel[p]`** (or none).
  Each table is a small coefficient bank (`coef_bank_ram`, row length 1) in its own register window (from **0x8000_C000** on, after Phase 11's link #3 window, which takes the next free slot first). Physical port numbers keep the "appended, never interleaved" rule; **core channel numbers become the user's**.
- **Cost and latency:** do the input selection inside `pcm_pack2stream` (it emits one channel per cycle: read `in_flat[src[k]]` through a read port, one N:1 mux, ~1 cycle) and the output selection after `pcm_stream2pack` (a registered mux, or per-beat writes into every output that selects the beat's channel). Today **D = 249 of D_MAX = 250**, and D_MAX comes from the **Pmods'** `i2s_port` (it samples on edge 254). **With the Pmods retired** the limit becomes the links' capture at the next strobe, and D_MAX can loosen (to be re-derived and checked at elaboration, `mixer_core_pkg`); otherwise the lane chooser spends DSPs.
- **The default patch is identity**, so every saved state keeps its meaning.
- **N×Y×Z:** the gateware is built at fixed maximum sizes (DSP and latency budget). Recommend **runtime counts per zone** as system settings: the server advertises only the first N / Y / Z channels (the rest unpatched and silent), so a count change needs no rebuild, only the "config changed" broadcast from the snapshots plan. Window size limit: a 4 KB window holds at most **960** coefficients (0x100 + 4k ≤ 0x1000), so a matrix above 30 × 32 needs bigger windows (an 8 KB BD range and `ADDR_WIDTH` 13).
- **Protocol:** per input channel a **`source`**, per output channel a **`destination`** (the app's D64 already proposes `source`). Pickers from a fixed list of physical ports ("USB 1–8", "AVB 1–8", "MOTU 1–2", the Pmods while they exist). The standard's enums are **numbers only**, so add **option labels** (an optional `optionLabels` list beside `options`: additive, no `schemaVersion` bump), and the app shows them.
- **Decide:** outputs as "each output channel picks one destination" (the user's phrasing) vs "each physical output picks one output channel" (what the hardware does; lets one channel feed two places). The server can present the first on top of the second; assigning a destination another channel holds either steals it (the other becomes none, echoed) or is refused.

## Interaction with retiring the Pmods

If the Pmods' RTL is removed (Phase 11 decides when): their physical ports 0–3 are **retired, not reused** (the rule from Phase 11 §6.1); with this plan's patch that stops mattering to the user, because core channel numbers no longer follow physical ports. The frame strobe, which today comes from the Pmod I2S receiver (`jb_rx_valid`), must then come from the clock divider directly.

## Seams

Front door → core boundary (the patch sits between the packed contract and the stream converters, or inside them); control plane (two windows, two backends or a `source`/`destination` module on the channel backends); platform (the physical port list, named, owned by `fpgamixer_top`); protocol (option labels); app (pickers).

## Tests to plan

RTL: the patch bit-exact against a model at random tables, timing to the cycle, "none" = silence, identity = today's behaviour; core D re-checked. Server: assignments, steal/refuse rule, counts changing the config, snapshots carrying the patch. Bench: the user's own example (inputs 1–5 ← AVB 4–9, outputs 1–3 → USB 1–3) by ear. Mutation-tested.

## App work (controller repo, handoff)

Source / destination pickers on the strips (with the labels); the channel-count settings; refetching the config on "config changed".
