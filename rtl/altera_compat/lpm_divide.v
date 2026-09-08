// lpm_divide -- Intel LPM divider. One combinational divide followed by
// lpm_pipeline register stages (no retiming implied; see README.md).
// LPM_REMAINDERPOSITIVE is the default here: remainder takes the numerator's
// sign convention Vivado's % gives, which matches Intel for the unsigned
// denominators every MiSTer use I have read passes.
// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module lpm_divide #(
    parameter integer lpm_widthn         = 16,
    parameter integer lpm_widthd         = 16,
    parameter integer lpm_pipeline       = 0,
    parameter         lpm_nrepresentation = "UNSIGNED",
    parameter         lpm_drepresentation = "UNSIGNED",
    parameter         lpm_type           = "LPM_DIVIDE",
    parameter         lpm_hint           = "UNUSED",
    parameter         maximize_speed     = 5
) (
    input  wire [lpm_widthn-1:0] numer,
    input  wire [lpm_widthd-1:0] denom,
    input  wire                  clock,
    input  wire                  clken,
    input  wire                  aclr,
    output wire [lpm_widthn-1:0] quotient,
    output wire [lpm_widthd-1:0] remain
);
    localparam NS = (lpm_nrepresentation == "SIGNED");
    localparam DS = (lpm_drepresentation == "SIGNED");
    localparam integer WN = lpm_widthn + 1, WD = lpm_widthd + 1;
    localparam integer WW = (WN > WD) ? WN : WD;
    wire signed [WW-1:0] n = NS ? {{(WW-lpm_widthn){numer[lpm_widthn-1]}}, numer} : {{(WW-lpm_widthn){1'b0}}, numer};
    wire signed [WW-1:0] d = DS ? {{(WW-lpm_widthd){denom[lpm_widthd-1]}}, denom} : {{(WW-lpm_widthd){1'b0}}, denom};
    wire signed [WW-1:0] q = (d == 0) ? {WW{1'b1}} : n / d;
    wire signed [WW-1:0] r = (d == 0) ? n : n % d;
    wire [lpm_widthn+lpm_widthd-1:0] pair = {q[lpm_widthn-1:0], r[lpm_widthd-1:0]};
    generate
        if (lpm_pipeline == 0) begin : comb
            assign {quotient, remain} = pair;
        end else begin : pipe
            reg [lpm_widthn+lpm_widthd-1:0] st [0:lpm_pipeline-1];
            integer k;
            always @(posedge clock) begin
                st[0] <= pair;
                for (k = 1; k < lpm_pipeline; k = k + 1) st[k] <= st[k-1];
            end
            assign {quotient, remain} = st[lpm_pipeline-1];
        end
    endgenerate
endmodule
