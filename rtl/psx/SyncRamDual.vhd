-- SyncRamDual -- Vivado replacement for the Peip cores' upstream/rtl/SyncRamDual.vhd.
--
-- Upstream writes a `signal` array from both ports in ONE process. Quartus infers
-- a true dual-port RAM from that; Vivado 2026.1 does not -- it builds the array
-- out of registers (the GBA's 8 KB "smallram" came out as 65,544 flip-flops and
-- 157k LUTs, four times over). Same entity, same generics, same ports; the body
-- is the two-process shared-variable form Vivado's inference wants, read-first on
-- each port, which is what the signal form gave (reads see the old value).
-- SPDX-License-Identifier: BSD-2-Clause
library ieee;
use ieee.std_logic_1164.all;

entity SyncRamDual is
   generic
   (
      DATA_WIDTH : natural := 8;
      ADDR_WIDTH : natural := 6
   );
   port
   (
      clk        : in std_logic;

      addr_a     : in natural range 0 to 2**ADDR_WIDTH - 1;
      datain_a   : in std_logic_vector((DATA_WIDTH-1) downto 0);
      dataout_a  : out std_logic_vector((DATA_WIDTH -1) downto 0);
      we_a       : in std_logic := '1';
      re_a       : in std_logic := '1';

      addr_b     : in natural range 0 to 2**ADDR_WIDTH - 1;
      datain_b   : in std_logic_vector((DATA_WIDTH-1) downto 0);
      dataout_b  : out std_logic_vector((DATA_WIDTH -1) downto 0);
      we_b       : in std_logic := '1';
      re_b       : in std_logic := '1'
   );
end;

architecture rtl of SyncRamDual is
   subtype word_t is std_logic_vector((DATA_WIDTH-1) downto 0);
   type memory_t is array(0 to 2**ADDR_WIDTH-1) of word_t;
   shared variable ram : memory_t := (others => (others => '0'));
   attribute ram_style : string;
   attribute ram_style of ram : variable is "block";
begin
   port_a : process(clk)
   begin
      if rising_edge(clk) then
         if re_a = '1' then dataout_a <= ram(addr_a); end if;
         if we_a = '1' then ram(addr_a) := datain_a; end if;
      end if;
   end process;

   port_b : process(clk)
   begin
      if rising_edge(clk) then
         if re_b = '1' then dataout_b <= ram(addr_b); end if;
         if we_b = '1' then ram(addr_b) := datain_b; end if;
      end if;
   end process;
end rtl;
