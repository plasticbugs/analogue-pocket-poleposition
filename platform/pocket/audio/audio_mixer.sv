//------------------------------------------------------------------------------
// SPDX-License-Identifier: MIT
// SPDX-FileType: SOURCE
// SPDX-FileCopyrightText: (c) 2023, OpenGateware authors and contributors
//------------------------------------------------------------------------------
//
// Analogue Pocket Audio Mixer
//
// Copyright (c) 2023, Marcus Andrade <marcus@opengateware.org>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
//------------------------------------------------------------------------------

`default_nettype none

module audio_mixer
    #(
         parameter DW     = 16,
         parameter STEREO =  1
     ) (
         // Clocks and Reset
         input  logic          clk_74b,    //! Clock 74.25Mhz
         input  logic          reset,      //! Reset
         // Controls
         input  logic    [3:0] afilter_sw, //! Predefined Audio Filter Switch
         input  logic    [3:0] vol_att,    //! Volume ([0] Max | [7] Min)
         input  logic    [1:0] mix,        //! [0] No Mix | [1] 25% | [2] 50% | [3] 100% (mono)
         input  logic          pause_core, //! Mute Audio
         // Audio From Core
         input  logic          is_signed,  //! Signed Audio
         input  logic [DW-1:0] core_l,     //! Left  Channel Audio from Core
         input  logic [DW-1:0] core_r,     //! Right Channel Audio from Core
         // Pocket I2S
         output logic          audio_mclk, //! Serial Master Clock
         output logic          audio_lrck, //! Left/Right clock
         output logic          audio_dac   //! Serialized data
     );

    //! ------------------------------------------------------------------------
    //! Audio Clocks
    //! MCLK: 12.288MHz (256*Fs, where Fs = 48000)
    //! SCLK:  3.072mhz (MCLK/4)
    //! ------------------------------------------------------------------------
    wire audio_sclk;

    mf_audio_pll audio_pll
                 (
                     .refclk   ( clk_74b    ),
                     .rst      ( 0          ),
                     .outclk_0 ( audio_mclk ),
                     .outclk_1 ( audio_sclk )
                 );

    //! ------------------------------------------------------------------------
    //! Pad core_l/core_r with zeros to maintain a consistent size of 16 bits
    //! ------------------------------------------------------------------------
    logic [15:0] core_al, core_ar;

    always_comb begin
        core_al =          DW == 16 ? core_l : {core_l, {16-DW{1'b0}}};
        core_ar = STEREO ? DW == 16 ? core_r : {core_r, {16-DW{1'b0}}} : core_al;
    end

    //! ------------------------------------------------------------------------
    //! Low Pass Filter
    //! Pole Position: the preset table is live, so afilter_sw picks the filter
    //! (0 = the framework's default ~18 kHz anti-imaging low-pass). The core
    //! drives it from the Cabinet Reverb level to add the speaker box's
    //! high-frequency loss. afilter_sw arrives from another clock domain and
    //! changes only from the menu, so two flops bring it across; a select that
    //! passes through an intermediate value for a clock is still a stable
    //! preset.
    //! ------------------------------------------------------------------------
    logic [3:0] afilter_s1 = 4'd0, afilter_s2 = 4'd0;
    always_ff @(posedge audio_mclk) begin
        afilter_s1 <= afilter_sw;
        afilter_s2 <= afilter_s1;
    end

    logic [31:0] aflt_rate;
    logic [39:0] acx;
    logic  [7:0] acx0, acx1, acx2;
    logic [23:0] acy0, acy1, acy2;

    arcade_filters arcade_filters
                   (
                       .clk        ( audio_mclk ),
                       .afilter_sw ( afilter_s2 ),
                       .flt_rate   ( aflt_rate  ),
                       .cx         ( acx        ),
                       .cx0        ( acx0       ),
                       .cx1        ( acx1       ),
                       .cx2        ( acx2       ),
                       .cy0        ( acy0       ),
                       .cy1        ( acy1       ),
                       .cy2        ( acy2       )
                   );

    //! ------------------------------------------------------------------------
    //! Audio Filters
    //! ------------------------------------------------------------------------
    logic [15:0] audio_l, audio_r;

    audio_filters audio_filters
                  (
                      .clk       ( audio_mclk ),
                      .reset     ( reset      ),
                      // Controls
                      .att       ( {pause_core, vol_att} ),
                      .mix       ( mix        ),
                      // Audio Filter
                      .flt_rate  ( aflt_rate  ),
                      .cx        ( acx        ),
                      .cx0       ( acx0       ),
                      .cx1       ( acx1       ),
                      .cx2       ( acx2       ),
                      .cy0       ( acy0       ),
                      .cy1       ( acy1       ),
                      .cy2       ( acy2       ),
                      // Audio from Core
                      .is_signed ( is_signed  ),
                      .core_l    ( core_al    ),
                      .core_r    ( core_ar    ),
                      // Filtered Audio Output
                      .audio_l   ( audio_l    ),
                      .audio_r   ( audio_r    )
                  );

    //! ------------------------------------------------------------------------
    //! Pocket I2S Output
    //! ------------------------------------------------------------------------
    pocket_i2s pocket_i2s
               (
                   // Serial Clock
                   .audio_sclk ( audio_sclk ), // [i]
                   // Audio Input
                   .audio_l    ( audio_l    ), // [i]
                   .audio_r    ( audio_r    ), // [i]
                   // Pocket I2S Interface
                   .audio_dac  ( audio_dac  ), // [o]
                   .audio_lrck ( audio_lrck )  // [o]
               );

endmodule
