/*
 * Copyright (c) 2016 Clément Bœsch <clement stupeflix.com>
 * Copyright (c) 2019-2021 Sebastian Pop <spop@amazon.com>
 * Copyright (c) 2022 Jonathan Swinney <jswinney@amazon.com>
 *
 * This file is part of FFmpeg.
 *
 * FFmpeg is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * FFmpeg is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FFmpeg; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#include "libavutil/aarch64/asm.S"

/*
;-----------------------------------------------------------------------------
; horizontal line scaling
;
; void hscale<source_width>to<intermediate_nbits>_<filterSize>_<opt>
;                               (SwsInternal *c, int{16,32}_t *dst,
;                                int dstW, const uint{8,16}_t *src,
;                                const int16_t *filter,
;                                const int32_t *filterPos, int filterSize);
;
; Scale one horizontal line. Input is either 8-bit width or 16-bit width
; ($source_width can be either 8, 9, 10 or 16, difference is whether we have to
; downscale before multiplying). Filter is 14 bits. Output is either 15 bits
; (in int16_t) or 19 bits (in int32_t), as given in $intermediate_nbits. Each
; output pixel is generated from $filterSize input pixels, the position of
; the first pixel is given in filterPos[nOutputPixel].
;----------------------------------------------------------------------------- */

function ff_hscale8to15_X8_neon, export=1
        sbfiz           x7, x6, #1, #32             // filterSize*2 (*2 because int16)
1:      ldr             w8, [x5], #4                // filterPos[idx]
        ldr             w0, [x5], #4                // filterPos[idx + 1]
        ldr             w11, [x5], #4               // filterPos[idx + 2]
        ldr             w9, [x5], #4                // filterPos[idx + 3]
        mov             x16, x4                     // filter0 = filter
        add             x12, x16, x7                // filter1 = filter0 + filterSize*2
        add             x13, x12, x7                // filter2 = filter1 + filterSize*2
        add             x4, x13, x7                 // filter3 = filter2 + filterSize*2
        movi            v0.16b, #0                  // val sum part 1 (for dst[0])
        movi            v1.16b, #0                  // val sum part 2 (for dst[1])
        movi            v2.16b, #0                  // val sum part 3 (for dst[2])
        movi            v3.16b, #0                  // val sum part 4 (for dst[3])
        add             x17, x3, w8, uxtw           // srcp + filterPos[0]
        add             x8,  x3, w0, uxtw           // srcp + filterPos[1]
        add             x0, x3, w11, uxtw           // srcp + filterPos[2]
        add             x11, x3, w9, uxtw           // srcp + filterPos[3]
        mov             w15, w6                     // filterSize counter
2:      ld1             {v4.8b}, [x17], #8          // srcp[filterPos[0] + {0..7}]
        ld1             {v5.8h}, [x16], #16         // load 8x16-bit filter values, part 1
        ld1             {v6.8b}, [x8], #8           // srcp[filterPos[1] + {0..7}]
        ld1             {v7.8h}, [x12], #16         // load 8x16-bit at filter+filterSize
        uxtl            v4.8h, v4.8b                // unpack part 1 to 16-bit
        smlal           v0.4s, v4.4h, v5.4h         // v0 accumulates srcp[filterPos[0] + {0..3}] * filter[{0..3}]
        smlal2          v0.4s, v4.8h, v5.8h         // v0 accumulates srcp[filterPos[0] + {4..7}] * filter[{4..7}]
        ld1             {v16.8b}, [x0], #8          // srcp[filterPos[2] + {0..7}]
        ld1             {v17.8h}, [x13], #16        // load 8x16-bit at filter+2*filterSize
        uxtl            v6.8h, v6.8b                // unpack part 2 to 16-bit
        smlal           v1.4s, v6.4h, v7.4h         // v1 accumulates srcp[filterPos[1] + {0..3}] * filter[{0..3}]
        uxtl            v16.8h, v16.8b              // unpack part 3 to 16-bit
        smlal           v2.4s, v16.4h, v17.4h       // v2 accumulates srcp[filterPos[2] + {0..3}] * filter[{0..3}]
        smlal2          v2.4s, v16.8h, v17.8h       // v2 accumulates srcp[filterPos[2] + {4..7}] * filter[{4..7}]
        ld1             {v18.8b}, [x11], #8         // srcp[filterPos[3] + {0..7}]
        smlal2          v1.4s, v6.8h, v7.8h         // v1 accumulates srcp[filterPos[1] + {4..7}] * filter[{4..7}]
        ld1             {v19.8h}, [x4], #16         // load 8x16-bit at filter+3*filterSize
        subs            w15, w15, #8                // j -= 8: processed 8/filterSize
        uxtl            v18.8h, v18.8b              // unpack part 4 to 16-bit
        smlal           v3.4s, v18.4h, v19.4h       // v3 accumulates srcp[filterPos[3] + {0..3}] * filter[{0..3}]
        smlal2          v3.4s, v18.8h, v19.8h       // v3 accumulates srcp[filterPos[3] + {4..7}] * filter[{4..7}]
        b.gt            2b                          // inner loop if filterSize not consumed completely
        addp            v0.4s, v0.4s, v1.4s         // part01 horizontal pair adding
        addp            v2.4s, v2.4s, v3.4s         // part23 horizontal pair adding
        addp            v0.4s, v0.4s, v2.4s         // part0123 horizontal pair adding
        subs            w2, w2, #4                  // dstW -= 4
        sqshrn          v0.4h, v0.4s, #7            // shift and clip the 2x16-bit final values
        st1             {v0.4h}, [x1], #8           // write to destination part0123
        b.gt            1b                          // loop until end of line
        ret
endfunc

function ff_hscale8to15_X4_neon, export=1
// x0  SwsInternal *c (not used)
// x1  int16_t *dst
// w2  int dstW
// x3  const uint8_t *src
// x4  const int16_t *filter
// x5  const int32_t *filterPos
// w6  int filterSize

// This function for filter sizes that are 4 mod 8. In other words, anything that's 0 mod 4 but not
// 0 mod 8. It also assumes that dstW is 0 mod 4.

        lsl             w7, w6, #1                  // w7 = filterSize * 2
