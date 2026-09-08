// altshift_taps -- Intel RAM-based shift register; one tap, tap_distance deep.
// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module altshift_taps #(
    parameter integer number_of_taps = 1,
    parameter integer tap_distance   = 4,
    parameter integer width          = 8,
    parameter         lpm_type       = "altshift_taps",
    parameter         lpm_hint       = "UNUSED",
    parameter         intended_device_family = "Cyclone V",
    parameter         power_up_state = "CLEARED"
) (
    input  wire             clock,
    input  wire             clken,
    input  wire             aclr,
    input  wire [width-1:0] shiftin,
    output wire [width-1:0] shiftout,
    output wire [width*number_of_taps-1:0] taps
);
    reg [width-1:0] sr [0:tap_distance-1];
    integer k;
    always @(posedge clock)
        if (clken) begin
            sr[0] <= shiftin;
            for (k = 1; k < tap_distance; k = k + 1) sr[k] <= sr[k-1];
        end
    assign shiftout = sr[tap_distance-1];
    assign taps = {number_of_taps{sr[tap_distance-1]}};
endmodule
