-- iop_dma.vhd -- the IOP's DMA controller.
--
-- Thirteen channels in two banks, as the PS2's IOP has them:
--
--   bank 1, 0x1F801080 + ch*0x10, channels 0-6
--     0 MDECin  1 MDECout  2 SIF2/GPU  3 CDVD  4 SPU2 core0  5 PIO  6 OTC
--     0x1F8010F0 DPCR   0x1F8010F4 DICR
--   bank 2, 0x1F801500 + (ch-7)*0x10, channels 7-12
--     7 SPU2 core1  8 DEV9  9 SIF0  10 SIF1  11 SIO2in  12 SIO2out
--     0x1F801570 DPCR2  0x1F801574 DICR2  0x1F801578 DMACEN  0x1F80157C DMACINTEN
--
-- Per channel: +0 MADR, +4 BCR, +8 CHCR, +C TADR (chain mode).
--
-- CHCR bits, from the PS1's, which the IOP's is a superset of:
--   0      direction: 0 = to RAM (from the device), 1 = from RAM
--   1      address step: 0 = +4, 1 = -4
--   8      chopping enable
--   9-10   SyncMode: 0 burst, 1 slice/block, 2 linked list
--   16-18  chopping DMA window, 20-22 chopping CPU window
--   24     start/busy -- cleared by the controller when the transfer ends
--   28     start/trigger -- cleared when the transfer begins (SyncMode 0)
--
-- DICR: bit 15 force IRQ, 16-22 per-channel enable, 23 master enable,
-- 24-30 per-channel flags (a write clears the bits it names), 31 the master
-- flag, which is read-only and is force | (master_enable & (enable & flags)).
-- The master flag going high is what raises INTC bit 3.
--
-- What is implemented, and what is not:
--
--   * The register file, DPCR/DPCR2, DICR/DICR2, DMACEN and the interrupt --
--     all channels.
--   * **Channel 6, OTC, completely.** It needs no peripheral: it walks
--     backwards through RAM writing a linked list, each word holding the
--     address of the previous one and the last word written holding
--     0x00FFFFFF. That makes it the one channel that can be tested with
--     nothing else present, which is why it is first.
--   * **Channel 3, CDVD**, has its device-side handshake here (`dev_*`) and
--     moves words the device supplies. It does nothing until the CDVD block
--     supplies them; today `dev_valid` is tied low.
--   * Every other channel accepts its registers and reports completion
--     without moving data, which is what the previous register stub did, so
--     nothing that worked before this block breaks.
--
-- > **NOTE (unverified):** chopping, SyncMode 1 and 2 (slice and linked list),
-- > and the priority/round-robin arbitration DPCR describes are not
-- > implemented. The BIOS's own boot does not use them on the channels above,
-- > and SIF's chain mode will need them.
-- > *Verify by: watching CHCR writes on the analyzer once SIFMAN moves real
-- > data, and implementing what it actually asks for.*
--
-- Derived from PSX_MiSTer's rtl/dma.vhd (Robert Peip, GPL-2.0) for the OTC
-- word format and the CHCR/DICR semantics; the structure here is new because
-- that controller is bound to the PS1's peripherals.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity iop_dma is
   port
   (
      clk1x         : in  std_logic;
      reset         : in  std_logic;

      -- bank 1: channels 0-6, DPCR, DICR
      bus_addr      : in  unsigned(6 downto 0);
      bus_writeMask : in  std_logic_vector(3 downto 0);
      bus_dataWrite : in  std_logic_vector(31 downto 0);
      bus_read      : in  std_logic;
      bus_write     : in  std_logic;
      bus_dataRead  : out std_logic_vector(31 downto 0) := (others => '0');

      -- bank 2: channels 7-12, DPCR2, DICR2, DMACEN, DMACINTEN
      bus2_addr     : in  unsigned(6 downto 0);
      bus2_writeMask: in  std_logic_vector(3 downto 0);
      bus2_dataWrite: in  std_logic_vector(31 downto 0);
      bus2_read     : in  std_logic;
      bus2_write    : in  std_logic;
      bus2_dataRead : out std_logic_vector(31 downto 0) := (others => '0');

      -- RAM master.  ram_req is held until ram_gnt; the word is written on the
      -- granted cycle.  Reads are not used yet (no channel moves RAM -> device).
      ram_req       : out std_logic := '0';
      ram_addr      : out std_logic_vector(23 downto 0) := (others => '0');
      ram_wdata     : out std_logic_vector(31 downto 0) := (others => '0');
      ram_gnt       : in  std_logic;

      -- device side for channel 3 (CDVD): a word is taken when both are high
      dev_valid     : in  std_logic := '0';
      dev_data      : in  std_logic_vector(31 downto 0) := (others => '0');
      dev_ready     : out std_logic := '0';

      -- to the INTC, bit 3
      irq           : out std_logic := '0';

      -- diagnostics for the host: which channel last ran and how many words
      dbg_channel   : out unsigned(3 downto 0) := (others => '0');
      dbg_words     : out unsigned(23 downto 0) := (others => '0');
      dbg_running   : out std_logic := '0'
   );
