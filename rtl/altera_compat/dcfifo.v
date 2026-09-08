// dcfifo -- Intel dual-clock FIFO as a Gray-pointer asynchronous FIFO.
// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module dcfifo #(
    parameter integer lpm_width     = 8,
    parameter integer lpm_numwords  = 32,
    parameter integer lpm_widthu    = 5,
    parameter integer lpm_width_r   = lpm_width,
    parameter integer lpm_widthu_r  = lpm_widthu,
    parameter         lpm_showahead = "OFF",
    parameter         lpm_type      = "dcfifo",
    parameter         lpm_hint      = "UNUSED",
    parameter         overflow_checking  = "ON",
    parameter         underflow_checking = "ON",
    parameter         use_eab       = "ON",
    parameter integer rdsync_delaypipe = 2,
    parameter integer wrsync_delaypipe = 2,
    parameter         add_ram_output_register = "OFF",
    parameter         intended_device_family = "Cyclone V",
    parameter         read_aclr_synch  = "OFF",
    parameter         write_aclr_synch = "OFF",
    parameter         clocks_are_synchronized = "FALSE",
    parameter         add_usedw_msb_bit = "OFF"
) (
    input  wire                  wrclk,
    input  wire                  rdclk,
    input  wire [lpm_width-1:0]  data,
    input  wire                  wrreq,
    input  wire                  rdreq,
    input  wire                  aclr,
    output reg  [lpm_width-1:0]  q,
    output wire                  rdempty,
    output wire                  wrfull,
    output wire                  rdfull,
    output wire                  wrempty,
    output wire [lpm_widthu-1:0] rdusedw,
    output wire [lpm_widthu-1:0] wrusedw
);
    localparam integer AW = lpm_widthu;
    reg [lpm_width-1:0] mem [0:lpm_numwords-1];
    reg [AW:0] wbin = 0, rbin = 0;
    wire [AW:0] wgray = wbin ^ (wbin >> 1);
    wire [AW:0] rgray = rbin ^ (rbin >> 1);
    reg  [AW:0] rgray_w1 = 0, rgray_w2 = 0, wgray_r1 = 0, wgray_r2 = 0;
    always @(posedge wrclk) begin rgray_w1 <= rgray; rgray_w2 <= rgray_w1; end
    always @(posedge rdclk) begin wgray_r1 <= wgray; wgray_r2 <= wgray_r1; end
    function [AW:0] g2b(input [AW:0] g); integer k; begin g2b[AW] = g[AW]; for (k = AW-1; k >= 0; k = k - 1) g2b[k] = g2b[k+1] ^ g[k]; end endfunction
    wire [AW:0] rbin_w = g2b(rgray_w2);
    wire [AW:0] wbin_r = g2b(wgray_r2);
    wire [AW:0] wcnt = wbin - rbin_w;
    wire [AW:0] rcnt = wbin_r - rbin;
    assign wrfull  = (wcnt == lpm_numwords);
    assign wrempty = (wcnt == 0);
    assign rdempty = (rcnt == 0);
    assign rdfull  = (rcnt == lpm_numwords);
    assign wrusedw = wcnt[AW-1:0];
    assign rdusedw = rcnt[AW-1:0];
    wire do_wr = wrreq && (!wrfull || overflow_checking == "OFF");
    wire do_rd = rdreq && (!rdempty || underflow_checking == "OFF");
    always @(posedge wrclk or posedge aclr)
        if (aclr) wbin <= 0;
        else if (do_wr) begin mem[wbin[AW-1:0]] <= data; wbin <= wbin + 1'b1; end
    always @(posedge rdclk or posedge aclr)
        if (aclr) rbin <= 0;
        else if (do_rd) rbin <= rbin + 1'b1;
    generate
        if (lpm_showahead == "ON") begin : ahead
            always @(*) q = mem[rbin[AW-1:0]];
        end else begin : normal
            always @(posedge rdclk) if (do_rd) q <= mem[rbin[AW-1:0]];
        end
    endgenerate
endmodule
