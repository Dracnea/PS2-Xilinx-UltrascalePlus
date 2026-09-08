// altera_mult_add -- the single-multiplier case with dynamic sign inputs and an
// optional output register, which is all the N64 core's cpu_mul.vhd uses.
// SPDX-License-Identifier: BSD-2-Clause
`timescale 1ns/1ps
module altera_mult_add #(
    parameter integer number_of_multipliers = 1,
    parameter integer width_a       = 64,
    parameter integer width_b       = 64,
    parameter integer width_result  = 128,
    parameter         output_register = "CLOCK0",
    parameter         output_aclr   = "NONE",
    parameter         output_sclr   = "NONE",
    parameter         multiplier1_direction = "ADD",
    parameter         port_addnsub1 = "PORT_UNUSED",
    parameter         addnsub_multiplier_register1 = "UNREGISTERED",
    parameter         addnsub_multiplier_aclr1 = "NONE",
    parameter         addnsub_multiplier_sclr1 = "NONE",
    parameter         input_register_a0 = "UNREGISTERED",
    parameter         input_register_b0 = "UNREGISTERED",
    parameter         input_aclr_a0 = "NONE",
    parameter         input_aclr_b0 = "NONE",
    parameter         input_sclr_a0 = "NONE",
    parameter         input_sclr_b0 = "NONE",
    parameter         input_source_a0 = "DATAA",
    parameter         input_source_b0 = "DATAB",
    parameter         multiplier_register0 = "UNREGISTERED",
    parameter         multiplier_aclr0 = "NONE",
    parameter         multiplier_sclr0 = "NONE",
    parameter         port_signa = "PORT_USED",
    parameter         port_signb = "PORT_USED",
    parameter         representation_a = "UNSIGNED",
    parameter         representation_b = "UNSIGNED",
    parameter         signed_register_a = "UNREGISTERED",
    parameter         signed_register_b = "UNREGISTERED",
    parameter         signed_aclr_a = "NONE",
    parameter         signed_aclr_b = "NONE",
    parameter         signed_sclr_a = "NONE",
    parameter         signed_sclr_b = "NONE",
    parameter         signed_pipeline_register_a = "UNREGISTERED",
    parameter         signed_pipeline_register_b = "UNREGISTERED",
    parameter         signed_pipeline_aclr_a = "NONE",
    parameter         signed_pipeline_aclr_b = "NONE",
    parameter         signed_pipeline_sclr_a = "NONE",
    parameter         signed_pipeline_sclr_b = "NONE",
    parameter         intended_device_family = "Cyclone V",
    parameter         lpm_type = "altera_mult_add",
    parameter         lpm_hint = "UNUSED",
    parameter         dedicated_multiplier_circuitry = "AUTO",
    parameter         dsp_block_balancing = "AUTO",
    parameter         selected_device_family = "Cyclone V",
    parameter         use_dsp_block = "YES"
) (
    input  wire [width_a-1:0]      dataa,
    input  wire [width_b-1:0]      datab,
    input  wire                    clock0,
    input  wire                    ena0,
    input  wire                    aclr0,
    input  wire                    sclr0,
    input  wire                    signa,
    input  wire                    signb,
    output wire [width_result-1:0] result
);
    wire sa = (port_signa == "PORT_USED") ? signa : (representation_a == "SIGNED");
    wire sb = (port_signb == "PORT_USED") ? signb : (representation_b == "SIGNED");
    wire signed [width_a:0] ea = {sa & dataa[width_a-1], dataa};
    wire signed [width_b:0] eb = {sb & datab[width_b-1], datab};
    wire signed [width_a+width_b+1:0] prod = ea * eb;
    wire [width_result-1:0] p = prod[width_result-1:0];
    reg  [width_result-1:0] p_q = {width_result{1'b0}};
    always @(posedge clock0) p_q <= p;
    assign result = (output_register == "UNREGISTERED") ? p : p_q;
endmodule
