// altddio_out -- Intel DDR output register, one ODDRE1 per bit (UltraScale+).
// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module altddio_out #(
    parameter integer width          = 1,
    parameter         power_up_high  = "OFF",
    parameter         oe_reg         = "UNREGISTERED",
    parameter         extend_oe_disable = "OFF",
    parameter         invert_output  = "OFF",
    parameter         intended_device_family = "Cyclone V",
    parameter         lpm_type       = "altddio_out",
    parameter         lpm_hint       = "UNUSED"
) (
    input  wire [width-1:0] datain_h,
    input  wire [width-1:0] datain_l,
    input  wire             outclock,
    input  wire             outclocken,
    input  wire             oe,
    input  wire             aclr,
    input  wire             aset,
    input  wire             sclr,
    input  wire             sset,
    output wire [width-1:0] dataout,
    output wire             oe_out
);
    genvar g;
    generate
        for (g = 0; g < width; g = g + 1) begin : lane
            ODDRE1 #(.IS_C_INVERTED(1'b0), .IS_D1_INVERTED(1'b0), .IS_D2_INVERTED(1'b0),
                     .SIM_DEVICE("ULTRASCALE_PLUS"), .SRVAL(1'b0))
                oddr (.Q(dataout[g]), .C(outclock), .D1(datain_h[g]), .D2(datain_l[g]), .SR(1'b0));
        end
    endgenerate
    assign oe_out = oe;
endmodule
