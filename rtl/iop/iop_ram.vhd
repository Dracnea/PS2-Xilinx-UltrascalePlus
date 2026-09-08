-- iop_ram.vhd -- the IOP's 2 MB RAM and 4 MB ROM as on-chip memory, behind the
-- RAM protocol the PSX memory mux and CPU expect from PSX_MiSTer's SDRAM
-- controller (overlay/cores/PSX/rtl/sdram.sv, channel 1):
--
--   request : ram_ena for one clk1x cycle with ram_rnw, ram_Adr (byte address,
--             word aligned), ram_be / ram_dataWrite for writes, ram_cache for
--             an instruction-cache line fill.
--   reply   : ram_done for one cycle with ram_dataRead = the word at ram_Adr.
--             For a cache fill the words from ram_Adr to the end of its 16-byte
--             line are also written straight into the CPU's instruction cache
--             through cache_wr (one-hot word select), cache_data and
--             cache_addr = ram_Adr(11 downto 4), one word per clk1x cycle.
--
-- One difference from the SDRAM controller, found in simulation: that
-- controller delivers the line words at clk3x rate and ram_done reaches the
-- CPU a resynchronisation later, so every word is in the cache before the CPU
-- looks for it.  Delivering a word per clk1x cycle with ram_done on the
-- second word (the SDRAM's nominal timing) makes the CPU miss on the third
-- and fourth words and refetch them.  Here ram_done comes with the LAST word
-- of the fill instead; the fill costs a couple of cycles more and the CPU
-- never sees a partially filled line.
--
-- Address map, ram_Adr(24 downto 23):  "00" RAM (2 MB, mirrored above),
-- "01" ROM (4 MB).  The ROM is a RAM with a second write port (rom_wr /
-- rom_addr / rom_data, word addressed) for the host or the testbench to load
-- an image into; the console's own ROM is a flash part the IOP never writes.
--
-- Both arrays are organised as 128-bit rows (one cache line) so that they
-- infer UltraRAM efficiently: a URAM is 4096 x 72, and a 32-bit-wide array
-- wastes 40 bits of every row (a 32-bit organisation of the same 6 MB cost
-- 384 URAMs on xcu55n; this one costs 192).  Read latency is two cycles so
-- the URAM output registers can be used.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity iop_ram is
   generic
   (
      RAM_ROWS_LOG2 : integer := 17;   -- 2^17 x 16 bytes = 2 MB
      ROM_ROWS_LOG2 : integer := 18    -- 2^18 x 16 bytes = 4 MB
   );
   port
   (
      clk1x         : in  std_logic;
      reset         : in  std_logic;
      -- memory-mux side
      ram_ena       : in  std_logic;
      ram_rnw       : in  std_logic;
      ram_Adr       : in  std_logic_vector(24 downto 0);
      ram_be        : in  std_logic_vector(3 downto 0);
      ram_dataWrite : in  std_logic_vector(31 downto 0);
      ram_cache     : in  std_logic;
      ram_done      : out std_logic := '0';
      ram_dataRead  : out std_logic_vector(31 downto 0) := (others => '0');
      -- CPU instruction-cache fill
      cache_wr      : out std_logic_vector(3 downto 0) := (others => '0');
      cache_data    : out std_logic_vector(31 downto 0) := (others => '0');
      cache_addr    : out std_logic_vector(7 downto 0) := (others => '0');
      -- ROM load port (word addressed)
      rom_wr        : in  std_logic;
      rom_addr      : in  std_logic_vector(19 downto 0);
      rom_data      : in  std_logic_vector(31 downto 0)
   );
end entity;

architecture arch of iop_ram is

   type t_ram is array (0 to 2**RAM_ROWS_LOG2-1) of std_logic_vector(127 downto 0);
   type t_rom is array (0 to 2**ROM_ROWS_LOG2-1) of std_logic_vector(127 downto 0);
   signal ram : t_ram := (others => (others => '0'));
   signal rom : t_rom := (others => (others => '0'));
   attribute ram_style : string;
   attribute ram_style of ram : signal is "ultra";
   attribute ram_style of rom : signal is "ultra";

   -- write side: byte enables and data spread over the 128-bit row
   signal ram_we      : std_logic := '0';
   signal ram_wbe     : std_logic_vector(15 downto 0) := (others => '0');
   signal ram_wrow    : unsigned(RAM_ROWS_LOG2-1 downto 0) := (others => '0');
   signal ram_wdata   : std_logic_vector(127 downto 0) := (others => '0');
   signal rom_wbe     : std_logic_vector(15 downto 0) := (others => '0');
   signal rom_wrow    : unsigned(ROM_ROWS_LOG2-1 downto 0) := (others => '0');
   signal rom_wdata   : std_logic_vector(127 downto 0) := (others => '0');

   -- read side
   signal rd_row      : unsigned(ROM_ROWS_LOG2-1 downto 0) := (others => '0');
   signal ram_q, ram_q2, rom_q, rom_q2 : std_logic_vector(127 downto 0) := (others => '0');

   type t_state is (IDLE, WRITEACK, RD1, RD2, EMIT);
   signal state       : t_state := IDLE;
   signal is_rom      : std_logic := '0';
   signal is_cache    : std_logic := '0';
   signal word_idx    : unsigned(1 downto 0) := (others => '0');
   signal first_word  : std_logic := '0';

begin

   -- ------------------------------------------------------------------ RAM
   ram_we   <= '1' when (ram_ena = '1' and ram_rnw = '0' and ram_Adr(24 downto 23) = "00") else '0';
   ram_wrow <= unsigned(ram_Adr(RAM_ROWS_LOG2+3 downto 4));
   ram_wdata <= ram_dataWrite & ram_dataWrite & ram_dataWrite & ram_dataWrite;
   process (ram_Adr, ram_be, ram_we)
   begin
      ram_wbe <= (others => '0');
      if (ram_we = '1') then
         case (ram_Adr(3 downto 2)) is
            when "00"   => ram_wbe( 3 downto  0) <= ram_be;
            when "01"   => ram_wbe( 7 downto  4) <= ram_be;
            when "10"   => ram_wbe(11 downto  8) <= ram_be;
            when others => ram_wbe(15 downto 12) <= ram_be;
         end case;
      end if;
   end process;

   process (clk1x)
   begin
      if rising_edge(clk1x) then
         for i in 0 to 15 loop
            if (ram_wbe(i) = '1') then
               ram(to_integer(ram_wrow))(8*i+7 downto 8*i) <= ram_wdata(8*i+7 downto 8*i);
            end if;
         end loop;
         ram_q  <= ram(to_integer(rd_row(RAM_ROWS_LOG2-1 downto 0)));
         ram_q2 <= ram_q;
      end if;
   end process;

   -- ------------------------------------------------------------------ ROM
   rom_wrow  <= unsigned(rom_addr(ROM_ROWS_LOG2+1 downto 2));
   rom_wdata <= rom_data & rom_data & rom_data & rom_data;
   process (rom_addr, rom_wr)
   begin
      rom_wbe <= (others => '0');
      if (rom_wr = '1') then
         case (rom_addr(1 downto 0)) is
            when "00"   => rom_wbe( 3 downto  0) <= "1111";
            when "01"   => rom_wbe( 7 downto  4) <= "1111";
            when "10"   => rom_wbe(11 downto  8) <= "1111";
            when others => rom_wbe(15 downto 12) <= "1111";
         end case;
      end if;
   end process;

   process (clk1x)
   begin
      if rising_edge(clk1x) then
         for i in 0 to 15 loop
            if (rom_wbe(i) = '1') then
               rom(to_integer(rom_wrow))(8*i+7 downto 8*i) <= rom_wdata(8*i+7 downto 8*i);
            end if;
         end loop;
         rom_q  <= rom(to_integer(rd_row));
         rom_q2 <= rom_q;
      end if;
   end process;

   -- ------------------------------------------------------- request sequencing
   process (clk1x)
      variable row_q : std_logic_vector(127 downto 0);
      variable word  : std_logic_vector(31 downto 0);
      variable last  : std_logic;
   begin
      if rising_edge(clk1x) then
         ram_done <= '0';
         cache_wr <= (others => '0');
         if (reset = '1') then
            state <= IDLE;
         else
            case (state) is
               when IDLE =>
                  if (ram_ena = '1') then
                     if (ram_rnw = '0') then
                        state <= WRITEACK;
                     else
                        is_rom     <= ram_Adr(23);
                        is_cache   <= ram_cache and not ram_Adr(23);   -- the mux never asks for a cached ROM line
                        if (ram_Adr(23) = '1') then
                           rd_row <= unsigned(ram_Adr(ROM_ROWS_LOG2+3 downto 4));
                        else
                           rd_row <= resize(unsigned(ram_Adr(RAM_ROWS_LOG2+3 downto 4)), ROM_ROWS_LOG2);
                        end if;
                        word_idx   <= unsigned(ram_Adr(3 downto 2));
                        cache_addr <= ram_Adr(11 downto 4);
                        first_word <= '1';
                        state      <= RD1;
                     end if;
                  end if;

               when WRITEACK =>
                  ram_done <= '1';
                  state    <= IDLE;

               when RD1 =>              -- row address is being read this cycle
                  state <= RD2;

               when RD2 =>              -- *_q valid, *_q2 next cycle
                  state <= EMIT;

               when EMIT =>
                  if (is_rom = '1') then row_q := rom_q2; else row_q := ram_q2; end if;
                  case (word_idx) is
                     when "00"   => word := row_q( 31 downto  0);
                     when "01"   => word := row_q( 63 downto 32);
                     when "10"   => word := row_q( 95 downto 64);
                     when others => word := row_q(127 downto 96);
                  end case;
                  if (first_word = '1') then
                     ram_dataRead <= word;
                     first_word   <= '0';
                  end if;
                  if (is_cache = '1') then
                     cache_data <= word;
                     case (word_idx) is
                        when "00"   => cache_wr <= "0001";
                        when "01"   => cache_wr <= "0010";
                        when "10"   => cache_wr <= "0100";
                        when others => cache_wr <= "1000";
                     end case;
                     if (word_idx = "11") then last := '1'; else last := '0'; end if;
                  else
                     last := '1';
                  end if;
                  word_idx <= word_idx + 1;
                  if (last = '1') then
                     ram_done <= '1';
                     state    <= IDLE;
                  end if;

               when others =>
                  state <= IDLE;
            end case;
         end if;
      end if;
   end process;

end architecture;
