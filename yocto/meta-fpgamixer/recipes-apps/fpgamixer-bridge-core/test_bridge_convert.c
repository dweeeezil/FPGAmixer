// SPDX-License-Identifier: MIT
/*
 * Unit test for bridge_convert.h (no ALSA needed). Any Linux host:
 *   gcc -Wall -Wextra -O2 -o t test_bridge_convert.c && ./t
 * Checks exact byte layouts against hand-written expectations (not just
 * round trips, which a symmetric bug would pass), sign extension, and round
 * trips over the whole 24-bit range's edges and a pseudo-random sweep.
 */
#include "bridge_convert.h"

#include <stdio.h>
#include <string.h>

static int fails;

#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL: " __VA_ARGS__); printf("\n"); } } while (0)

int main(void)
{
	/* exact layouts: 0x123456 and -2 (0xFFFFFE) */
	const int32_t v[2] = { 0x123456, -2 };
	uint8_t le[6], be[6];
	s32_to_s24_3le(v, le, 2);
	s32_to_s24_3be(v, be, 2);
	const uint8_t le_want[6] = { 0x56, 0x34, 0x12, 0xFE, 0xFF, 0xFF };
	const uint8_t be_want[6] = { 0x12, 0x34, 0x56, 0xFF, 0xFF, 0xFE };
	CHECK(!memcmp(le, le_want, 6), "S24_3LE layout");
	CHECK(!memcmp(be, be_want, 6), "S24_3BE layout");

	/* unpack with sign extension */
	const uint8_t be_in[9] = { 0x80, 0x00, 0x00,  0x7F, 0xFF, 0xFF,  0xFF, 0xFF, 0xFF };
	const uint8_t le_in[9] = { 0x00, 0x00, 0x80,  0xFF, 0xFF, 0x7F,  0xFF, 0xFF, 0xFF };
	const int32_t want[3] = { -8388608, 8388607, -1 };
	int32_t out[3];
	s24_3be_to_s32(be_in, out, 3);
	for (int i = 0; i < 3; i++)
		CHECK(out[i] == want[i], "S24_3BE -> s32 [%d]: %d, want %d", i, out[i], want[i]);
	s24_3le_to_s32(le_in, out, 3);
	for (int i = 0; i < 3; i++)
		CHECK(out[i] == want[i], "S24_3LE -> s32 [%d]: %d, want %d", i, out[i], want[i]);

	/* S32_BE with 24-bit audio: left-justified, low byte zero; the low byte
	 * of an incoming sample is dropped with the sign kept */
	uint8_t b4[8];
	s32_to_s32be(v, b4, 2);
	const uint8_t b4_want[8] = { 0x12, 0x34, 0x56, 0x00,  0xFF, 0xFF, 0xFE, 0x00 };
	CHECK(!memcmp(b4, b4_want, 8), "S32_BE layout");
	const uint8_t b4_in[8] = { 0x80, 0x00, 0x00, 0x7F,  0x00, 0x00, 0x01, 0xFF };
	int32_t o2[2];
	s32be_to_s32(b4_in, o2, 2);
	CHECK(o2[0] == -8388608, "S32_BE -> s32 [0]: %d", o2[0]);
	CHECK(o2[1] == 1, "S32_BE -> s32 [1]: %d", o2[1]);

	/* round trips: edges and a sweep */
	uint32_t x = 12345;
	for (int i = 0; i < 200000; i++) {
		int32_t s, r;
		uint8_t b[3];
		if (i < 6) {
			const int32_t edge[6] = { 0, 1, -1, 8388607, -8388608, 65536 };
			s = edge[i];
		} else {
			x = x * 1664525u + 1013904223u;
			s = (int32_t)(x << 8) >> 8;          /* any 24-bit value */
		}
		s32_to_s24_3be(&s, b, 1); s24_3be_to_s32(b, &r, 1);
		CHECK(r == s, "BE round trip %d -> %d", s, r);
		s32_to_s24_3le(&s, b, 1); s24_3le_to_s32(b, &r, 1);
		CHECK(r == s, "LE round trip %d -> %d", s, r);
		uint8_t q[4];
		s32_to_s32be(&s, q, 1); s32be_to_s32(q, &r, 1);
		CHECK(r == s, "S32_BE round trip %d -> %d", s, r);
		if (fails > 10)
			break;
	}

	printf(fails ? "FAIL test_bridge_convert (%d)\n" : "PASS test_bridge_convert\n", fails);
	return fails != 0;
}
