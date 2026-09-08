-- iop_regstub.vhd -- a register file standing in for an IOP peripheral that
-- is not implemented yet.  Writes are stored, reads return what was written
-- (zero until then), so boot code that programs a block and reads its
-- configuration back does not hang or fault.  It generates no interrupts and
-- moves no data.  Every instance is listed in docs/iop-subsystem.md as a stub.
--
-- Byte enables are honoured.  They were not until 2026-09-08, and it mattered:
-- scanning the BIOS modules for the registers they touch found SIFMAN writing
-- DMA block counts with `sh` (0x1F8010A4, 0x1F801524, 0x1F801534), which a
-- word-granular stub answers by clobbering the other half of the register.
-- Nothing read those back while the DMA controller was a stub, so it cost
-- nothing at the time; it would have been a real and very confusing bug the
-- moment something behind them started acting on their contents.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity iop_regstub is
   generic
   (
      ADDR_BITS : integer := 6            -- byte-address bits covered (word registers)
   );
   port
   (
      clk1x         : in  std_logic;
      reset         : in  std_logic;
      bus_addr      : in  unsigned(ADDR_BITS-1 downto 0);
      bus_writeMask : in  std_logic_vector(3 downto 0) := "1111";
      bus_dataWrite : in  std_logic_vector(31 downto 0);
      bus_read      : in  std_logic;
      bus_write     : in  std_logic;
      bus_dataRead  : out std_logic_vector(31 downto 0) := (others => '0')
   );
end entity;

architecture arch of iop_regstub is
   type t_regs is array (0 to 2**(ADDR_BITS-2)-1) of std_logic_vector(31 downto 0);
   signal regs : t_regs := (others => (others => '0'));
begin
   -- read data is valid the cycle after bus_read and zero otherwise: the memory
   -- mux ORs all peripheral read data together (PSX_MiSTer memorymux.vhd)
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         bus_dataRead <= (others => '0');
         if (bus_read = '1') then
            bus_dataRead <= regs(to_integer(bus_addr(ADDR_BITS-1 downto 2)));
         end if;
         if (reset = '1') then
            regs <= (others => (others => '0'));
         elsif (bus_write = '1') then
            -- the mux presents the data word-aligned with the live lanes
            -- selected by bus_writeMask, so only those lanes are stored
            for i in 0 to 3 loop
               if (bus_writeMask(i) = '1') then
                  regs(to_integer(bus_addr(ADDR_BITS-1 downto 2)))(8*i+7 downto 8*i)
                     <= bus_dataWrite(8*i+7 downto 8*i);
               end if;
            end loop;
         end if;
      end if;
   end process;
end architecture;
