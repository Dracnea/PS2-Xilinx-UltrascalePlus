-- Package lpm.lpm_components -- component declarations for lpm_mult and
-- lpm_divide, so `library lpm; use lpm.all;` (and lpm.lpm_components.all)
-- elaborate against the Verilog stand-ins here. Read into library lpm.
-- SPDX-License-Identifier: BSD-2-Clause
library ieee;
use ieee.std_logic_1164.all;

package lpm_components is

    component lpm_mult
        generic (
            lpm_widtha         : natural := 16;
            lpm_widthb         : natural := 16;
            lpm_widthp         : natural := 32;
            lpm_widths         : natural := 1;
            lpm_pipeline       : natural := 0;
            lpm_representation : string  := "UNSIGNED";
            lpm_type           : string  := "LPM_MULT";
            lpm_hint           : string  := "UNUSED";
            dsp_block_balancing : string := "AUTO";
            maximize_speed     : natural := 5
        );
        port (
            dataa  : in  std_logic_vector(lpm_widtha-1 downto 0) := (others => '0');
            datab  : in  std_logic_vector(lpm_widthb-1 downto 0) := (others => '0');
            sum    : in  std_logic_vector(lpm_widths-1 downto 0) := (others => '0');
            clock  : in  std_logic := '1';
            clken  : in  std_logic := '1';
            aclr   : in  std_logic := '0';
            result : out std_logic_vector(lpm_widthp-1 downto 0)
        );
    end component;

    component lpm_divide
        generic (
            lpm_widthn          : natural := 16;
            lpm_widthd          : natural := 16;
            lpm_pipeline        : natural := 0;
            lpm_nrepresentation : string  := "UNSIGNED";
            lpm_drepresentation : string  := "UNSIGNED";
            lpm_type            : string  := "LPM_DIVIDE";
            lpm_hint            : string  := "UNUSED";
            maximize_speed      : natural := 5
        );
        port (
            numer    : in  std_logic_vector(lpm_widthn-1 downto 0) := (others => '0');
            denom    : in  std_logic_vector(lpm_widthd-1 downto 0) := (others => '0');
            clock    : in  std_logic := '1';
            clken    : in  std_logic := '1';
            aclr     : in  std_logic := '0';
            quotient : out std_logic_vector(lpm_widthn-1 downto 0);
            remain   : out std_logic_vector(lpm_widthd-1 downto 0)
        );
    end component;

end package;
