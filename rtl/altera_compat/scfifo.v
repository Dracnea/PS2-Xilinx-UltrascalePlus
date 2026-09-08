// scfifo -- Intel single-clock FIFO, normal or show-ahead.
// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module scfifo #(
    parameter integer lpm_width     = 8,
    parameter integer lpm_numwords  = 32,
    parameter integer lpm_widthu    = 5,
    parameter         lpm_showahead = "OFF",
    parameter         lpm_type      = "scfifo",
    parameter         lpm_hint      = "UNUSED",
    parameter         add_ram_output_register = "OFF",
    parameter         overflow_checking  = "ON",
    parameter         underflow_checking = "ON",
    parameter         use_eab       = "ON",
    parameter         allow_rwcycle_when_full = "OFF",
    parameter         intended_device_family = "Cyclone V",
    parameter integer almost_full_value  = 0,
    parameter integer almost_empty_value = 0
) (
    input  wire                  clock,
    input  wire [lpm_width-1:0]  data,
    input  wire                  wrreq,
    input  wire                  rdreq,
    input  wire                  sclr,
    input  wire                  aclr,
    output reg  [lpm_width-1:0]  q,
    output wire                  empty,
    output wire                  full,
    output wire                  almost_full,
    output wire                  almost_empty,
    output wire [lpm_widthu-1:0] usedw,
    output wire [1:0]            eccstatus   // no ECC here; Saturn's wrappers connect it
);
    assign eccstatus = 2'b00;
    reg [lpm_width-1:0] mem [0:lpm_numwords-1];
    reg [lpm_widthu:0] wp = 0, rp = 0;          // one extra bit: full/empty distinction
    wire [lpm_widthu:0] cnt = wp - rp;
    assign empty = (cnt == 0);
    assign full  = (cnt == lpm_numwords);
    assign usedw = cnt[lpm_widthu-1:0];
    assign almost_full  = (cnt >= almost_full_value);
    assign almost_empty = (cnt <= almost_empty_value);
    wire do_wr = wrreq && (!full || overflow_checking == "OFF");
    wire do_rd = rdreq && (!empty || underflow_checking == "OFF");
    // The pointers take the asynchronous clear; the storage must not, or Vivado
    // refuses to infer a RAM ("sensitive to asynchronous reset") and dissolves it
    // into registers -- a 128 Kbit CD-audio FIFO failed synthesis that way. A
    // write during clear is harmless: the pointers restart at zero anyway.
    always @(posedge clock) begin
        if (do_wr && !aclr && !sclr) mem[wp[lpm_widthu-1:0]] <= data;
    end
    always @(posedge clock or posedge aclr) begin
        if (aclr) begin wp <= 0; rp <= 0; end
        else if (sclr) begin wp <= 0; rp <= 0; end
        else begin
            if (do_wr) wp <= wp + 1'b1;
            if (do_rd) rp <= rp + 1'b1;
        end
    end
    generate
        if (lpm_showahead == "ON") begin : ahead
            always @(*) q = mem[rp[lpm_widthu-1:0]];
        end else begin : normal
            always @(posedge clock) if (do_rd) q <= mem[rp[lpm_widthu-1:0]];
        end
    endgenerate
endmodule
