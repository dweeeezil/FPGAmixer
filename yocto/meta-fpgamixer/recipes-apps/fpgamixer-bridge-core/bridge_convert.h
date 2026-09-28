// SPDX-License-Identifier: MIT
/*
 * bridge_convert.h: the sample repacking the FPGAmixer bridges need, with no
 * ALSA dependency so it can be unit-tested anywhere (test_bridge_convert.c).
 *
 * The link cards (FPGAmixerLink, FPGAmixerLink2) use S24_LE: 24 bits
 * LSB-justified in a 32-bit word, sign-extended; here an int32_t. The other
 * ends use 3-byte packed samples: the UAC2 gadget S24_3LE, the AAF devices
 * S24_3BE (docs/phase9_status_2026-09-26.md sec. 6.12, decision A4).
 */
#ifndef BRIDGE_CONVERT_H
#define BRIDGE_CONVERT_H

#include <stddef.h>
#include <stdint.h>

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

#endif
