// altdpram -- Intel's simple dual-port RAM, used by the Peip cores in its MLAB
// form (registered write, asynchronous read): maps to LUT RAM here.
// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module altdpram #(
    parameter integer width          = 8,
    parameter integer widthad        = 8,
    parameter integer numwords       = (1 << widthad),
    parameter integer width_byteena  = 1,
    parameter         indata_reg     = "INCLOCK",
    parameter         outdata_reg    = "UNREGISTERED",
    parameter         rdaddress_reg  = "UNREGISTERED",
    parameter         rdcontrol_reg  = "UNREGISTERED",
    parameter         wraddress_reg  = "INCLOCK",
    parameter         wrcontrol_reg  = "INCLOCK",
    parameter         indata_aclr    = "OFF",
    parameter         outdata_aclr   = "OFF",
    parameter         rdaddress_aclr = "OFF",
    parameter         rdcontrol_aclr = "OFF",
    parameter         wraddress_aclr = "OFF",
    parameter         wrcontrol_aclr = "OFF",
    parameter         ram_block_type = "MLAB",
    parameter         read_during_write_mode_mixed_ports = "CONSTRAINED_DONT_CARE",
    parameter         intended_device_family = "Cyclone V",
    parameter         lpm_type       = "altdpram",
    parameter         lpm_hint       = "UNUSED",
    parameter         use_eab        = "OFF",
    parameter         power_up_uninitialized = "FALSE",   // accepted, ignored (Saturn's SH7604_mem.sv)
    parameter integer byte_size      = 8
) (
    input  wire [width-1:0]         data,
    input  wire [widthad-1:0]       wraddress,
    input  wire [widthad-1:0]       rdaddress,
    input  wire                     wren,
    input  wire                     rden,
    input  wire                     inclock,
    input  wire                     outclock,
    input  wire                     inclocken,
    input  wire                     outclocken,
    input  wire [width_byteena-1:0] byteena,
    input  wire                     aclr,
    input  wire                     rdaddressstall,   // Saturn's mlab wrappers connect these; a stall
    input  wire                     wraddressstall,   // is never asserted in any core here, so ignored
    input  wire                     sclr,             // synchronous clear of the output register: unused here
    output wire [width-1:0]         q
);
    localparam integer BE = width / width_byteena;
    // Intel's VHDL component declares numwords with a default of 0 meaning
    // "2**widthad"; that 0 overrides the parameter default above when the
    // model is bound from VHDL, and a [0:-1] array drops every write (found
    // in simulation: the PSX CPU's register file read X for every register).
    localparam integer NW = (numwords > 0) ? numwords : (1 << widthad);
    (* ram_style = "distributed" *) reg [width-1:0] mem [0:NW-1];
    integer l;
    always @(posedge inclock)
        if (wren)
            for (l = 0; l < width_byteena; l = l + 1)
                if (byteena[l]) mem[wraddress][l*BE +: BE] <= data[l*BE +: BE];
    wire [width-1:0] rd = mem[rdaddress];
    reg  [width-1:0] rd_q = {width{1'b0}};
    always @(posedge outclock) rd_q <= rd;
    assign q = (outdata_reg == "UNREGISTERED") ? rd : rd_q;
endmodule
