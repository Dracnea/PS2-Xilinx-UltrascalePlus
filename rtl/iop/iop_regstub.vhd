-- iop_regstub.vhd -- a register file standing in for an IOP peripheral that
-- is not implemented yet.  Writes are stored, reads return what was written
-- (RESET_VALUE until then), so boot code that programs a block and reads its
-- configuration back does not hang or fault.  It generates no interrupts and
-- moves no data.  Every instance is listed in the PS2 README as a stub.

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
            regs(to_integer(bus_addr(ADDR_BITS-1 downto 2))) <= bus_dataWrite;
         end if;
      end if;
   end process;
end architecture;
