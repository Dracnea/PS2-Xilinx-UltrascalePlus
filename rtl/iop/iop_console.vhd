-- iop_console.vhd -- the IOP's serial port (SIO1, 0x1F801050) as a console
-- sink.  The IOP kernel's Kprintf polls the status register for TX ready and
-- writes bytes to DATA; this always reports ready and hands every byte to
-- the outside (a FIFO the host reads, or the simulation bench's $write).
-- Nothing is received.  MODE/CTRL/BAUD are stored and read back.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity iop_console is
   port
   (
      clk1x         : in  std_logic;
      reset         : in  std_logic;
      bus_addr      : in  unsigned(3 downto 0);
      bus_dataWrite : in  std_logic_vector(31 downto 0);
      bus_read      : in  std_logic;
      bus_write     : in  std_logic;
      bus_dataRead  : out std_logic_vector(31 downto 0) := (others => '0');
      con_wr        : out std_logic := '0';
      con_data      : out std_logic_vector(7 downto 0) := (others => '0')
   );
end entity;

architecture arch of iop_console is
   signal mode : std_logic_vector(15 downto 0) := (others => '0');
   signal ctrl : std_logic_vector(15 downto 0) := (others => '0');
   signal baud : std_logic_vector(15 downto 0) := (others => '0');
begin
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         con_wr <= '0';
         if (reset = '1') then
            mode <= (others => '0'); ctrl <= (others => '0'); baud <= (others => '0');
         else
            if (bus_read = '1') then
               bus_dataRead <= (others => '0');
               case bus_addr is
                  when x"4"   => bus_dataRead <= x"00000005";          -- STAT: TX ready, TX empty, nothing received
                  when x"8"   => bus_dataRead <= x"0000" & mode;
                  when x"A"   => bus_dataRead <= x"0000" & ctrl;
                  when x"E"   => bus_dataRead <= x"0000" & baud;
                  when others => null;
               end case;
            end if;
            if (bus_write = '1') then
               case bus_addr is
                  when x"0"   => con_wr <= '1'; con_data <= bus_dataWrite(7 downto 0);
                  when x"8"   => mode <= bus_dataWrite(15 downto 0);
                  when x"A"   => ctrl <= bus_dataWrite(15 downto 0);
                  when x"E"   => baud <= bus_dataWrite(15 downto 0);
                  when others => null;
               end case;
            end if;
         end if;
      end if;
   end process;
end architecture;