end entity;

architecture arch of iop_dma is

   type t_word  is array (0 to 12) of std_logic_vector(31 downto 0);
   signal madr, bcr, chcr, tadr : t_word := (others => (others => '0'));

   signal dpcr  : std_logic_vector(31 downto 0) := x"07654321";
   signal dpcr2 : std_logic_vector(31 downto 0) := x"07654321";
   signal dicr_lo, dicr2_lo   : std_logic_vector(15 downto 0) := (others => '0');
   signal dicr_en, dicr2_en   : std_logic_vector(7 downto 0)  := (others => '0');  -- 16-22 enable, 23 master
   signal dicr_fl, dicr2_fl   : std_logic_vector(6 downto 0)  := (others => '0');  -- 24-30 flags
   signal dmacen    : std_logic_vector(31 downto 0) := (others => '0');
   signal dmacinten : std_logic_vector(31 downto 0) := (others => '0');

   -- transfer engine
   type t_state is (IDLE, RUN, FINISH);
   signal state    : t_state := IDLE;
   signal ch       : integer range 0 to 12 := 0;
   signal cur_addr : unsigned(23 downto 0) := (others => '0');
   signal words    : unsigned(23 downto 0) := (others => '0');
   signal decr     : std_logic := '0';

   function master_flag(en : std_logic_vector(7 downto 0);
                        fl : std_logic_vector(6 downto 0);
                        lo : std_logic_vector(15 downto 0)) return std_logic is
   begin
      if (lo(15) = '1') then return '1'; end if;                 -- force IRQ
      if (en(7) = '1' and (en(6 downto 0) and fl) /= "0000000") then return '1'; end if;
      return '0';
   end function;

   function lanes(old_v, new_v : std_logic_vector(31 downto 0);
                  m : std_logic_vector(3 downto 0)) return std_logic_vector is
      variable r : std_logic_vector(31 downto 0);
   begin
      r := old_v;
      for i in 0 to 3 loop
         if (m(i) = '1') then r(8*i+7 downto 8*i) := new_v(8*i+7 downto 8*i); end if;
      end loop;
      return r;
   end function;

   -- word count for SyncMode 0: BCR(15:0), with 0 meaning 0x10000
   function burst_words(b : std_logic_vector(31 downto 0)) return unsigned is
   begin
      if (b(15 downto 0) = x"0000") then return to_unsigned(16#10000#, 24); end if;
      return resize(unsigned(b(15 downto 0)), 24);
   end function;

begin

   irq         <= master_flag(dicr_en, dicr_fl, dicr_lo)
               or master_flag(dicr2_en, dicr2_fl, dicr2_lo);
   dbg_channel <= to_unsigned(ch, 4);
   dbg_words   <= words;
   dbg_running <= '1' when state /= IDLE else '0';
   -- dev_ready means "this word is taken", not "I am listening". A word is
   -- only consumed when the RAM write for it is granted, so gating on the
   -- state alone let the device advance faster than the DMA consumed and the
   -- word count never reached zero -- a stall, not a data error.
   dev_ready   <= '1' when (state = RUN and ch = 3 and ram_gnt = '1') else '0';

   process (clk1x)
      variable idx   : integer range 0 to 12;
      variable reg   : integer range 0 to 3;
      variable wr    : std_logic_vector(31 downto 0);
      variable start : integer range -1 to 12;
      -- The CHCR value being written, not the one in the register: the signal
      -- assignment does not land until the next cycle, so reading chcr(start)
      -- here would give the previous contents. That cost a simulation: the
      -- decrement bit read as 0 and OTC walked upward through RAM.
      variable start_chcr : std_logic_vector(31 downto 0);
   begin
      if rising_edge(clk1x) then
         -- Per-cycle defaults, overridden further down: every one of these is
         -- re-asserted by the branch that wants it, so a request lasts exactly
         -- as long as its condition holds and needs no explicit clear.
         bus_dataRead  <= (others => '0');
         bus2_dataRead <= (others => '0');
         ram_req       <= '0';
         start         := -1;
         start_chcr    := (others => '0');

         -- ---------------------------------------------------------- reads
         if (bus_read = '1') then
            if (bus_addr < 16#70#) then
               idx := to_integer(bus_addr(6 downto 4));
               reg := to_integer(bus_addr(3 downto 2));
               case reg is
                  when 0 => bus_dataRead <= madr(idx);
                  when 1 => bus_dataRead <= bcr(idx);
                  when 2 => bus_dataRead <= chcr(idx);
                  when others => bus_dataRead <= tadr(idx);
               end case;
            elsif (bus_addr(3 downto 2) = "00") then          -- 0xF0 DPCR
               bus_dataRead <= dpcr;
            else                                              -- 0xF4 DICR
               bus_dataRead <= master_flag(dicr_en, dicr_fl, dicr_lo)
                               & dicr_fl & dicr_en & dicr_lo;
            end if;
         end if;
         if (bus2_read = '1') then
            if (bus2_addr < 16#70#) then
               idx := 7 + to_integer(bus2_addr(6 downto 4));
               reg := to_integer(bus2_addr(3 downto 2));
               case reg is
                  when 0 => bus2_dataRead <= madr(idx);
                  when 1 => bus2_dataRead <= bcr(idx);
                  when 2 => bus2_dataRead <= chcr(idx);
                  when others => bus2_dataRead <= tadr(idx);
               end case;
            else
               case to_integer(bus2_addr(3 downto 2)) is
                  when 0 => bus2_dataRead <= dpcr2;
                  when 1 => bus2_dataRead <= master_flag(dicr2_en, dicr2_fl, dicr2_lo)
                                             & dicr2_fl & dicr2_en & dicr2_lo;
                  when 2 => bus2_dataRead <= dmacen;
                  when others => bus2_dataRead <= dmacinten;
               end case;
            end if;
         end if;

         if (reset = '1') then
            madr <= (others => (others => '0'));
            bcr  <= (others => (others => '0'));
            chcr <= (others => (others => '0'));
            tadr <= (others => (others => '0'));
            dpcr <= x"07654321"; dpcr2 <= x"07654321";
            dicr_lo <= (others => '0'); dicr_en <= (others => '0'); dicr_fl <= (others => '0');
            dicr2_lo <= (others => '0'); dicr2_en <= (others => '0'); dicr2_fl <= (others => '0');
            dmacen <= (others => '0'); dmacinten <= (others => '0');
            state <= IDLE;
         else
            -- ------------------------------------------------------- writes
            if (bus_write = '1') then
               wr := lanes(x"00000000", bus_dataWrite, bus_writeMask);
               if (bus_addr < 16#70#) then
                  idx := to_integer(bus_addr(6 downto 4));
                  reg := to_integer(bus_addr(3 downto 2));
                  case reg is
                     when 0 => madr(idx) <= lanes(madr(idx), bus_dataWrite, bus_writeMask);
                     when 1 => bcr(idx)  <= lanes(bcr(idx),  bus_dataWrite, bus_writeMask);
                     when 2 =>
                        chcr(idx) <= lanes(chcr(idx), bus_dataWrite, bus_writeMask);
                        -- a channel starts when start/busy is set and DPCR enables it
                        if (wr(24) = '1' and dpcr(idx*4+3) = '1') then
                           start := idx; start_chcr := wr;
                        end if;
                     when others => tadr(idx) <= lanes(tadr(idx), bus_dataWrite, bus_writeMask);
                  end case;
               elsif (bus_addr(3 downto 2) = "00") then
                  dpcr <= lanes(dpcr, bus_dataWrite, bus_writeMask);
               else
                  -- DICR: 0-15 stored, 16-23 stored, 24-30 write-one-to-clear
                  if (bus_writeMask(0) = '1') then dicr_lo(7 downto 0)  <= bus_dataWrite(7 downto 0);  end if;
                  if (bus_writeMask(1) = '1') then dicr_lo(15 downto 8) <= bus_dataWrite(15 downto 8); end if;
                  if (bus_writeMask(2) = '1') then dicr_en <= bus_dataWrite(23 downto 16); end if;
                  if (bus_writeMask(3) = '1') then dicr_fl <= dicr_fl and not bus_dataWrite(30 downto 24); end if;
               end if;
            end if;

            if (bus2_write = '1') then
               wr := lanes(x"00000000", bus2_dataWrite, bus2_writeMask);
               if (bus2_addr < 16#70#) then
                  idx := 7 + to_integer(bus2_addr(6 downto 4));
                  reg := to_integer(bus2_addr(3 downto 2));
                  case reg is
                     when 0 => madr(idx) <= lanes(madr(idx), bus2_dataWrite, bus2_writeMask);
                     when 1 => bcr(idx)  <= lanes(bcr(idx),  bus2_dataWrite, bus2_writeMask);
                     when 2 =>
                        chcr(idx) <= lanes(chcr(idx), bus2_dataWrite, bus2_writeMask);
                        if (wr(24) = '1' and dpcr2((idx-7)*4+3) = '1') then
                           start := idx; start_chcr := wr;
                        end if;
                     when others => tadr(idx) <= lanes(tadr(idx), bus2_dataWrite, bus2_writeMask);
                  end case;
               else
                  case to_integer(bus2_addr(3 downto 2)) is
                     when 0 => dpcr2 <= lanes(dpcr2, bus2_dataWrite, bus2_writeMask);
                     when 1 =>
                        if (bus2_writeMask(0) = '1') then dicr2_lo(7 downto 0)  <= bus2_dataWrite(7 downto 0);  end if;
                        if (bus2_writeMask(1) = '1') then dicr2_lo(15 downto 8) <= bus2_dataWrite(15 downto 8); end if;
                        if (bus2_writeMask(2) = '1') then dicr2_en <= bus2_dataWrite(23 downto 16); end if;
                        if (bus2_writeMask(3) = '1') then dicr2_fl <= dicr2_fl and not bus2_dataWrite(30 downto 24); end if;
                     when 2 => dmacen    <= lanes(dmacen, bus2_dataWrite, bus2_writeMask);
                     when others => dmacinten <= lanes(dmacinten, bus2_dataWrite, bus2_writeMask);
                  end case;
               end if;
            end if;

            -- ---------------------------------------------------- transfers
            case state is
               when IDLE =>
                  if (start >= 0) then
                     ch       <= start;
                     cur_addr <= unsigned(madr(start)(23 downto 0));
                     words    <= burst_words(bcr(start));
                     decr     <= start_chcr(1);
                     if (start = 6 or start = 3) then
                        state <= RUN;                  -- channels with a data path
                     else
                        state <= FINISH;               -- registers only, complete at once
                     end if;
                  end if;

               when RUN =>
                  if (words = 0) then
                     state <= FINISH;
                  elsif (ch = 6) then
                     -- OTC: walk backwards writing the address of the previous
                     -- entry; the last word written is the end marker.
                     ram_req   <= '1';
                     ram_addr  <= std_logic_vector(cur_addr);
                     if (words = 1) then
                        ram_wdata <= x"00FFFFFF";
                     else
                        ram_wdata <= x"00" & std_logic_vector(cur_addr(23 downto 2) - 1) & "00";
                     end if;
                     if (ram_gnt = '1') then
                        words    <= words - 1;
                        if (decr = '1') then cur_addr <= cur_addr - 4;
                        else                 cur_addr <= cur_addr + 4; end if;
                     end if;
                  elsif (ch = 3) then
                     -- CDVD: take a word from the device when it offers one
                     if (dev_valid = '1') then
                        ram_req   <= '1';
                        ram_addr  <= std_logic_vector(cur_addr);
                        ram_wdata <= dev_data;
                        if (ram_gnt = '1') then
                           words    <= words - 1;
                           if (decr = '1') then cur_addr <= cur_addr - 4;
                           else                 cur_addr <= cur_addr + 4; end if;
                        end if;
                     end if;
                  end if;

               when FINISH =>
                  madr(ch) <= x"00" & std_logic_vector(cur_addr);
                  chcr(ch) <= chcr(ch) and x"FEFFFFFF";       -- clear start/busy (24)
                  if (ch <= 6) then
                     dicr_fl(ch)  <= '1';
                  else
                     dicr2_fl(ch - 7) <= '1';
                  end if;
                  state <= IDLE;
            end case;
         end if;
      end if;
   end process;

end architecture;
