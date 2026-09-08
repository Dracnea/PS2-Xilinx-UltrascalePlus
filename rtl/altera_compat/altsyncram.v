// altsyncram -- Vivado stand-in for Intel's synchronous RAM megafunction.
// Interface per the Intel documentation; behaviour is read-first on each port
// (Intel NEW_DATA_NO_NBE_READ returns the new data -- see README.md).
// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module altsyncram #(
    parameter integer width_a               = 8,
    parameter integer widthad_a             = 8,
    parameter integer numwords_a            = (1 << widthad_a),
    parameter integer width_b               = width_a,
    parameter integer widthad_b             = widthad_a,
    parameter integer numwords_b            = (1 << widthad_b),
    parameter integer width_byteena_a       = 1,
    parameter integer width_byteena_b       = 1,
    parameter         operation_mode        = "BIDIR_DUAL_PORT",
    parameter         outdata_reg_a         = "UNREGISTERED",
    parameter         outdata_reg_b         = "UNREGISTERED",
    parameter         address_reg_b         = "CLOCK1",
    parameter         indata_reg_b          = "CLOCK1",
    parameter         wrcontrol_wraddress_reg_b = "CLOCK1",
    parameter         rdcontrol_reg_b       = "CLOCK1",
    parameter         byteena_reg_b         = "CLOCK1",
    parameter         clock_enable_input_a  = "NORMAL",
    parameter         clock_enable_input_b  = "NORMAL",
    parameter         clock_enable_output_a = "BYPASS",
    parameter         clock_enable_output_b = "BYPASS",
    parameter         clock_enable_core_a   = "USE_INPUT_CLKEN",
    parameter         clock_enable_core_b   = "USE_INPUT_CLKEN",
    parameter         outdata_aclr_a        = "NONE",
    parameter         outdata_aclr_b        = "NONE",
    parameter         indata_aclr_a         = "NONE",
    parameter         address_aclr_a        = "NONE",
    parameter         address_aclr_b        = "NONE",
    parameter         wrcontrol_aclr_a      = "NONE",
    parameter         byteena_aclr_a        = "NONE",
    parameter         byteena_aclr_b        = "NONE",
    parameter         read_during_write_mode_port_a      = "NEW_DATA_NO_NBE_READ",
    parameter         read_during_write_mode_port_b      = "NEW_DATA_NO_NBE_READ",
    parameter         read_during_write_mode_mixed_ports = "DONT_CARE",
    parameter         power_up_uninitialized = "FALSE",
    parameter         init_file             = "UNUSED",
    parameter         init_file_layout      = "PORT_A",
    parameter         ram_block_type        = "AUTO",
    parameter         intended_device_family = "Cyclone V",
    parameter         lpm_type              = "altsyncram",
    parameter         lpm_hint              = "UNUSED",
    parameter integer maximum_depth         = 0,
    parameter integer byte_size             = 8,
    parameter         enable_ecc            = "FALSE",
    parameter         implement_in_les      = "OFF",
    parameter         ecc_pipeline_stage_enabled = "FALSE"
) (
    input  wire [widthad_a-1:0]        address_a,
    input  wire [widthad_b-1:0]        address_b,
    input  wire [width_a-1:0]          data_a,
    input  wire [width_b-1:0]          data_b,
    input  wire                        wren_a,
    input  wire                        wren_b,
    input  wire                        rden_a,
    input  wire                        rden_b,
    input  wire                        clock0,
    input  wire                        clock1,
    input  wire                        clocken0,
    input  wire                        clocken1,
    input  wire                        clocken2,
    input  wire                        clocken3,
    input  wire [width_byteena_a-1:0]  byteena_a,
    input  wire [width_byteena_b-1:0]  byteena_b,
    input  wire                        aclr0,
    input  wire                        aclr1,
    input  wire                        addressstall_a,
    input  wire                        addressstall_b,
    output wire [width_a-1:0]          q_a,
    output wire [width_b-1:0]          q_b,
    output wire [2:0]                  eccstatus
);
    // The narrowest port defines the storage word; a wider port touches RA / RB
    // consecutive words per access, which is how Intel lays out mixed widths.
    localparam integer W     = (width_a < width_b) ? width_a : width_b;
    localparam integer RA    = width_a / W;
    localparam integer RB    = width_b / W;
    // numwords_* of 0 means 2**widthad_* (Intel's VHDL component default; it
    // overrides the parameter defaults above when bound from VHDL -- see altdpram.v)
    localparam integer NWA   = (numwords_a > 0) ? numwords_a : (1 << widthad_a);
    localparam integer NWB   = (numwords_b > 0) ? numwords_b : (1 << widthad_b);
    localparam integer DEPTH = (NWA * RA > NWB * RB) ? NWA * RA : NWB * RB;
    localparam integer BEA   = width_a / width_byteena_a;   // data bits per byte-enable lane
    localparam integer BEB   = width_b / width_byteena_b;
    localparam         BIDIR = (operation_mode == "BIDIR_DUAL_PORT");
    // (a byte-enable lane is never wider than the storage word in any MiSTer use)


    wire clk_b  = (address_reg_b == "CLOCK1") ? clock1   : clock0;
    wire en_b   = (address_reg_b == "CLOCK1") ? clocken1 : clocken0;
    wire clk_bq = (outdata_reg_b == "CLOCK1") ? clock1   : clock0;

    reg [width_a-1:0] ra = {width_a{1'b0}};
    reg [width_b-1:0] rb = {width_b{1'b0}};
    integer i, l;

    // Two shapes Vivado recognises as block RAM (UG901 templates), chosen at
    // elaboration: equal port widths with byte-enable lanes, or asymmetric
    // widths where the wide port moves RA/RB storage words per access (whole
    // words only -- the asymmetric instances in MiSTer cores have one lane).
    // Writes are never per bit: a per-bit loop turns the array into registers.
    generate
        if (RA == 1 && RB == 1) begin : sym
            reg [W-1:0] mem [0:DEPTH-1];
            always @(posedge clock0) begin
                if (clocken0) begin
                    for (l = 0; l < width_byteena_a; l = l + 1)
                        if (wren_a && byteena_a[l]) mem[address_a][l*BEA +: BEA] <= data_a[l*BEA +: BEA];
                    if (rden_a) ra <= mem[address_a];
                end
            end
            always @(posedge clk_b) begin
                if (en_b) begin
                    for (l = 0; l < width_byteena_b; l = l + 1)
                        if (BIDIR && wren_b && byteena_b[l]) mem[address_b][l*BEB +: BEB] <= data_b[l*BEB +: BEB];
                    if (rden_b) rb <= mem[address_b];
                end
            end
        end else begin : asym
            // Asymmetric ports as R interleaved symmetric banks (UG901's other
            // template, and the one Vivado 2026.1 accepts): the wide port hits every
            // bank at one row, the narrow port picks bank = low address bits. Whole
            // words only; the narrow read is muxed by a registered bank select.
            localparam integer R    = (RA > RB) ? RA : RB;
            localparam integer LR   = (R > 1) ? $clog2(R) : 1;
            localparam integer ROWS = DEPTH / R;
            localparam         WIDE_A = (RA > RB);
            wire            wclk  = WIDE_A ? clock0   : clk_b;
            wire            wen   = WIDE_A ? clocken0 : en_b;
            wire            wwr   = WIDE_A ? (wren_a & byteena_a[0]) : (BIDIR & wren_b & byteena_b[0]);
            wire            wrd   = WIDE_A ? rden_a   : rden_b;
            wire [31:0]     waddr = WIDE_A ? address_a : address_b;
            wire [R*W-1:0]  wdata = WIDE_A ? data_a   : data_b;
            wire            nclk  = WIDE_A ? clk_b    : clock0;
            wire            nen   = WIDE_A ? en_b     : clocken0;
            wire            nwr   = WIDE_A ? (BIDIR & wren_b & byteena_b[0]) : (wren_a & byteena_a[0]);
            wire            nrd   = WIDE_A ? rden_b   : rden_a;
            wire [31:0]     naddr = WIDE_A ? address_b : address_a;
            wire [W-1:0]    ndata = WIDE_A ? data_b   : data_a;
            wire [LR-1:0]   nsel  = naddr[LR-1:0];
            wire [31:0]     nrow  = naddr >> LR;
            reg  [LR-1:0]   nsel_q = {LR{1'b0}};
            wire [R*W-1:0]  wq;
            wire [W-1:0]    nq [0:R-1];
            genvar k;
            for (k = 0; k < R; k = k + 1) begin : bank
                reg [W-1:0] m [0:ROWS-1];
                reg [W-1:0] qw = {W{1'b0}}, qn = {W{1'b0}};
                always @(posedge wclk) if (wen) begin
                    if (wwr) m[waddr] <= wdata[k*W +: W];
                    if (wrd) qw <= m[waddr];
                end
                always @(posedge nclk) if (nen) begin
                    if (nwr && nsel == k) m[nrow] <= ndata;
                    if (nrd) qn <= m[nrow];
                end
                assign wq[k*W +: W] = qw;
                assign nq[k] = qn;
            end
            always @(posedge nclk) if (nen && nrd) nsel_q <= nsel;
            always @(*) begin
                ra = WIDE_A ? wq : nq[nsel_q];
                rb = WIDE_A ? nq[nsel_q] : wq;
            end
        end
    endgenerate

    reg [width_a-1:0] ra_q = {width_a{1'b0}};
    reg [width_b-1:0] rb_q = {width_b{1'b0}};
    always @(posedge clock0) ra_q <= ra;
    always @(posedge clk_bq) rb_q <= rb;
    assign q_a = (outdata_reg_a == "UNREGISTERED") ? ra : ra_q;
    assign q_b = (outdata_reg_b == "UNREGISTERED") ? rb : rb_q;
    assign eccstatus = 3'b000;
endmodule
