// pll_cfg / pll_cfg_small -- the Altera PLL-reconfig megafunction front-ends the
// PSX and N64 cores drive to switch pixel/core clocks at runtime (PAL/NTSC, turbo).
// Static stubs: the write is accepted and dropped, the PLL keeps its build-time
// rates. Runtime retuning needs an MMCME4 DRP sequencer (see the PLL shims).
// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module pll_cfg #(
    parameter ENABLE_BYTEENABLE = 0, parameter BYTEENABLE_WIDTH = 4,
    parameter RECONFIG_ADDR_WIDTH = 6, parameter RECONFIG_DATA_WIDTH = 32,
    parameter reconf_width = 64, parameter WAIT_FOR_LOCK = 1
) (
    input  wire        mgmt_clk,
    input  wire        mgmt_reset,
    output wire        mgmt_waitrequest,
    input  wire        mgmt_read,
    input  wire        mgmt_write,
    output wire [31:0] mgmt_readdata,
    input  wire [5:0]  mgmt_address,
    input  wire [31:0] mgmt_writedata,
    output wire [63:0] reconfig_to_pll,
    input  wire [63:0] reconfig_from_pll
);
    assign mgmt_waitrequest = 1'b0;
    assign mgmt_readdata    = 32'd0;
    assign reconfig_to_pll  = 64'd0;
endmodule

module pll_cfg_small #(
    parameter ENABLE_BYTEENABLE = 0, parameter BYTEENABLE_WIDTH = 4,
    parameter RECONFIG_ADDR_WIDTH = 6, parameter RECONFIG_DATA_WIDTH = 32,
    parameter reconf_width = 64, parameter WAIT_FOR_LOCK = 1
) (
    input  wire        mgmt_clk,
    input  wire        mgmt_reset,
    output wire        mgmt_waitrequest,
    input  wire        mgmt_write,
    input  wire [5:0]  mgmt_address,
    input  wire [31:0] mgmt_writedata,
    output wire [63:0] reconfig_to_pll,
    input  wire [63:0] reconfig_from_pll
);
    assign mgmt_waitrequest = 1'b0;
    assign reconfig_to_pll  = 64'd0;
endmodule
