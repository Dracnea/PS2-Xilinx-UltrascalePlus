-- iop_spuram.vhd -- 512 KB of SPU work RAM on chip, behind the SDRAM-style
-- port PSX_MiSTer's spu_ram drives in its useSDRAM mode:
--
--   request : ram_ena for one cycle with ram_rnw, ram_Adr (byte address,
--             halfword aligned), ram_dataWrite(15 downto 0) and ram_be
--             ("0011") for writes.
--   reply   : ram_done for one cycle, ram_dataRead(15 downto 0) = the
--             halfword at ram_Adr.  One request at a time.
--
-- Organised as 128-bit rows (8 halfwords) so it infers UltraRAM without
-- waste: 2^15 rows x 16 bytes = 512 KB = 16 URAMs per instance.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity iop_spuram is
   generic
   (
      ROWS_LOG2 : integer := 15    -- 2^15 x 16 bytes = 512 KB
   );
   port
   (
      clk1x         : in  std_logic;
      reset         : in  std_logic;
      ram_ena       : in  std_logic;
      ram_rnw       : in  std_logic;
      ram_Adr       : in  std_logic_vector(18 downto 0);
      ram_be        : in  std_logic_vector(3 downto 0);
      ram_dataWrite : in  std_logic_vector(31 downto 0);
      ram_done      : out std_logic := '0';
      ram_dataRead  : out std_logic_vector(31 downto 0) := (others => '0')
   );
end entity;

architecture arch of iop_spuram is

   type t_ram is array (0 to 2**ROWS_LOG2-1) of std_logic_vector(127 downto 0);
   signal ram : t_ram := (others => (others => '0'));
   attribute ram_style : string;
   attribute ram_style of ram : signal is "ultra";

   signal wbe     : std_logic_vector(15 downto 0) := (others => '0');
   signal wrow    : unsigned(ROWS_LOG2-1 downto 0);
   signal wdata   : std_logic_vector(127 downto 0);
   signal rd_row  : unsigned(ROWS_LOG2-1 downto 0) := (others => '0');
   signal rd_lane : unsigned(2 downto 0) := (others => '0');
   signal q, q2   : std_logic_vector(127 downto 0) := (others => '0');
   signal v0, v1, v2 : std_logic := '0';
   signal wr_ack  : std_logic := '0';

   -- synthesis translate_off
   -- xsim cannot read an element of a VHDL array from a SystemVerilog bench
   -- reliably, so the boot test's check of row 0x200 (the transfer target)
   -- reads this scalar mirror instead.  Simulation only.
   signal sim_row200 : std_logic_vector(127 downto 0) := (others => '0');
   -- synthesis translate_on

begin

   -- synthesis translate_off
   sim_row200 <= ram(16#200#);
   -- synthesis translate_on

   wrow  <= unsigned(ram_Adr(ROWS_LOG2+3 downto 4));
   wdata <= ram_dataWrite(15 downto 0) & ram_dataWrite(15 downto 0) & ram_dataWrite(15 downto 0) & ram_dataWrite(15 downto 0) &
            ram_dataWrite(15 downto 0) & ram_dataWrite(15 downto 0) & ram_dataWrite(15 downto 0) & ram_dataWrite(15 downto 0);

   process (ram_ena, ram_rnw, ram_Adr, ram_be)
      variable lane : integer range 0 to 7;
   begin
      wbe  <= (others => '0');
      lane := to_integer(unsigned(ram_Adr(3 downto 1)));
      if (ram_ena = '1' and ram_rnw = '0') then
         wbe(2*lane)   <= ram_be(0);
         wbe(2*lane+1) <= ram_be(1);
      end if;
   end process;

   process (clk1x)
   begin
      if rising_edge(clk1x) then
         for i in 0 to 15 loop
            if (wbe(i) = '1') then
               ram(to_integer(wrow))(8*i+7 downto 8*i) <= wdata(8*i+7 downto 8*i);
            end if;
         end loop;
         q  <= ram(to_integer(rd_row));
         q2 <= q;
      end if;
   end process;

   process (clk1x)
   begin
      if rising_edge(clk1x) then
         ram_done <= '0';
         v0 <= '0';
         if (reset = '1') then
            v1 <= '0'; v2 <= '0'; wr_ack <= '0';
         else
            if (ram_ena = '1' and ram_rnw = '1') then
               rd_row  <= unsigned(ram_Adr(ROWS_LOG2+3 downto 4));
               rd_lane <= unsigned(ram_Adr(3 downto 1));
               v0 <= '1';
            end if;
            wr_ack <= ram_ena and not ram_rnw;
            if (wr_ack = '1') then
               ram_done <= '1';
            end if;
            v1 <= v0;      -- q valid next cycle
            v2 <= v1;      -- q2 valid
            if (v2 = '1') then
               ram_dataRead <= x"0000" & q2(16*to_integer(rd_lane)+15 downto 16*to_integer(rd_lane));
               ram_done     <= '1';
            end if;
         end if;
      end if;
   end process;

end architecture;
