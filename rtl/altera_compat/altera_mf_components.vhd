-- Package altera_mf.altera_mf_components -- component declarations for the
-- Verilog stand-ins in this directory, so VHDL that says
--   library altera_mf; use altera_mf.altera_mf_components.all;
-- elaborates. Generic and port names match the Verilog parameters and ports
-- one to one; every input has a default so the sparse instantiations in the
-- MiSTer cores (RamMLAB, dpram, SyncRamDualByteEnable, Shiftreg, cpu_mul)
-- leave the rest unconnected. Read into library altera_mf.
-- SPDX-License-Identifier: BSD-2-Clause
library ieee;
use ieee.std_logic_1164.all;

package altera_mf_components is

    component altsyncram
        generic (
            width_a                : natural := 8;
            widthad_a              : natural := 8;
            numwords_a             : natural := 0;
            width_b                : natural := 8;
            widthad_b              : natural := 8;
            numwords_b             : natural := 0;
            width_byteena_a        : natural := 1;
            width_byteena_b        : natural := 1;
            operation_mode         : string  := "BIDIR_DUAL_PORT";
            outdata_reg_a          : string  := "UNREGISTERED";
            outdata_reg_b          : string  := "UNREGISTERED";
            address_reg_b          : string  := "CLOCK1";
            indata_reg_b           : string  := "CLOCK1";
            wrcontrol_wraddress_reg_b : string := "CLOCK1";
            rdcontrol_reg_b        : string  := "CLOCK1";
            byteena_reg_b          : string  := "CLOCK1";
            clock_enable_input_a   : string  := "NORMAL";
            clock_enable_input_b   : string  := "NORMAL";
            clock_enable_output_a  : string  := "BYPASS";
            clock_enable_output_b  : string  := "BYPASS";
            clock_enable_core_a    : string  := "USE_INPUT_CLKEN";
            clock_enable_core_b    : string  := "USE_INPUT_CLKEN";
            outdata_aclr_a         : string  := "NONE";
            outdata_aclr_b         : string  := "NONE";
            indata_aclr_a          : string  := "NONE";
            address_aclr_a         : string  := "NONE";
            address_aclr_b         : string  := "NONE";
            wrcontrol_aclr_a       : string  := "NONE";
            byteena_aclr_a         : string  := "NONE";
            byteena_aclr_b         : string  := "NONE";
            read_during_write_mode_port_a      : string := "NEW_DATA_NO_NBE_READ";
            read_during_write_mode_port_b      : string := "NEW_DATA_NO_NBE_READ";
            read_during_write_mode_mixed_ports : string := "DONT_CARE";
            power_up_uninitialized : string  := "FALSE";
            init_file              : string  := "UNUSED";
            init_file_layout       : string  := "PORT_A";
            ram_block_type         : string  := "AUTO";
            intended_device_family : string  := "Cyclone V";
            lpm_type               : string  := "altsyncram";
            lpm_hint               : string  := "UNUSED";
            maximum_depth          : natural := 0;
            byte_size              : natural := 8;
            enable_ecc             : string  := "FALSE";
            implement_in_les       : string  := "OFF";
            ecc_pipeline_stage_enabled : string := "FALSE"
        );
        port (
            address_a      : in  std_logic_vector(widthad_a-1 downto 0) := (others => '0');
            address_b      : in  std_logic_vector(widthad_b-1 downto 0) := (others => '0');
            data_a         : in  std_logic_vector(width_a-1 downto 0)   := (others => '0');
            data_b         : in  std_logic_vector(width_b-1 downto 0)   := (others => '0');
            wren_a         : in  std_logic := '0';
            wren_b         : in  std_logic := '0';
            rden_a         : in  std_logic := '1';
            rden_b         : in  std_logic := '1';
            clock0         : in  std_logic := '1';
            clock1         : in  std_logic := '1';
            clocken0       : in  std_logic := '1';
            clocken1       : in  std_logic := '1';
            clocken2       : in  std_logic := '1';
            clocken3       : in  std_logic := '1';
            byteena_a      : in  std_logic_vector(width_byteena_a-1 downto 0) := (others => '1');
            byteena_b      : in  std_logic_vector(width_byteena_b-1 downto 0) := (others => '1');
            aclr0          : in  std_logic := '0';
            aclr1          : in  std_logic := '0';
            addressstall_a : in  std_logic := '0';
            addressstall_b : in  std_logic := '0';
            q_a            : out std_logic_vector(width_a-1 downto 0);
            q_b            : out std_logic_vector(width_b-1 downto 0);
            eccstatus      : out std_logic_vector(2 downto 0)
        );
    end component;

    component altdpram
        generic (
            width          : natural := 8;
            widthad        : natural := 8;
            numwords       : natural := 0;
            width_byteena  : natural := 1;
            indata_reg     : string  := "INCLOCK";
            outdata_reg    : string  := "UNREGISTERED";
            rdaddress_reg  : string  := "UNREGISTERED";
            rdcontrol_reg  : string  := "UNREGISTERED";
            wraddress_reg  : string  := "INCLOCK";
            wrcontrol_reg  : string  := "INCLOCK";
            indata_aclr    : string  := "OFF";
            outdata_aclr   : string  := "OFF";
            rdaddress_aclr : string  := "OFF";
            rdcontrol_aclr : string  := "OFF";
            wraddress_aclr : string  := "OFF";
            wrcontrol_aclr : string  := "OFF";
            ram_block_type : string  := "MLAB";
            read_during_write_mode_mixed_ports : string := "CONSTRAINED_DONT_CARE";
            intended_device_family : string := "Cyclone V";
            lpm_type       : string  := "altdpram";
            lpm_hint       : string  := "UNUSED";
            use_eab        : string  := "OFF"
        );
        port (
            data       : in  std_logic_vector(width-1 downto 0) := (others => '0');
            wraddress  : in  std_logic_vector(widthad-1 downto 0) := (others => '0');
            rdaddress  : in  std_logic_vector(widthad-1 downto 0) := (others => '0');
            wren       : in  std_logic := '0';
            rden       : in  std_logic := '1';
            inclock    : in  std_logic := '1';
            outclock   : in  std_logic := '1';
            inclocken  : in  std_logic := '1';
            outclocken : in  std_logic := '1';
            byteena    : in  std_logic_vector(width_byteena-1 downto 0) := (others => '1');
            aclr       : in  std_logic := '0';
            q          : out std_logic_vector(width-1 downto 0)
        );
    end component;

    component altshift_taps
        generic (
            number_of_taps : natural := 1;
            tap_distance   : natural := 4;
            width          : natural := 8;
            lpm_type       : string  := "altshift_taps";
            lpm_hint       : string  := "UNUSED";
            intended_device_family : string := "Cyclone V";
            power_up_state : string  := "CLEARED"
        );
        port (
            clock    : in  std_logic := '1';
            clken    : in  std_logic := '1';
            aclr     : in  std_logic := '0';
            shiftin  : in  std_logic_vector(width-1 downto 0) := (others => '0');
            shiftout : out std_logic_vector(width-1 downto 0);
            taps     : out std_logic_vector(width*number_of_taps-1 downto 0)
        );
    end component;

    component altera_mult_add
        generic (
            number_of_multipliers : natural := 1;
            width_a        : natural := 64;
            width_b        : natural := 64;
            width_result   : natural := 128;
            output_register : string := "CLOCK0";
            output_aclr    : string := "NONE";
            output_sclr    : string := "NONE";
            multiplier1_direction : string := "ADD";
            port_addnsub1  : string := "PORT_UNUSED";
            addnsub_multiplier_register1 : string := "UNREGISTERED";
            addnsub_multiplier_aclr1 : string := "NONE";
            addnsub_multiplier_sclr1 : string := "NONE";
            input_register_a0 : string := "UNREGISTERED";
            input_register_b0 : string := "UNREGISTERED";
            input_aclr_a0  : string := "NONE";
            input_aclr_b0  : string := "NONE";
            input_sclr_a0  : string := "NONE";
            input_sclr_b0  : string := "NONE";
            input_source_a0 : string := "DATAA";
            input_source_b0 : string := "DATAB";
            multiplier_register0 : string := "UNREGISTERED";
            multiplier_aclr0 : string := "NONE";
            multiplier_sclr0 : string := "NONE";
            port_signa     : string := "PORT_USED";
            port_signb     : string := "PORT_USED";
            representation_a : string := "UNSIGNED";
            representation_b : string := "UNSIGNED";
            signed_register_a : string := "UNREGISTERED";
            signed_register_b : string := "UNREGISTERED";
            signed_aclr_a  : string := "NONE";
            signed_aclr_b  : string := "NONE";
            signed_sclr_a  : string := "NONE";
            signed_sclr_b  : string := "NONE";
            signed_pipeline_register_a : string := "UNREGISTERED";
            signed_pipeline_register_b : string := "UNREGISTERED";
            signed_pipeline_aclr_a : string := "NONE";
            signed_pipeline_aclr_b : string := "NONE";
            signed_pipeline_sclr_a : string := "NONE";
            signed_pipeline_sclr_b : string := "NONE";
            intended_device_family : string := "Cyclone V";
            lpm_type       : string := "altera_mult_add";
            lpm_hint       : string := "UNUSED";
            dedicated_multiplier_circuitry : string := "AUTO";
            dsp_block_balancing : string := "AUTO";
            selected_device_family : string := "Cyclone V";
            use_dsp_block  : string := "YES"
        );
        port (
            dataa  : in  std_logic_vector(width_a-1 downto 0) := (others => '0');
            datab  : in  std_logic_vector(width_b-1 downto 0) := (others => '0');
            clock0 : in  std_logic := '1';
            ena0   : in  std_logic := '1';
            aclr0  : in  std_logic := '0';
            sclr0  : in  std_logic := '0';
            signa  : in  std_logic := '0';
            signb  : in  std_logic := '0';
            result : out std_logic_vector(width_result-1 downto 0)
        );
    end component;

    component altddio_out
        generic (
            width          : natural := 1;
            power_up_high  : string := "OFF";
            oe_reg         : string := "UNREGISTERED";
            extend_oe_disable : string := "OFF";
            invert_output  : string := "OFF";
            intended_device_family : string := "Cyclone V";
            lpm_type       : string := "altddio_out";
            lpm_hint       : string := "UNUSED"
        );
        port (
            datain_h   : in  std_logic_vector(width-1 downto 0) := (others => '0');
            datain_l   : in  std_logic_vector(width-1 downto 0) := (others => '0');
            outclock   : in  std_logic := '1';
            outclocken : in  std_logic := '1';
            oe         : in  std_logic := '1';
            aclr       : in  std_logic := '0';
            aset       : in  std_logic := '0';
            sclr       : in  std_logic := '0';
            sset       : in  std_logic := '0';
            dataout    : out std_logic_vector(width-1 downto 0);
            oe_out     : out std_logic
        );
    end component;

    component scfifo
        generic (
            lpm_width     : natural := 8;
            lpm_numwords  : natural := 32;
            lpm_widthu    : natural := 5;
            lpm_showahead : string  := "OFF";
            lpm_type      : string  := "scfifo";
            lpm_hint      : string  := "UNUSED";
            add_ram_output_register : string := "OFF";
            overflow_checking  : string := "ON";
            underflow_checking : string := "ON";
            use_eab       : string  := "ON";
            allow_rwcycle_when_full : string := "OFF";
            intended_device_family : string := "Cyclone V";
            almost_full_value  : natural := 0;
            almost_empty_value : natural := 0
        );
        port (
            clock  : in  std_logic := '1';
            data   : in  std_logic_vector(lpm_width-1 downto 0) := (others => '0');
            wrreq  : in  std_logic := '0';
            rdreq  : in  std_logic := '0';
            sclr   : in  std_logic := '0';
            aclr   : in  std_logic := '0';
            q      : out std_logic_vector(lpm_width-1 downto 0);
            empty  : out std_logic;
            full   : out std_logic;
            almost_full  : out std_logic;
            almost_empty : out std_logic;
            usedw  : out std_logic_vector(lpm_widthu-1 downto 0)
        );
    end component;

    component dcfifo
        generic (
            lpm_width     : natural := 8;
            lpm_numwords  : natural := 32;
            lpm_widthu    : natural := 5;
            lpm_width_r   : natural := 8;
            lpm_widthu_r  : natural := 5;
            lpm_showahead : string  := "OFF";
            lpm_type      : string  := "dcfifo";
            lpm_hint      : string  := "UNUSED";
            overflow_checking  : string := "ON";
            underflow_checking : string := "ON";
            use_eab       : string  := "ON";
            rdsync_delaypipe : natural := 2;
            wrsync_delaypipe : natural := 2;
            add_ram_output_register : string := "OFF";
            intended_device_family : string := "Cyclone V";
            read_aclr_synch  : string := "OFF";
            write_aclr_synch : string := "OFF";
            clocks_are_synchronized : string := "FALSE";
            add_usedw_msb_bit : string := "OFF"
        );
        port (
            wrclk   : in  std_logic := '1';
            rdclk   : in  std_logic := '1';
            data    : in  std_logic_vector(lpm_width-1 downto 0) := (others => '0');
            wrreq   : in  std_logic := '0';
            rdreq   : in  std_logic := '0';
            aclr    : in  std_logic := '0';
            q       : out std_logic_vector(lpm_width-1 downto 0);
            rdempty : out std_logic;
            wrfull  : out std_logic;
            rdfull  : out std_logic;
            wrempty : out std_logic;
            rdusedw : out std_logic_vector(lpm_widthu-1 downto 0);
            wrusedw : out std_logic_vector(lpm_widthu-1 downto 0)
        );
    end component;

end package;
