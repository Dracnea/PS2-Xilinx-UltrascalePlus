// lpm_mult -- Intel LPM multiplier: signed/unsigned per lpm_representation,
// lpm_pipeline output register stages.
// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module lpm_mult #(
    parameter integer lpm_widtha         = 16,
    parameter integer lpm_widthb         = 16,
    parameter integer lpm_widthp         = 32,
    parameter integer lpm_widths         = 1,
    parameter integer lpm_pipeline       = 0,
    parameter         lpm_representation = "UNSIGNED",
    parameter         lpm_type           = "LPM_MULT",
    parameter         lpm_hint           = "UNUSED",
    parameter         dsp_block_balancing = "AUTO",
    parameter         maximize_speed     = 5
) (
    input  wire [lpm_widtha-1:0] dataa,
    input  wire [lpm_widthb-1:0] datab,
    input  wire [lpm_widths-1:0] sum,
    input  wire                  clock,
    input  wire                  clken,
    input  wire                  aclr,
    output wire [lpm_widthp-1:0] result
);
    localparam SIGNED = (lpm_representation == "SIGNED");
    wire signed [lpm_widtha:0] sa = SIGNED ? {dataa[lpm_widtha-1], dataa} : {1'b0, dataa};
    wire signed [lpm_widthb:0] sb = SIGNED ? {datab[lpm_widthb-1], datab} : {1'b0, datab};
    wire signed [lpm_widtha+lpm_widthb+1:0] prod = sa * sb;
    wire [lpm_widthp-1:0] p = prod[lpm_widthp-1:0];
    generate
        if (lpm_pipeline == 0) begin : comb
            assign result = p;
        end else begin : pipe
            reg [lpm_widthp-1:0] st [0:lpm_pipeline-1];
            integer k;
            always @(posedge clock) begin
                st[0] <= p;
                for (k = 1; k < lpm_pipeline; k = k + 1) st[k] <= st[k-1];
            end
            assign result = st[lpm_pipeline-1];
        end
    endgenerate
endmodule
