// ODDR -- the Series-7 output DDR cell, as a wrapper on UltraScale+'s ODDRE1.
// MiSTeX's Xilinx SDRAM controllers (cores/*/rtl/sdram.sv) instantiate ODDR,
// which does not exist on US+; this keeps those files unmodified.
// ODDRE1 has no clock enable: CE is ignored (every MiSTeX use ties it high).
// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module ODDR #(
    parameter DDR_CLK_EDGE = "OPPOSITE_EDGE",
    parameter INIT         = 1'b0,
    parameter SRTYPE       = "SYNC",
    parameter IS_C_INVERTED  = 1'b0,
    parameter IS_D1_INVERTED = 1'b0,
    parameter IS_D2_INVERTED = 1'b0
) (
    output wire Q,
    input  wire C,
    input  wire CE,
    input  wire D1,
    input  wire D2,
    input  wire R,
    input  wire S
);
    ODDRE1 #(.IS_C_INVERTED(IS_C_INVERTED), .IS_D1_INVERTED(IS_D1_INVERTED), .IS_D2_INVERTED(IS_D2_INVERTED),
             .SIM_DEVICE("ULTRASCALE_PLUS"), .SRVAL(INIT))
        u (.Q(Q), .C(C), .D1(D1), .D2(D2), .SR(R));
endmodule
