// SPDX-License-Identifier: MIT
/*
 * bridge_convert.h: the sample repacking the FPGAmixer bridges need, with no
 * ALSA dependency so it can be unit-tested anywhere (test_bridge_convert.c).
 *
 * The link cards (FPGAmixerLink, FPGAmixerLink2) use S24_LE: 24 bits
 * LSB-justified in a 32-bit word; here an int32_t, sign-extended on the way
 * in by s24le_to_s32 (the top byte isn't relied on). The other
 * ends use 3-byte packed samples: the UAC2 gadget S24_3LE, the AAF devices
 * S24_3BE (docs/phase9_status_2026-09-26.md sec. 6.12, decision A4).
 */
#ifndef BRIDGE_CONVERT_H
#define BRIDGE_CONVERT_H

#include <stddef.h>
#include <stdint.h>

/*
 * S24_LE as read from a link card: 24 bits in the low three bytes of a
 * 32-bit word. The top byte is NOT trusted to be the sign extension (never
 * measured for the formatter's capture side; Phase 11 H.2: the first user
 * that reads the whole int32, the resampler, heard noise): sign-extend from
 * bit 23 here, whatever the top byte holds.
 */
static inline void s24le_to_s32(const int32_t *in, int32_t *out, size_t n)
{
	for (size_t i = 0; i < n; i++)
		out[i] = (int32_t)((uint32_t)in[i] << 8) >> 8;
}

static inline void s24_3le_to_s32(const uint8_t *in, int32_t *out, size_t n)
{
	for (size_t i = 0; i < n; i++, in += 3) {
		uint32_t v = in[0] | (in[1] << 8) | ((uint32_t)in[2] << 16);
		out[i] = (int32_t)(v << 8) >> 8;
	}
}

static inline void s24_3be_to_s32(const uint8_t *in, int32_t *out, size_t n)
{
	for (size_t i = 0; i < n; i++, in += 3) {
		uint32_t v = ((uint32_t)in[0] << 16) | (in[1] << 8) | in[2];
		out[i] = (int32_t)(v << 8) >> 8;
	}
}

static inline void s32_to_s24_3le(const int32_t *in, uint8_t *out, size_t n)
{
	for (size_t i = 0; i < n; i++, out += 3) {
		out[0] = (uint8_t)in[i];
		out[1] = (uint8_t)(in[i] >> 8);
		out[2] = (uint8_t)(in[i] >> 16);
	}
}

static inline void s32_to_s24_3be(const int32_t *in, uint8_t *out, size_t n)
{
	for (size_t i = 0; i < n; i++, out += 3) {
		out[0] = (uint8_t)(in[i] >> 16);
		out[1] = (uint8_t)(in[i] >> 8);
		out[2] = (uint8_t)in[i];
	}
}

/*
 * S32_BE carrying 24-bit audio (AAF INT_32BIT with bit_depth 24, Milan's base
 * format, Phase 10): the 24 bits left-justified, the low byte zero. On the
 * way in the low byte is dropped (arithmetic shift keeps the sign).
 */
static inline void s32be_to_s32(const uint8_t *in, int32_t *out, size_t n)
{
	for (size_t i = 0; i < n; i++, in += 4) {
		uint32_t v = ((uint32_t)in[0] << 24) | ((uint32_t)in[1] << 16) |
			     ((uint32_t)in[2] << 8) | in[3];
		out[i] = (int32_t)v >> 8;
	}
}

static inline void s32_to_s32be(const int32_t *in, uint8_t *out, size_t n)
{
	for (size_t i = 0; i < n; i++, out += 4) {
		out[0] = (uint8_t)(in[i] >> 16);
		out[1] = (uint8_t)(in[i] >> 8);
		out[2] = (uint8_t)in[i];
		out[3] = 0;
	}
}

/*
 * S32_LE carrying 24-bit audio (Phase 11: the MOTU M2 through snd-usb-audio,
 * "Format: S32_LE, Bits: 24"): the 24 bits left-justified in a little-endian
 * 32-bit word. Same layout as S32_BE above, the other byte order. Read as
 * bytes, so it is correct on any host.
 */
static inline void s32le_to_s32(const uint8_t *in, int32_t *out, size_t n)
{
	for (size_t i = 0; i < n; i++, in += 4) {
		uint32_t v = in[0] | ((uint32_t)in[1] << 8) | ((uint32_t)in[2] << 16) |
			     ((uint32_t)in[3] << 24);
		out[i] = (int32_t)v >> 8;
	}
}

static inline void s32_to_s32le(const int32_t *in, uint8_t *out, size_t n)
{
	for (size_t i = 0; i < n; i++, out += 4) {
		out[0] = 0;
		out[1] = (uint8_t)in[i];
		out[2] = (uint8_t)(in[i] >> 8);
		out[3] = (uint8_t)(in[i] >> 16);
	}
}

#endif