1:
        ldp             w8, w9,  [x5]               // filterPos[idx + 0], [idx + 1]
        ldp             w10, w11, [x5, #8]          // filterPos[idx + 2], [idx + 3]

        movi            v16.16b, #0                 // initialize accumulator for idx + 0
        movi            v17.16b, #0                 // initialize accumulator for idx + 1
        movi            v18.16b, #0                 // initialize accumulator for idx + 2
        movi            v19.16b, #0                 // initialize accumulator for idx + 3

        mov             x12, x4                     // filter pointer for idx + 0
        add             x13, x4, x7                 // filter pointer for idx + 1
        add             x8, x3, w8, uxtw            // srcp + filterPos[idx + 0]
        add             x9, x3, w9, uxtw            // srcp + filterPos[idx + 1]

        add             x14, x13, x7                // filter pointer for idx + 2
        add             x10, x3, w10, uxtw          // srcp + filterPos[idx + 2]
        add             x11, x3, w11, uxtw          // srcp + filterPos[idx + 3]

        mov             w0, w6                      // copy filterSize to a temp register, w0
        add             x5, x5, #16                 // advance the filterPos pointer
        add             x15, x14, x7                // filter pointer for idx + 3
        mov             x16, xzr                    // temp register for offsetting filter pointers

2:
        // This section loops over 8-wide chunks of filter size
        ldr             d4, [x8], #8                // load 8 bytes from srcp for idx + 0
        ldr             q0, [x12, x16]              // load 8 values, 16 bytes from filter for idx + 0

        ldr             d5, [x9], #8                // load 8 bytes from srcp for idx + 1
        ldr             q1, [x13, x16]              // load 8 values, 16 bytes from filter for idx + 1

        uxtl            v4.8h, v4.8b                // unsigned extend long for idx + 0
        uxtl            v5.8h, v5.8b                // unsigned extend long for idx + 1

        ldr             d6, [x10], #8               // load 8 bytes from srcp for idx + 2
        ldr             q2, [x14, x16]              // load 8 values, 16 bytes from filter for idx + 2

        smlal           v16.4s, v0.4h, v4.4h        // val += src[srcPos + j + 0..3] * filter[fs * i + j + 0..3], idx + 0
        smlal           v17.4s, v1.4h, v5.4h        // val += src[srcPos + j + 0..3] * filter[fs * i + j + 0..3], idx + 1

        ldr             d7, [x11], #8               // load 8 bytes from srcp for idx + 3
        ldr             q3, [x15, x16]              // load 8 values, 16 bytes from filter for idx + 3

        sub             w0, w0, #8                  // decrement the remaining filterSize counter
        smlal2          v16.4s, v0.8h, v4.8h        // val += src[srcPos + j + 4..7] * filter[fs * i + j + 4..7], idx + 0
        smlal2          v17.4s, v1.8h, v5.8h        // val += src[srcPos + j + 4..7] * filter[fs * i + j + 4..7], idx + 1
        uxtl            v6.8h, v6.8b                // unsigned extend long for idx + 2
        uxtl            v7.8h, v7.8b                // unsigned extend long for idx + 3
        smlal           v18.4s, v2.4h, v6.4h        // val += src[srcPos + j + 0..3] * filter[fs * i + j + 0..3], idx + 2
        smlal           v19.4s, v3.4h, v7.4h        // val += src[srcPos + j + 0..3] * filter[fs * i + j + 0..3], idx + 3

        cmp             w0, #8                      // are there at least 8 more elements in filter to consume?
        add             x16, x16, #16               // advance the offsetting register for filter values

        smlal2          v18.4s, v2.8h, v6.8h        // val += src[srcPos + j + 4..7] * filter[fs * i + j + 4..7], idx + 2
        smlal2          v19.4s, v3.8h, v7.8h        // val += src[srcPos + j + 4..7] * filter[fs * i + j + 4..7], idx + 3

        b.ge            2b                          // branch back to inner loop

        // complete the remaining 4 filter elements
        sub             x17, x7, #8                 // calculate the offset of the filter pointer for the remaining 4 elements

        ldr             s4, [x8]                    // load 4 bytes from srcp for idx + 0
        ldr             d0, [x12, x17]              // load 4 values, 8 bytes from filter for idx + 0
        ldr             s5, [x9]                    // load 4 bytes from srcp for idx + 1
        ldr             d1, [x13, x17]              // load 4 values, 8 bytes from filter for idx + 1

        uxtl            v4.8h, v4.8b                // unsigned extend long for idx + 0
        uxtl            v5.8h, v5.8b                // unsigned extend long for idx + 1

        ldr             s6, [x10]                   // load 4 bytes from srcp for idx + 2
        ldr             d2, [x14, x17]              // load 4 values, 8 bytes from filter for idx + 2
        smlal           v16.4s, v0.4h, v4.4h        // val += src[srcPos + j + 0..3] * filter[fs * i + j + 0..3], idx + 0
        smlal           v17.4s, v1.4h, v5.4h        // val += src[srcPos + j + 0..3] * filter[fs * i + j + 0..3], idx + 1
        ldr             s7, [x11]                   // load 4 bytes from srcp for idx + 3
        ldr             d3, [x15, x17]              // load 4 values, 8 bytes from filter for idx + 3

        uxtl            v6.8h, v6.8b                // unsigned extend long for idx + 2
        uxtl            v7.8h, v7.8b                // unsigned extend long for idx + 3
        addp            v16.4s, v16.4s, v17.4s      // horizontal pair adding for idx 0,1
        smlal           v18.4s, v2.4h, v6.4h        // val += src[srcPos + j + 0..3] * filter[fs * i + j + 0..3], idx + 2
        smlal           v19.4s, v3.4h, v7.4h        // val += src[srcPos + j + 0..3] * filter[fs * i + j + 0..3], idx + 3

        addp            v18.4s, v18.4s, v19.4s      // horizontal pair adding for idx 2,3
        addp            v16.4s, v16.4s, v18.4s      // final horizontal pair adding producing one vector with results for idx = 0..3

        subs            w2, w2, #4                  // dstW -= 4
        sqshrn          v0.4h, v16.4s, #7           // shift and clip the 2x16-bit final values
        st1             {v0.4h}, [x1], #8           // write to destination idx 0..3
        add             x4, x4, x7, lsl #2          // filter += (filterSize*2) * 4
        b.gt            1b                          // loop until end of line
        ret
endfunc

// 4-tap hscale with register tbl-transpose.
//
// For each group of 8 output pixels the 4 contiguous source bytes of each
// pixel are gathered into two 128-bit words, and the four byte-planes (one
// per filter tap, across all 8 pixels) are extracted with a register tbl.
// This avoids the store-to-stack + ld4 transpose of the reference kernel,
// keeping the gather path in registers.  Uses only caller-saved registers,
// so no callee-saved saves or stack allocation are required.
const .Lhsc_e_idx0, align=4
        .byte   0,  4,  8, 12, 16, 20, 24, 28,  0,  0,  0,  0,  0,  0,  0,  0
endconst
const .Lhsc_e_idx1, align=4
        .byte   1,  5,  9, 13, 17, 21, 25, 29,  0,  0,  0,  0,  0,  0,  0,  0
endconst
const .Lhsc_e_idx2, align=4
        .byte   2,  6, 10, 14, 18, 22, 26, 30,  0,  0,  0,  0,  0,  0,  0,  0
endconst
const .Lhsc_e_idx3, align=4
        .byte   3,  7, 11, 15, 19, 23, 27, 31,  0,  0,  0,  0,  0,  0,  0,  0
endconst
function ff_hscale8to15_4_neon, export=1
// x0  SwsInternal *c (not used)
// x1  int16_t *dst
// w2  int dstW
// x3  const uint8_t *src
// x4  const int16_t *filter
// x5  const int32_t *filterPos
// w6  int filterSize (not used; fixed at 4)
//
// v0       accumulator for output pixels 0..3
// v5       accumulator for output pixels 4..7
// v16-v19  the four byte-planes (tap 0..3) after the tbl transpose
// v24-v27  the four tbl index vectors
// v28-v29  the packed 8 gathered source windows
        cmp             w2, #8
        b.lt            .Lhscale4_tail
        movrel          x6, .Lhsc_e_idx0
        movrel          x7, .Lhsc_e_idx1
        movrel          x8, .Lhsc_e_idx2
        movrel          x9, .Lhsc_e_idx3
        ldr             q24, [x6]
        ldr             q25, [x7]
        ldr             q26, [x8]
        ldr             q27, [x9]
.Lhscale4_loop:
        // gather the 8 filter positions for this group
        ldp             w8,  w9,  [x5]
        ldp             w10, w11, [x5, #8]
        ldp             w12, w13, [x5, #16]
        ldp             w14, w15, [x5, #24]
        add             x5, x5, #32
        // gather the 8 source windows (4 contiguous bytes each)
        ldr             w8,  [x3, w8,  uxtw]
        ldr             w9,  [x3, w9,  uxtw]
        ldr             w10, [x3, w10, uxtw]
        ldr             w11, [x3, w11, uxtw]
        ldr             w12, [x3, w12, uxtw]
        ldr             w13, [x3, w13, uxtw]
        ldr             w14, [x3, w14, uxtw]
        ldr             w15, [x3, w15, uxtw]
        // pack the 8 gathered words into two 128-bit registers
        ins             v28.s[0], w8
        ins             v28.s[1], w9
        ins             v28.s[2], w10
        ins             v28.s[3], w11
        ins             v29.s[0], w12
        ins             v29.s[1], w13
        ins             v29.s[2], w14
        ins             v29.s[3], w15
        // transpose: byte-plane j holds tap j of all 8 pixels
        tbl             v16.8b, {v28.16b, v29.16b}, v24.8b
        tbl             v17.8b, {v28.16b, v29.16b}, v25.8b
        tbl             v18.8b, {v28.16b, v29.16b}, v26.8b
        tbl             v19.8b, {v28.16b, v29.16b}, v27.8b
        ld4             {v1.8h, v2.8h, v3.8h, v4.8h}, [x4], #64
        uxtl            v16.8h, v16.8b            // unsigned extend the byte-planes
        uxtl            v17.8h, v17.8b
        uxtl            v18.8h, v18.8b
        uxtl            v19.8h, v19.8b
        movi            v0.16b, #0
        movi            v5.16b, #0
        smlal           v0.4s, v1.4h, v16.4h      // taps 0..3 for pixels 0..3
        smlal           v0.4s, v2.4h, v17.4h
        smlal           v0.4s, v3.4h, v18.4h
        smlal           v0.4s, v4.4h, v19.4h
        smlal2          v5.4s, v1.8h, v16.8h      // taps 0..3 for pixels 4..7
        smlal2          v5.4s, v2.8h, v17.8h
        smlal2          v5.4s, v3.8h, v18.8h
        smlal2          v5.4s, v4.8h, v19.8h
        sqshrn          v0.4h, v0.4s, #7          // >>7 and saturate-narrow to 16-bit
        sqshrn          v1.4h, v5.4s, #7
        st1             {v0.4h, v1.4h}, [x1], #16 // write 8 output pixels
        sub             w2, w2, #8
        cmp             w2, #8
        b.ge            .Lhscale4_loop
.Lhscale4_tail:
        cbz             w2, .Lhscale4_end
.Lhscale4_tail_loop:
        // scalar tail for the remaining dstW % 8 (1..7) pixels
        ldr             w8,  [x5], #4              // filterPos[i]
        add             x9,  x3, w8, uxtw
        ld1             {v5.s}[0], [x9]            // src[filterPos[i] + 0..3]
        ld1             {v6.4h}, [x4], #8          // filter[4*i + 0..3]
        uxtl            v5.8h, v5.8b
        smull           v0.4s, v5.4h, v6.4h
        addv            s0, v0.4s
        sqshrn          h0, s0, #7
        st1             {v0.h}[0], [x1], #2
        subs            w2, w2, #1
        b.ne            .Lhscale4_tail_loop
.Lhscale4_end:
        ret
endfunc

function ff_hscale8to19_4_neon, export=1
        // x0               SwsInternal *c (unused)
        // x1               int32_t *dst
        // w2               int dstW
        // x3               const uint8_t *src // treat it as uint16_t *src
        // x4               const uint16_t *filter
        // x5               const int32_t *filterPos
        // w6               int filterSize

        movi            v18.4s, #1
        movi            v17.4s, #1
        shl             v18.4s, v18.4s, #19
        sub             v18.4s, v18.4s, v17.4s      // max allowed value

        cmp             w2, #16
        b.lt            2f // move to last block

        ldp             w8, w9, [x5]                // filterPos[0], filterPos[1]
        ldp             w10, w11, [x5, #8]          // filterPos[2], filterPos[3]
        ldp             w12, w13, [x5, #16]         // filterPos[4], filterPos[5]
        ldp             w14, w15, [x5, #24]         // filterPos[6], filterPos[7]
        add             x5, x5, #32

        // load data from
        ldr             w8, [x3, w8, uxtw]
        ldr             w9, [x3, w9, uxtw]
        ldr             w10, [x3, w10, uxtw]
        ldr             w11, [x3, w11, uxtw]
        ldr             w12, [x3, w12, uxtw]
        ldr             w13, [x3, w13, uxtw]
        ldr             w14, [x3, w14, uxtw]
        ldr             w15, [x3, w15, uxtw]

        // E-style: register tbl-transpose (drop-in for store-to-stack + ld4),
        // removing the memory round-trip from the gather path. Bit-exact.
        adrp            x6, .Lhsc_e_idx0
        add             x6, x6, :lo12:.Lhsc_e_idx0
        ldr             q24, [x6, #0]
        ldr             q25, [x6, #16]
        ldr             q26, [x6, #32]
        ldr             q27, [x6, #48]
        ins             v16.s[0], w8
        ins             v16.s[1], w9
        ins             v16.s[2], w10
        ins             v16.s[3], w11
        ins             v17.s[0], w12
        ins             v17.s[1], w13
        ins             v17.s[2], w14
        ins             v17.s[3], w15

1:
        tbl             v0.8b, {v16.16b, v17.16b}, v24.8b
        tbl             v1.8b, {v16.16b, v17.16b}, v25.8b
        tbl             v2.8b, {v16.16b, v17.16b}, v26.8b
        tbl             v3.8b, {v16.16b, v17.16b}, v27.8b
        ld4             {v28.8h, v29.8h, v30.8h, v31.8h}, [x4], #64 // filter[0..7]
        // load filterPositions into registers for next iteration

        ldp             w8, w9, [x5]                // filterPos[0], filterPos[1]
        ldp             w10, w11, [x5, #8]          // filterPos[2], filterPos[3]
        ldp             w12, w13, [x5, #16]         // filterPos[4], filterPos[5]
        ldp             w14, w15, [x5, #24]         // filterPos[6], filterPos[7]
        add             x5, x5, #32
        uxtl            v0.8h, v0.8b
        ldr             w8, [x3, w8, uxtw]
        smull           v5.4s, v0.4h, v28.4h        // multiply first column of src
        ldr             w9, [x3, w9, uxtw]
        smull2          v6.4s, v0.8h, v28.8h
        ins             v16.s[0], w8
        ins             v16.s[1], w9

        uxtl            v1.8h, v1.8b
        ldr             w10, [x3, w10, uxtw]
        smlal           v5.4s, v1.4h, v29.4h        // multiply second column of src
        ldr             w11, [x3, w11, uxtw]
        smlal2          v6.4s, v1.8h, v29.8h
        ins             v16.s[2], w10
        ins             v16.s[3], w11

        uxtl            v2.8h, v2.8b
        ldr             w12, [x3, w12, uxtw]
        smlal           v5.4s, v2.4h, v30.4h        // multiply third column of src
        ldr             w13, [x3, w13, uxtw]
        smlal2          v6.4s, v2.8h, v30.8h
        ins             v17.s[0], w12
        ins             v17.s[1], w13

        uxtl            v3.8h, v3.8b
        ldr             w14, [x3, w14, uxtw]
        smlal           v5.4s, v3.4h, v31.4h        // multiply fourth column of src
        ldr             w15, [x3, w15, uxtw]
        smlal2          v6.4s, v3.8h, v31.8h
        ins             v17.s[2], w14
        ins             v17.s[3], w15

        sub             w2, w2, #8
        sshr            v5.4s, v5.4s, #3
        sshr            v6.4s, v6.4s, #3
        smin            v5.4s, v5.4s, v18.4s
        smin            v6.4s, v6.4s, v18.4s

        st1             {v5.4s, v6.4s}, [x1], #32
        cmp             w2, #16
        b.ge            1b

        // here we make last iteration, without updating the registers
        tbl             v0.8b, {v16.16b, v17.16b}, v24.8b
        tbl             v1.8b, {v16.16b, v17.16b}, v25.8b
        tbl             v2.8b, {v16.16b, v17.16b}, v26.8b
        tbl             v3.8b, {v16.16b, v17.16b}, v27.8b
        ld4             {v28.8h, v29.8h, v30.8h, v31.8h}, [x4], #64 // filter[0..7]

        uxtl            v0.8h, v0.8b
        uxtl            v1.8h, v1.8b
        smull           v5.4s, v0.4h, v28.4h
        smull2          v6.4s, v0.8h, v28.8h
        uxtl            v2.8h, v2.8b
        smlal           v5.4s, v1.4h, v29.4h
        smlal2          v6.4s, v1.8h, v29.8h
        uxtl            v3.8h, v3.8b
        smlal           v5.4s, v2.4h, v30.4h
        smlal2          v6.4s, v2.8h, v30.8h
        smlal           v5.4s, v3.4h, v31.4h
        smlal2          v6.4s, v3.8h, v31.8h

        sshr            v5.4s, v5.4s, #3
        sshr            v6.4s, v6.4s, #3

        smin            v5.4s, v5.4s, v18.4s
        smin            v6.4s, v6.4s, v18.4s

        sub             w2, w2, #8
        st1             {v5.4s, v6.4s}, [x1], #32
        cbnz            w2, 2f

        ret

2:
        ldr             w8, [x5], #4 // load filterPos
        add             x9, x3, w8, uxtw // src + filterPos
        ld1             {v0.s}[0], [x9] // load 4 * uint8_t* into one single
        ld1             {v31.4h}, [x4], #8
        uxtl            v0.8h, v0.8b
        smull           v5.4s, v0.4h, v31.4h
        saddlv          d0, v5.4s
        sqshrn          s0, d0, #3
        smin            v0.4s, v0.4s, v18.4s
        st1             {v0.s}[0], [x1], #4
        sub             w2, w2, #1
        cbnz            w2, 2b // if iterations remain jump to beginning

        ret
endfunc

function ff_hscale8to19_X8_neon, export=1
        movi            v20.4s, #1
        movi            v17.4s, #1
        shl             v20.4s, v20.4s, #19
        sub             v20.4s, v20.4s, v17.4s

        sbfiz           x7, x6, #1, #32             // filterSize*2 (*2 because int16)
1:
        mov             x16, x4                     // filter0 = filter
        ldr             w8, [x5], #4                // filterPos[idx]
        add             x12, x16, x7                // filter1 = filter0 + filterSize*2
        ldr             w0, [x5], #4                // filterPos[idx + 1]
        add             x13, x12, x7                // filter2 = filter1 + filterSize*2
        ldr             w11, [x5], #4               // filterPos[idx + 2]
        add             x4, x13, x7                 // filter3 = filter2 + filterSize*2
        ldr             w9, [x5], #4                // filterPos[idx + 3]
        movi            v0.16b, #0                  // val sum part 1 (for dst[0])
        movi            v1.16b, #0                  // val sum part 2 (for dst[1])
        movi            v2.16b, #0                  // val sum part 3 (for dst[2])
        movi            v3.16b, #0                  // val sum part 4 (for dst[3])
        add             x17, x3, w8, uxtw           // srcp + filterPos[0]
        add             x8,  x3, w0, uxtw           // srcp + filterPos[1]
        add             x0, x3, w11, uxtw           // srcp + filterPos[2]
        add             x11, x3, w9, uxtw           // srcp + filterPos[3]
        mov             w15, w6                     // filterSize counter
2:      ld1             {v4.8b}, [x17], #8          // srcp[filterPos[0] + {0..7}]
        ld1             {v5.8h}, [x16], #16         // load 8x16-bit filter values, part 1
        uxtl            v4.8h, v4.8b                // unpack part 1 to 16-bit
        smlal           v0.4s, v4.4h, v5.4h         // v0 accumulates srcp[filterPos[0] + {0..3}] * filter[{0..3}]
        ld1             {v6.8b}, [x8], #8           // srcp[filterPos[1] + {0..7}]
        smlal2          v0.4s, v4.8h, v5.8h         // v0 accumulates srcp[filterPos[0] + {4..7}] * filter[{4..7}]
        ld1             {v7.8h}, [x12], #16         // load 8x16-bit at filter+filterSize
        ld1             {v16.8b}, [x0], #8          // srcp[filterPos[2] + {0..7}]
        uxtl            v6.8h, v6.8b                // unpack part 2 to 16-bit
        ld1             {v17.8h}, [x13], #16        // load 8x16-bit at filter+2*filterSize
        uxtl            v16.8h, v16.8b              // unpack part 3 to 16-bit
        smlal           v1.4s, v6.4h, v7.4h         // v1 accumulates srcp[filterPos[1] + {0..3}] * filter[{0..3}]
        ld1             {v18.8b}, [x11], #8         // srcp[filterPos[3] + {0..7}]
        smlal           v2.4s, v16.4h, v17.4h       // v2 accumulates srcp[filterPos[2] + {0..3}] * filter[{0..3}]
        ld1             {v19.8h}, [x4], #16         // load 8x16-bit at filter+3*filterSize
        smlal2          v2.4s, v16.8h, v17.8h       // v2 accumulates srcp[filterPos[2] + {4..7}] * filter[{4..7}]
        uxtl            v18.8h, v18.8b              // unpack part 4 to 16-bit
        smlal2          v1.4s, v6.8h, v7.8h         // v1 accumulates srcp[filterPos[1] + {4..7}] * filter[{4..7}]
        smlal           v3.4s, v18.4h, v19.4h       // v3 accumulates srcp[filterPos[3] + {0..3}] * filter[{0..3}]
        subs            w15, w15, #8                // j -= 8: processed 8/filterSize
        smlal2          v3.4s, v18.8h, v19.8h       // v3 accumulates srcp[filterPos[3] + {4..7}] * filter[{4..7}]
        b.gt            2b                          // inner loop if filterSize not consumed completely
        addp            v0.4s, v0.4s, v1.4s         // part01 horizontal pair adding
        addp            v2.4s, v2.4s, v3.4s         // part23 horizontal pair adding
        addp            v0.4s, v0.4s, v2.4s         // part0123 horizontal pair adding
        subs            w2, w2, #4                  // dstW -= 4
        sshr            v0.4s, v0.4s, #3            // shift and clip the 2x16-bit final values
        smin            v0.4s, v0.4s, v20.4s
        st1             {v0.4s}, [x1], #16           // write to destination part0123
        b.gt            1b                          // loop until end of line
        ret
endfunc

function ff_hscale8to19_X4_neon, export=1
        // x0  SwsInternal *c (not used)
        // x1  int16_t *dst
        // w2  int dstW
        // x3  const uint8_t *src
        // x4  const int16_t *filter
        // x5  const int32_t *filterPos
        // w6  int filterSize

        movi            v20.4s, #1
        movi            v17.4s, #1
        shl             v20.4s, v20.4s, #19
        sub             v20.4s, v20.4s, v17.4s

        lsl             w7, w6, #1
1:
        ldp             w8, w9, [x5]
        ldp             w10, w11, [x5, #8]

        movi            v16.16b, #0                 // initialize accumulator for idx + 0
        movi            v17.16b, #0                 // initialize accumulator for idx + 1
        movi            v18.16b, #0                 // initialize accumulator for idx + 2
        movi            v19.16b, #0                 // initialize accumulator for idx + 3

        mov             x12, x4                     // filter + 0
        add             x13, x4, x7                 // filter + 1
        add             x8, x3, w8, uxtw            // srcp + filterPos 0
        add             x14, x13, x7                // filter + 2
        add             x9, x3, w9, uxtw            // srcp + filterPos 1
        add             x15, x14, x7                // filter + 3
        add             x10, x3, w10, uxtw          // srcp + filterPos 2
        mov             w0, w6                      // save the filterSize to temporary variable
        add             x11, x3, w11, uxtw          // srcp + filterPos 3
        add             x5, x5, #16                 // advance filter position
        mov             x16, xzr                    // clear the register x16 used for offsetting the filter values

2:
        ldr             d4, [x8], #8                // load src values for idx 0
        ldr             q31, [x12, x16]             // load filter values for idx 0
        uxtl            v4.8h, v4.8b                // extend type to match the filter' size
        ldr             d5, [x9], #8                // load src values for idx 1
        smlal           v16.4s, v4.4h, v31.4h       // multiplication of lower half for idx 0
        uxtl            v5.8h, v5.8b                // extend type to match the filter' size
        ldr             q30, [x13, x16]             // load filter values for idx 1
        smlal2          v16.4s, v4.8h, v31.8h       // multiplication of upper half for idx 0
        ldr             d6, [x10], #8               // load src values for idx 2
        ldr             q29, [x14, x16]             // load filter values for idx 2
        smlal           v17.4s, v5.4h, v30.4h       // multiplication of lower half for idx 1
        ldr             d7, [x11], #8               // load src values for idx 3
        smlal2          v17.4s, v5.8h, v30.8h       // multiplication of upper half for idx 1
        uxtl            v6.8h, v6.8b                // extend tpye to matchi the filter's size
        ldr             q28, [x15, x16]             // load filter values for idx 3
        smlal           v18.4s, v6.4h, v29.4h       // multiplication of lower half for idx 2
        uxtl            v7.8h, v7.8b
        smlal2          v18.4s, v6.8h, v29.8h       // multiplication of upper half for idx 2
        sub             w0, w0, #8
        smlal           v19.4s, v7.4h, v28.4h       // multiplication of lower half for idx 3
        cmp             w0, #8
        smlal2          v19.4s, v7.8h, v28.8h       // multiplication of upper half for idx 3
        add             x16, x16, #16                // advance filter values indexing

        b.ge            2b


        // 4 iterations left

        sub             x17, x7, #8                 // step back to wrap up the filter pos for last 4 elements

        ldr             s4, [x8]                    // load src values for idx 0
        ldr             d31, [x12, x17]             // load filter values for idx 0
        uxtl            v4.8h, v4.8b                // extend type to match the filter' size
        ldr             s5, [x9]                    // load src values for idx 1
        smlal           v16.4s, v4.4h, v31.4h
        ldr             d30, [x13, x17]             // load filter values for idx 1
        uxtl            v5.8h, v5.8b                // extend type to match the filter' size
        ldr             s6, [x10]                   // load src values for idx 2
        smlal           v17.4s, v5.4h, v30.4h
        uxtl            v6.8h, v6.8b                // extend type to match the filter's size
        ldr             d29, [x14, x17]             // load filter values for idx 2
        ldr             s7, [x11]                   // load src values for idx 3
        addp            v16.4s, v16.4s, v17.4s
        uxtl            v7.8h, v7.8b
        ldr             d28, [x15, x17]             // load filter values for idx 3
        smlal           v18.4s, v6.4h, v29.4h
        smlal           v19.4s, v7.4h, v28.4h
        subs            w2, w2, #4
        addp            v18.4s, v18.4s, v19.4s
        addp            v16.4s, v16.4s, v18.4s
        sshr            v16.4s, v16.4s, #3
        smin            v16.4s, v16.4s, v20.4s

        st1             {v16.4s}, [x1], #16
        add             x4, x4, x7, lsl #2
        b.gt            1b
        ret
endfunc


.macro hscale_iter src, src2, filter, dst1, dst2
        uxtl            \src\().4s, \src\().4h
        sxtl            v19.4s, \filter\().4h
        mul             \dst1\().4s, \src\().4s, v19.4s
        uxtl            \src2\().4s, \src2\().4h
        sxtl2           \filter\().4s, \filter\().8h
        mul             \dst2\().4s, \src2\().4s, \filter\().4s
.endm

function ff_hscale16to15_4_neon_asm, export=1
        // w0               int shift
        // x1               int32_t *dst
        // w2               int dstW
        // x3               const uint8_t *src // treat it as uint16_t *src
        // x4               const uint16_t *filter
        // x5               const int32_t *filterPos
        // w6               int filterSize

        movi            v18.4s, #1
        movi            v17.4s, #1
        shl             v18.4s, v18.4s, #15
        sub             v18.4s, v18.4s, v17.4s      // max allowed value
        dup             v17.4s, w0                  // read shift
        neg             v17.4s, v17.4s              // negate it, so it can be used in sshl (effectively shift right)

        cmp             w2, #16
        b.lt            2f // move to last block

        ldp             w8, w9, [x5]                // filterPos[0], filterPos[1]
        ldp             w10, w11, [x5, #8]          // filterPos[2], filterPos[3]
        ldp             w12, w13, [x5, #16]         // filterPos[4], filterPos[5]
        ldp             w14, w15, [x5, #24]         // filterPos[6], filterPos[7]
        add             x5, x5, #32

        // shift all filterPos left by one, as uint16_t will be read
        ld1             {v28.8h, v29.8h, v30.8h, v31.8h}, [x4], #64 // filter[0..7]
        lsl             x8, x8, #1
        lsl             x9, x9, #1
        lsl             x10, x10, #1
        lsl             x11, x11, #1
        lsl             x12, x12, #1
        lsl             x13, x13, #1
        lsl             x14, x14, #1
        lsl             x15, x15, #1

        // load src with given offset
        ldr             d0, [x3, w8,  uxtw]
        ldr             d1, [x3, w9,  uxtw]
        ldr             d2, [x3, w10, uxtw]
        ldr             d3, [x3, w11, uxtw]
        ldr             d4, [x3, w12, uxtw]
        ldr             d5, [x3, w13, uxtw]
        ldr             d6, [x3, w14, uxtw]
        ldr             d7, [x3, w15, uxtw]

1:

        // load filterPositions into registers for next iteration

        hscale_iter     v0, v1, v28, v20, v21
        ldp             w8, w9, [x5]                // filterPos[0], filterPos[1]
        hscale_iter     v2, v3, v29, v22, v23
        ldp             w10, w11, [x5, #8]          // filterPos[2], filterPos[3]
        hscale_iter     v4, v5, v30, v24, v25
        ldp             w12, w13, [x5, #16]         // filterPos[4], filterPos[5]
        hscale_iter     v6, v7, v31, v26, v27
        ldp             w14, w15, [x5, #24]         // filterPos[6], filterPos[7]
        subs            w2, w2, #8
        add             x5, x5, #32

        ldp             q28, q29, [x4], #32 // filter[0..7]
        lsl             x8, x8, #1
        lsl             x9, x9, #1
        lsl             x10, x10, #1
        lsl             x11, x11, #1
        ldp             q30, q31, [x4], #32 // filter[0..7]
        lsl             x12, x12, #1
        lsl             x13, x13, #1
        lsl             x14, x14, #1
        lsl             x15, x15, #1

        addp            v20.4s, v20.4s, v21.4s
        ldr             d0, [x3, w8,  uxtw]
        addp            v22.4s, v22.4s, v23.4s
        ldr             d1, [x3, w9,  uxtw]
        addp            v24.4s, v24.4s, v25.4s
        ldr             d2, [x3, w10, uxtw]
        addp            v26.4s, v26.4s, v27.4s
        ldr             d3, [x3, w11, uxtw]
        addp            v20.4s, v20.4s, v22.4s
        ldr             d4, [x3, w12, uxtw]
        addp            v21.4s, v24.4s, v26.4s
        ldr             d5, [x3, w13, uxtw]
        cmp             w2, #16

        sshl            v20.4s, v20.4s, v17.4s
        ldr             d6, [x3, w14, uxtw]
        sshl            v21.4s, v21.4s, v17.4s
        ldr             d7, [x3, w15, uxtw]
        smin            v20.4s, v20.4s, v18.4s
        smin            v21.4s, v21.4s, v18.4s
        xtn             v20.4h, v20.4s
        xtn2            v20.8h, v21.4s

        st1             {v20.8h}, [x1], #16

        b.ge            1b

        // here we make last iteration, without updating the registers

        hscale_iter     v0, v1, v28, v20, v21
        hscale_iter     v2, v3, v29, v22, v23
        hscale_iter     v4, v5, v30, v24, v25
        hscale_iter     v6, v7, v31, v26, v27
        subs            w2, w2, #8

        addp            v20.4s, v20.4s, v21.4s
        addp            v22.4s, v22.4s, v23.4s
        addp            v24.4s, v24.4s, v25.4s
        addp            v26.4s, v26.4s, v27.4s
        addp            v0.4s, v20.4s, v22.4s
        addp            v1.4s, v24.4s, v26.4s

        sshl            v0.4s, v0.4s, v17.4s
        sshl            v1.4s, v1.4s, v17.4s
        smin            v0.4s, v0.4s, v18.4s
        smin            v1.4s, v1.4s, v18.4s
        xtn             v0.4h, v0.4s
        xtn2            v0.8h, v1.4s

        st1             {v0.8h}, [x1], #16
        cbnz            w2, 2f

        ret

2:
        ldr             w8, [x5], #4                // load filterPos
        add             x9, x3, w8, uxtw #1         // src + filterPos
        ld1             {v0.4h}, [x9]               // load 4 * uint16_t
        ld1             {v31.4h}, [x4], #8
        sub             w2, w2, #1

        uxtl            v0.4s, v0.4h
        sxtl            v31.4s, v31.4h
        mul             v5.4s, v0.4s, v31.4s
        addv            s0, v5.4s
        sshl            v0.4s, v0.4s, v17.4s
        smin            v0.4s, v0.4s, v18.4s
        st1             {v0.h}[0], [x1], #2
        cbnz            w2, 2b                      // if iterations remain jump to beginning

        ret
endfunc

function ff_hscale16to15_X8_neon_asm, export=1
        // w0               int shift
        // x1               int32_t *dst
        // w2               int dstW
        // x3               const uint8_t *src // treat it as uint16_t *src
        // x4               const uint16_t *filter
        // x5               const int32_t *filterPos
        // w6               int filterSize

        movi            v20.4s, #1
        movi            v21.4s, #1
        shl             v20.4s, v20.4s, #15
        sub             v20.4s, v20.4s, v21.4s
        dup             v21.4s, w0
        neg             v21.4s, v21.4s

        sbfiz           x7, x6, #1, #32             // filterSize*2 (*2 because int16)
1:      ldr             w8, [x5], #4                // filterPos[idx]
        lsl             w8, w8, #1
        ldr             w10, [x5], #4               // filterPos[idx + 1]
        lsl             w10, w10, #1
        ldr             w11, [x5], #4               // filterPos[idx + 2]
        lsl             w11, w11, #1
        ldr             w9, [x5], #4                // filterPos[idx + 3]
        lsl             w9, w9, #1
        mov             x16, x4                     // filter0 = filter
        add             x12, x16, x7                // filter1 = filter0 + filterSize*2
        add             x13, x12, x7                // filter2 = filter1 + filterSize*2
        add             x4, x13, x7                 // filter3 = filter2 + filterSize*2
        movi            v0.16b, #0                  // val sum part 1 (for dst[0])
        movi            v1.16b, #0                  // val sum part 2 (for dst[1])
        movi            v2.16b, #0                  // val sum part 3 (for dst[2])
        movi            v3.16b, #0                  // val sum part 4 (for dst[3])
        add             x17, x3, w8, uxtw           // srcp + filterPos[0]
        add             x8,  x3, w10, uxtw          // srcp + filterPos[1]
        add             x10, x3, w11, uxtw          // srcp + filterPos[2]
        add             x11, x3, w9, uxtw           // srcp + filterPos[3]
        mov             w15, w6                     // filterSize counter
2:      ld1             {v4.8h}, [x17], #16         // srcp[filterPos[0] + {0..7}]
        ld1             {v5.8h}, [x16], #16         // load 8x16-bit filter values, part 1
        ld1             {v6.8h}, [x8], #16          // srcp[filterPos[1] + {0..7}]
        ld1             {v7.8h}, [x12], #16         // load 8x16-bit at filter+filterSize
        uxtl            v24.4s, v4.4h               // extend srcp lower half to 32 bits to preserve sign
        sxtl            v25.4s, v5.4h               // extend filter lower half to 32 bits to match srcp size
        uxtl2           v4.4s, v4.8h                // extend srcp upper half to 32 bits
        mla             v0.4s, v24.4s, v25.4s       // multiply accumulate lower half of v4 * v5
        sxtl2           v5.4s, v5.8h                // extend filter upper half to 32 bits
        uxtl            v26.4s, v6.4h               // extend srcp lower half to 32 bits
        mla             v0.4s, v4.4s, v5.4s         // multiply accumulate upper half of v4 * v5
        sxtl            v27.4s, v7.4h               // extend filter lower half
        uxtl2           v6.4s, v6.8h                // extend srcp upper half
        sxtl2           v7.4s, v7.8h                // extend filter upper half
        ld1             {v16.8h}, [x10], #16        // srcp[filterPos[2] + {0..7}]
        mla             v1.4s, v26.4s, v27.4s       // v1 accumulates srcp[filterPos[1] + {0..3}] * filter[{0..3}]
        ld1             {v17.8h}, [x13], #16        // load 8x16-bit at filter+2*filterSize
        uxtl            v22.4s, v16.4h              // extend srcp lower half
        sxtl            v23.4s, v17.4h              // extend filter lower half
        uxtl2           v16.4s, v16.8h              // extend srcp upper half
        sxtl2           v17.4s, v17.8h              // extend filter upper half
        mla             v2.4s, v22.4s, v23.4s       // v2 accumulates srcp[filterPos[2] + {0..3}] * filter[{0..3}]
        mla             v2.4s, v16.4s, v17.4s       // v2 accumulates srcp[filterPos[2] + {4..7}] * filter[{4..7}]
        ld1             {v18.8h}, [x11], #16        // srcp[filterPos[3] + {0..7}]
        mla             v1.4s, v6.4s, v7.4s         // v1 accumulates srcp[filterPos[1] + {4..7}] * filter[{4..7}]
        ld1             {v19.8h}, [x4], #16         // load 8x16-bit at filter+3*filterSize
        subs            w15, w15, #8                // j -= 8: processed 8/filterSize
        uxtl            v28.4s, v18.4h              // extend srcp lower half
        sxtl            v29.4s, v19.4h              // extend filter lower half
        uxtl2           v18.4s, v18.8h              // extend srcp upper half
        sxtl2           v19.4s, v19.8h              // extend filter upper half
        mla             v3.4s, v28.4s, v29.4s       // v3 accumulates srcp[filterPos[3] + {0..3}] * filter[{0..3}]
        mla             v3.4s, v18.4s, v19.4s       // v3 accumulates srcp[filterPos[3] + {4..7}] * filter[{4..7}]
        b.gt            2b                          // inner loop if filterSize not consumed completely
        addp            v0.4s, v0.4s, v1.4s         // part01 horizontal pair adding
        addp            v2.4s, v2.4s, v3.4s         // part23 horizontal pair adding
        addp            v0.4s, v0.4s, v2.4s         // part0123 horizontal pair adding
        subs            w2, w2, #4                  // dstW -= 4
        sshl            v0.4s, v0.4s, v21.4s        // shift right (effectively right, as shift is negative); overflow expected
        smin            v0.4s, v0.4s, v20.4s        // apply min (do not use sqshl)
        xtn             v0.4h, v0.4s                // narrow down to 16 bits

        st1             {v0.4h}, [x1], #8           // write to destination part0123
        b.gt            1b                          // loop until end of line
        ret
endfunc

function ff_hscale16to15_X4_neon_asm, export=1
        // w0  int shift
        // x1  int16_t *dst
        // w2  int dstW
        // x3  const uint8_t *src
        // x4  const int16_t *filter
        // x5  const int32_t *filterPos
        // w6  int filterSize

        stp             d8, d9, [sp, #-0x20]!
        stp             d10, d11, [sp, #0x10]

        movi            v18.4s, #1
        movi            v17.4s, #1
        shl             v18.4s, v18.4s, #15
        sub             v21.4s, v18.4s, v17.4s      // max allowed value
        dup             v17.4s, w0                  // read shift
        neg             v20.4s, v17.4s              // negate it, so it can be used in sshl (effectively shift right)

        lsl             w7, w6, #1
1:
        ldp             w8, w9, [x5]
        ldp             w10, w11, [x5, #8]

        movi            v16.16b, #0                 // initialize accumulator for idx + 0
        movi            v17.16b, #0                 // initialize accumulator for idx + 1
        movi            v18.16b, #0                 // initialize accumulator for idx + 2
        movi            v19.16b, #0                 // initialize accumulator for idx + 3

        mov             x12, x4                     // filter + 0
        add             x13, x4, x7                 // filter + 1
        add             x8, x3, x8, lsl #1          // srcp + filterPos 0
        add             x14, x13, x7                // filter + 2
        add             x9, x3, x9, lsl #1          // srcp + filterPos 1
        add             x15, x14, x7                // filter + 3
        add             x10, x3, x10, lsl #1        // srcp + filterPos 2
        mov             w0, w6                      // save the filterSize to temporary variable
        add             x11, x3, x11, lsl #1        // srcp + filterPos 3
        add             x5, x5, #16                 // advance filter position
        mov             x16, xzr                    // clear the register x16 used for offsetting the filter values

2:
        ldr             q4, [x8], #16               // load src values for idx 0
        ldr             q5, [x9], #16               // load src values for idx 1
        uxtl            v26.4s, v4.4h
        uxtl2           v4.4s, v4.8h
        ldr             q31, [x12, x16]             // load filter values for idx 0
        ldr             q6, [x10], #16              // load src values for idx 2
        sxtl            v22.4s, v31.4h
        sxtl2           v31.4s, v31.8h
        mla             v16.4s, v26.4s, v22.4s      // multiplication of lower half for idx 0
        uxtl            v25.4s, v5.4h
        uxtl2           v5.4s, v5.8h
        ldr             q30, [x13, x16]             // load filter values for idx 1
        ldr             q7, [x11], #16              // load src values for idx 3
        mla             v16.4s, v4.4s, v31.4s       // multiplication of upper half for idx 0
        uxtl            v24.4s, v6.4h
        sxtl            v8.4s, v30.4h
        sxtl2           v30.4s, v30.8h
        mla             v17.4s, v25.4s, v8.4s       // multiplication of lower half for idx 1
        ldr             q29, [x14, x16]             // load filter values for idx 2
        uxtl2           v6.4s, v6.8h
        sxtl            v9.4s, v29.4h
        sxtl2           v29.4s, v29.8h
        mla             v17.4s, v5.4s, v30.4s       // multiplication of upper half for idx 1
        mla             v18.4s, v24.4s, v9.4s       // multiplication of lower half for idx 2
        ldr             q28, [x15, x16]             // load filter values for idx 3
        uxtl            v23.4s, v7.4h
        sxtl            v10.4s, v28.4h
        mla             v18.4s, v6.4s, v29.4s       // multiplication of upper half for idx 2
        uxtl2           v7.4s, v7.8h
        sxtl2           v28.4s, v28.8h
        mla             v19.4s, v23.4s, v10.4s      // multiplication of lower half for idx 3
        sub             w0, w0, #8
        cmp             w0, #8
        mla             v19.4s, v7.4s, v28.4s       // multiplication of upper half for idx 3

        add             x16, x16, #16               // advance filter values indexing

        b.ge            2b

        // 4 iterations left

        sub             x17, x7, #8                 // step back to wrap up the filter pos for last 4 elements

        ldr             d4, [x8]                    // load src values for idx 0
        ldr             d31, [x12, x17]             // load filter values for idx 0
        uxtl            v4.4s, v4.4h
        sxtl            v31.4s, v31.4h
        ldr             d5, [x9]                    // load src values for idx 1
        mla             v16.4s, v4.4s, v31.4s       // multiplication of upper half for idx 0
        ldr             d30, [x13, x17]             // load filter values for idx 1
        uxtl            v5.4s, v5.4h
        sxtl            v30.4s, v30.4h
        ldr             d6, [x10]                   // load src values for idx 2
        mla             v17.4s, v5.4s, v30.4s       // multiplication of upper half for idx 1
        ldr             d29, [x14, x17]             // load filter values for idx 2
        uxtl            v6.4s, v6.4h
        sxtl            v29.4s, v29.4h
        ldr             d7, [x11]                   // load src values for idx 3
        ldr             d28, [x15, x17]             // load filter values for idx 3
        mla             v18.4s, v6.4s, v29.4s       // multiplication of upper half for idx 2
        uxtl            v7.4s, v7.4h
        sxtl            v28.4s, v28.4h
        addp            v16.4s, v16.4s, v17.4s
        mla             v19.4s, v7.4s, v28.4s       // multiplication of upper half for idx 3
        subs            w2, w2, #4
        addp            v18.4s, v18.4s, v19.4s
        addp            v16.4s, v16.4s, v18.4s
        sshl            v16.4s, v16.4s, v20.4s
        smin            v16.4s, v16.4s, v21.4s
        xtn             v16.4h, v16.4s

        st1             {v16.4h}, [x1], #8
        add             x4, x4, x7, lsl #2
        b.gt            1b

        ldp             d8, d9, [sp]
        ldp             d10, d11, [sp, #0x10]

        add             sp, sp, #0x20

        ret
endfunc

        // NOTE: an E-style register tbl-transpose was tried for
        // ff_hscale16to19_4_neon_asm but measured 1.17x SLOWER than the stock
        // store-to-stack + ld4 (4-register 64-byte tbl latency beats the win),
        // so it was reverted. The 8-bit 8to19_4 keeps the tbl version (~1.38x).

function ff_hscale16to19_4_neon_asm, export=1
        // w0               int shift
        // x1               int32_t *dst
        // w2               int dstW
        // x3               const uint8_t *src // treat it as uint16_t *src
        // x4               const uint16_t *filter
        // x5               const int32_t *filterPos
        // w6               int filterSize

        movi            v18.4s, #1
        movi            v17.4s, #1
        shl             v18.4s, v18.4s, #19
        sub             v18.4s, v18.4s, v17.4s      // max allowed value
        dup             v17.4s, w0                  // read shift
        neg             v17.4s, v17.4s              // negate it, so it can be used in sshl (effectively shift right)

        cmp             w2, #16
        b.lt            2f // move to last block

        ldp             w8, w9, [x5]                // filterPos[0], filterPos[1]
        ldp             w10, w11, [x5, #8]          // filterPos[2], filterPos[3]
        ldp             w12, w13, [x5, #16]         // filterPos[4], filterPos[5]
        ldp             w14, w15, [x5, #24]         // filterPos[6], filterPos[7]
        add             x5, x5, #32

        // shift all filterPos left by one, as uint16_t will be read
        lsl             x8, x8, #1
        lsl             x9, x9, #1
        lsl             x10, x10, #1
        lsl             x11, x11, #1
        lsl             x12, x12, #1
        lsl             x13, x13, #1
        lsl             x14, x14, #1
        lsl             x15, x15, #1

        // load src with given offset
        ldr             x8,  [x3, w8,  uxtw]
        ldr             x9,  [x3, w9,  uxtw]
        ldr             x10, [x3, w10, uxtw]
        ldr             x11, [x3, w11, uxtw]
        ldr             x12, [x3, w12, uxtw]
        ldr             x13, [x3, w13, uxtw]
        ldr             x14, [x3, w14, uxtw]
        ldr             x15, [x3, w15, uxtw]

        sub             sp, sp, #64
        // push src on stack so it can be loaded into vectors later
        stp             x8, x9, [sp]
        stp             x10, x11, [sp, #16]
        stp             x12, x13, [sp, #32]
        stp             x14, x15, [sp, #48]

1:
        ld4             {v0.8h, v1.8h, v2.8h, v3.8h}, [sp]
        ld4             {v28.8h, v29.8h, v30.8h, v31.8h}, [x4], #64 // filter[0..7]

        // Each of blocks does the following:
        // Extend src and filter to 32 bits with uxtl and sxtl
        // multiply or multiply and accumulate results
        // Extending to 32 bits is necessary, as unit16_t values can't
        // be represented as int16_t without type promotion.
        uxtl            v26.4s, v0.4h
        sxtl            v27.4s, v28.4h
        uxtl2           v0.4s, v0.8h
        mul             v5.4s, v26.4s, v27.4s
        sxtl2           v28.4s, v28.8h
        uxtl            v26.4s, v1.4h
        mul             v6.4s, v0.4s, v28.4s

        sxtl            v27.4s, v29.4h
        uxtl2           v0.4s, v1.8h
        mla             v5.4s, v27.4s, v26.4s
        sxtl2           v28.4s, v29.8h
        uxtl            v26.4s, v2.4h
        mla             v6.4s, v28.4s, v0.4s

        sxtl            v27.4s, v30.4h
        uxtl2           v0.4s, v2.8h
        mla             v5.4s, v27.4s, v26.4s
        sxtl2           v28.4s, v30.8h
        uxtl            v26.4s, v3.4h
        mla             v6.4s, v28.4s, v0.4s

        sxtl            v27.4s, v31.4h
        uxtl2           v0.4s, v3.8h
        mla             v5.4s, v27.4s, v26.4s
        sxtl2           v28.4s, v31.8h
        sub             w2, w2, #8
        mla             v6.4s, v28.4s, v0.4s

        sshl            v5.4s, v5.4s, v17.4s
        sshl            v6.4s, v6.4s, v17.4s
        smin            v5.4s, v5.4s, v18.4s
        smin            v6.4s, v6.4s, v18.4s

        st1             {v5.4s, v6.4s}, [x1], #32
        cmp             w2, #16

        // load filterPositions into registers for next iteration
        ldp             w8, w9, [x5]                // filterPos[0], filterPos[1]
        ldp             w10, w11, [x5, #8]          // filterPos[2], filterPos[3]
        ldp             w12, w13, [x5, #16]         // filterPos[4], filterPos[5]
        ldp             w14, w15, [x5, #24]         // filterPos[6], filterPos[7]
        add             x5, x5, #32

        lsl             x8, x8, #1
        lsl             x9, x9, #1
        lsl             x10, x10, #1
        lsl             x11, x11, #1
        lsl             x12, x12, #1
        lsl             x13, x13, #1
        lsl             x14, x14, #1
        lsl             x15, x15, #1

        ldr             x8,  [x3, w8,  uxtw]
        ldr             x9,  [x3, w9,  uxtw]
        ldr             x10, [x3, w10, uxtw]
        ldr             x11, [x3, w11, uxtw]
        ldr             x12, [x3, w12, uxtw]
        ldr             x13, [x3, w13, uxtw]
        ldr             x14, [x3, w14, uxtw]
        ldr             x15, [x3, w15, uxtw]

        stp             x8, x9, [sp]
        stp             x10, x11, [sp, #16]
        stp             x12, x13, [sp, #32]
        stp             x14, x15, [sp, #48]

        b.ge            1b

        // here we make last iteration, without updating the registers
        ld4             {v0.8h, v1.8h, v2.8h, v3.8h}, [sp]
        ld4             {v28.8h, v29.8h, v30.8h, v31.8h}, [x4], #64

        uxtl            v26.4s, v0.4h
        sxtl            v27.4s, v28.4h
        uxtl2           v0.4s, v0.8h
        mul             v5.4s, v26.4s, v27.4s
        sxtl2           v28.4s, v28.8h
        uxtl            v26.4s, v1.4h
        mul             v6.4s, v0.4s, v28.4s

        sxtl            v27.4s, v29.4h
        uxtl2           v0.4s, v1.8h
        mla             v5.4s, v26.4s, v27.4s
        sxtl2           v28.4s, v29.8h
        uxtl            v26.4s, v2.4h
        mla             v6.4s, v0.4s, v28.4s

        sxtl            v27.4s, v30.4h
        uxtl2           v0.4s, v2.8h
        mla             v5.4s, v26.4s, v27.4s
        sxtl2           v28.4s, v30.8h
        uxtl            v26.4s, v3.4h
        mla             v6.4s, v0.4s, v28.4s

        sxtl            v27.4s, v31.4h
        uxtl2           v0.4s, v3.8h
        mla             v5.4s, v26.4s, v27.4s
        sxtl2           v28.4s, v31.8h
        subs            w2, w2, #8
        mla             v6.4s, v0.4s, v28.4s

        sshl            v5.4s, v5.4s, v17.4s
        sshl            v6.4s, v6.4s, v17.4s

        smin            v5.4s, v5.4s, v18.4s
        smin            v6.4s, v6.4s, v18.4s

        st1             {v5.4s, v6.4s}, [x1], #32
        add             sp, sp, #64                 // restore stack
        cbnz            w2, 2f

        ret

2:
        ldr             w8, [x5], #4                // load filterPos
        lsl             w8, w8, #1
        add             x9, x3, w8, uxtw            // src + filterPos
        ld1             {v0.4h}, [x9]               // load 4 * uint16_t
        ld1             {v31.4h}, [x4], #8

        uxtl            v0.4s, v0.4h
        sxtl            v31.4s, v31.4h
        subs            w2, w2, #1
        mul             v5.4s, v0.4s, v31.4s
        addv            s0, v5.4s
        sshl            v0.4s, v0.4s, v17.4s
        smin            v0.4s, v0.4s, v18.4s
        st1             {v0.s}[0], [x1], #4
        cbnz            w2, 2b                      // if iterations remain jump to beginning

        ret
endfunc

function ff_hscale16to19_X8_neon_asm, export=1
        // w0               int shift
        // x1               int32_t *dst
        // w2               int dstW
        // x3               const uint8_t *src // treat it as uint16_t *src
        // x4               const uint16_t *filter
        // x5               const int32_t *filterPos
        // w6               int filterSize

        movi            v20.4s, #1
        movi            v21.4s, #1
        shl             v20.4s, v20.4s, #19
        sub             v20.4s, v20.4s, v21.4s
        dup             v21.4s, w0
        neg             v21.4s, v21.4s

        sbfiz           x7, x6, #1, #32             // filterSize*2 (*2 because int16)
1:      ldr             w8, [x5], #4                // filterPos[idx]
        ldr             w10, [x5], #4               // filterPos[idx + 1]
        lsl             w8, w8, #1
        ldr             w11, [x5], #4               // filterPos[idx + 2]
        ldr             w9, [x5], #4                // filterPos[idx + 3]
        mov             x16, x4                     // filter0 = filter
        lsl             w11, w11, #1
        add             x12, x16, x7                // filter1 = filter0 + filterSize*2
        lsl             w9, w9, #1
        add             x13, x12, x7                // filter2 = filter1 + filterSize*2
        lsl             w10, w10, #1
        add             x4, x13, x7                 // filter3 = filter2 + filterSize*2
        movi            v0.16b, #0                  // val sum part 1 (for dst[0])
        movi            v1.16b, #0                  // val sum part 2 (for dst[1])
        movi            v2.16b, #0                  // val sum part 3 (for dst[2])
        movi            v3.16b, #0                  // val sum part 4 (for dst[3])
        add             x17, x3, w8, uxtw           // srcp + filterPos[0]
        add             x8,  x3, w10, uxtw          // srcp + filterPos[1]
        add             x10, x3, w11, uxtw          // srcp + filterPos[2]
        add             x11, x3, w9, uxtw           // srcp + filterPos[3]
        mov             w15, w6                     // filterSize counter
2:      ld1             {v4.8h}, [x17], #16         // srcp[filterPos[0] + {0..7}]
        ld1             {v5.8h}, [x16], #16         // load 8x16-bit filter values, part 1
        ld1             {v6.8h}, [x8], #16          // srcp[filterPos[1] + {0..7}]
        ld1             {v7.8h}, [x12], #16         // load 8x16-bit at filter+filterSize
        uxtl            v24.4s, v4.4h               // extend srcp lower half to 32 bits to preserve sign
        sxtl            v25.4s, v5.4h               // extend filter lower half to 32 bits to match srcp size
        uxtl2           v4.4s, v4.8h                // extend srcp upper half to 32 bits
        mla             v0.4s, v24.4s, v25.4s       // multiply accumulate lower half of v4 * v5
        sxtl2           v5.4s, v5.8h                // extend filter upper half to 32 bits
        uxtl            v26.4s, v6.4h               // extend srcp lower half to 32 bits
        mla             v0.4s, v4.4s, v5.4s         // multiply accumulate upper half of v4 * v5
        sxtl            v27.4s, v7.4h               // extend filter lower half
        uxtl2           v6.4s, v6.8h                // extend srcp upper half
        sxtl2           v7.4s, v7.8h                // extend filter upper half
        ld1             {v16.8h}, [x10], #16        // srcp[filterPos[2] + {0..7}]
        mla             v1.4s, v26.4s, v27.4s       // v1 accumulates srcp[filterPos[1] + {0..3}] * filter[{0..3}]
        ld1             {v17.8h}, [x13], #16        // load 8x16-bit at filter+2*filterSize
        uxtl            v22.4s, v16.4h              // extend srcp lower half
        sxtl            v23.4s, v17.4h              // extend filter lower half
        uxtl2           v16.4s, v16.8h              // extend srcp upper half
        sxtl2           v17.4s, v17.8h              // extend filter upper half
        mla             v2.4s, v22.4s, v23.4s       // v2 accumulates srcp[filterPos[2] + {0..3}] * filter[{0..3}]
        mla             v2.4s, v16.4s, v17.4s       // v2 accumulates srcp[filterPos[2] + {4..7}] * filter[{4..7}]
        ld1             {v18.8h}, [x11], #16        // srcp[filterPos[3] + {0..7}]
        mla             v1.4s, v6.4s, v7.4s         // v1 accumulates srcp[filterPos[1] + {4..7}] * filter[{4..7}]
        ld1             {v19.8h}, [x4], #16         // load 8x16-bit at filter+3*filterSize
        subs            w15, w15, #8                // j -= 8: processed 8/filterSize
        uxtl            v28.4s, v18.4h              // extend srcp lower half
        sxtl            v29.4s, v19.4h              // extend filter lower half
        uxtl2           v18.4s, v18.8h              // extend srcp upper half
        sxtl2           v19.4s, v19.8h              // extend filter upper half
        mla             v3.4s, v28.4s, v29.4s       // v3 accumulates srcp[filterPos[3] + {0..3}] * filter[{0..3}]
        mla             v3.4s, v18.4s, v19.4s       // v3 accumulates srcp[filterPos[3] + {4..7}] * filter[{4..7}]
        b.gt            2b                          // inner loop if filterSize not consumed completely
        addp            v0.4s, v0.4s, v1.4s         // part01 horizontal pair adding
        addp            v2.4s, v2.4s, v3.4s         // part23 horizontal pair adding
        addp            v0.4s, v0.4s, v2.4s         // part0123 horizontal pair adding
        subs            w2, w2, #4                  // dstW -= 4
        sshl            v0.4s, v0.4s, v21.4s        // shift right (effectively right, as shift is negative); overflow expected
        smin            v0.4s, v0.4s, v20.4s        // apply min (do not use sqshl)
        st1             {v0.4s}, [x1], #16          // write to destination part0123
        b.gt            1b                          // loop until end of line
        ret
endfunc

function ff_hscale16to19_X4_neon_asm, export=1
        // w0  int shift
        // x1  int16_t *dst
        // w2  int dstW
        // x3  const uint8_t *src
        // x4  const int16_t *filter
        // x5  const int32_t *filterPos
        // w6  int filterSize

        stp             d8, d9, [sp, #-0x20]!
        stp             d10, d11, [sp, #0x10]

        movi            v18.4s, #1
        movi            v17.4s, #1
        shl             v18.4s, v18.4s, #19
        sub             v21.4s, v18.4s, v17.4s      // max allowed value
        dup             v17.4s, w0                  // read shift
        neg             v20.4s, v17.4s              // negate it, so it can be used in sshl (effectively shift right)

        lsl             w7, w6, #1
1:
        ldp             w8, w9, [x5]
        ldp             w10, w11, [x5, #8]

        movi            v16.16b, #0                 // initialize accumulator for idx + 0
        movi            v17.16b, #0                 // initialize accumulator for idx + 1
        movi            v18.16b, #0                 // initialize accumulator for idx + 2
        movi            v19.16b, #0                 // initialize accumulator for idx + 3

        mov             x12, x4                     // filter + 0
        add             x13, x4, x7                 // filter + 1
        add             x8, x3, x8, lsl #1          // srcp + filterPos 0
        add             x14, x13, x7                // filter + 2
        add             x9, x3, x9, lsl #1          // srcp + filterPos 1
        add             x15, x14, x7                // filter + 3
        add             x10, x3, x10, lsl #1        // srcp + filterPos 2
        mov             w0, w6                      // save the filterSize to temporary variable
        add             x11, x3, x11, lsl #1        // srcp + filterPos 3
        add             x5, x5, #16                 // advance filter position
        mov             x16, xzr                    // clear the register x16 used for offsetting the filter values

2:
        ldr             q4, [x8], #16               // load src values for idx 0
        ldr             q5, [x9], #16               // load src values for idx 1
        uxtl            v26.4s, v4.4h
        uxtl2           v4.4s, v4.8h
        ldr             q31, [x12, x16]             // load filter values for idx 0
        ldr             q6, [x10], #16              // load src values for idx 2
        sxtl            v22.4s, v31.4h
        sxtl2           v31.4s, v31.8h
        mla             v16.4s, v26.4s, v22.4s      // multiplication of lower half for idx 0
        uxtl            v25.4s, v5.4h
        uxtl2           v5.4s, v5.8h
        ldr             q30, [x13, x16]             // load filter values for idx 1
        ldr             q7, [x11], #16              // load src values for idx 3
        mla             v16.4s, v4.4s, v31.4s       // multiplication of upper half for idx 0
        uxtl            v24.4s, v6.4h
        sxtl            v8.4s, v30.4h
        sxtl2           v30.4s, v30.8h
        mla             v17.4s, v25.4s, v8.4s       // multiplication of lower half for idx 1
        ldr             q29, [x14, x16]             // load filter values for idx 2
        uxtl2           v6.4s, v6.8h
        sxtl            v9.4s, v29.4h
        sxtl2           v29.4s, v29.8h
        mla             v17.4s, v5.4s, v30.4s       // multiplication of upper half for idx 1
        ldr             q28, [x15, x16]             // load filter values for idx 3
        mla             v18.4s, v24.4s, v9.4s       // multiplication of lower half for idx 2
        uxtl            v23.4s, v7.4h
        sxtl            v10.4s, v28.4h
        mla             v18.4s, v6.4s, v29.4s       // multiplication of upper half for idx 2
        uxtl2           v7.4s, v7.8h
        sxtl2           v28.4s, v28.8h
        mla             v19.4s, v23.4s, v10.4s      // multiplication of lower half for idx 3
        sub             w0, w0, #8
        cmp             w0, #8
        mla             v19.4s, v7.4s, v28.4s       // multiplication of upper half for idx 3

        add             x16, x16, #16               // advance filter values indexing

        b.ge            2b

        // 4 iterations left

        sub             x17, x7, #8                 // step back to wrap up the filter pos for last 4 elements

        ldr             d4, [x8]                    // load src values for idx 0
        ldr             d31, [x12, x17]             // load filter values for idx 0
        uxtl            v4.4s, v4.4h
        sxtl            v31.4s, v31.4h
        ldr             d5, [x9]                    // load src values for idx 1
        mla             v16.4s, v4.4s, v31.4s       // multiplication of upper half for idx 0
        ldr             d30, [x13, x17]             // load filter values for idx 1
        uxtl            v5.4s, v5.4h
        sxtl            v30.4s, v30.4h
        ldr             d6, [x10]                   // load src values for idx 2
        mla             v17.4s, v5.4s, v30.4s       // multiplication of upper half for idx 1
        ldr             d29, [x14, x17]             // load filter values for idx 2
        uxtl            v6.4s, v6.4h
        sxtl            v29.4s, v29.4h
        ldr             d7, [x11]                   // load src values for idx 3
        ldr             d28, [x15, x17]             // load filter values for idx 3
        mla             v18.4s, v6.4s, v29.4s       // multiplication of upper half for idx 2
        uxtl            v7.4s, v7.4h
        sxtl            v28.4s, v28.4h
        addp            v16.4s, v16.4s, v17.4s
        mla             v19.4s, v7.4s, v28.4s       // multiplication of upper half for idx 3
        subs            w2, w2, #4
        addp            v18.4s, v18.4s, v19.4s
        addp            v16.4s, v16.4s, v18.4s
        sshl            v16.4s, v16.4s, v20.4s
        smin            v16.4s, v16.4s, v21.4s

        st1             {v16.4s}, [x1], #16
        add             x4, x4, x7, lsl #2
        b.gt            1b

        ldp             d8, d9, [sp]
        ldp             d10, d11, [sp, #0x10]

        add             sp, sp, #0x20

        ret
endfunc

/* A: fs==8 fast path for ff_hscale8to15_X8_neon. The 4 filter rows for one
 * output group are contiguous when filterSize==8 (4*8*2 = 64 bytes), loaded
 * in one quad ld1 instead of 4 separate ld1. Bit-exact vs stock _X8.
 * Valid only for filterSize==8 and dstW % 4 == 0 (dispatched via wrapper). */
.text
.align 4
.global ff_hs8_15_X8_fs8
.type   ff_hs8_15_X8_fs8, %function
ff_hs8_15_X8_fs8:
1:
        ldp             w8, w0, [x5]        // filterPos[0],[1]
        ldp             w11, w9, [x5, #8]   // filterPos[2],[3]
        add             x5, x5, #16
        add             x17, x3, w8, uxtw
        add             x8,  x3, w0, uxtw
        add             x0,  x3, w11, uxtw
        add             x11, x3, w9, uxtw
        movi            v0.16b, #0
        movi            v1.16b, #0
        movi            v2.16b, #0
        movi            v3.16b, #0
        // all 4 filter rows in one quad load (fs==8 -> contiguous 64B): out0..out3 -> v20..v23
        // NOTE: use caller-saved v20-v23 (v8-v15 are callee-saved per AAPCS64 and must be preserved)
        ld1             {v20.8h, v21.8h, v22.8h, v23.8h}, [x4], #64
        ld1             {v4.8b}, [x17], #8
        ld1             {v6.8b}, [x8],  #8
        ld1             {v16.8b}, [x0], #8
        ld1             {v18.8b}, [x11], #8
        uxtl            v4.8h, v4.8b
        uxtl            v6.8h, v6.8b
        uxtl            v16.8h, v16.8b
        uxtl            v18.8h, v18.8b
        smlal           v0.4s, v4.4h,  v20.4h
        smlal2          v0.4s, v4.8h,  v20.8h
        smlal           v1.4s, v6.4h,  v21.4h
        smlal2          v1.4s, v6.8h,  v21.8h
        smlal           v2.4s, v16.4h, v22.4h
        smlal2          v2.4s, v16.8h, v22.8h
        smlal           v3.4s, v18.4h, v23.4h
        smlal2          v3.4s, v18.8h, v23.8h
        addp            v0.4s, v0.4s, v1.4s
        addp            v2.4s, v2.4s, v3.4s
        addp            v0.4s, v0.4s, v2.4s
        sqshrn          v0.4h, v0.4s, #7
        st1             {v0.4h}, [x1], #8
        sub             w2, w2, #4
        cbnz            w2, 1b
        ret
.size ff_hs8_15_X8_fs8, .-ff_hs8_15_X8_fs8

