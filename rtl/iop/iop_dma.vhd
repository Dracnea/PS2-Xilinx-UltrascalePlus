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

      -- RAM master.  ram_req is held until ram_gnt; a write completes on the
      -- granted cycle.  A read is two-sided: the grant only means the access
      -- was issued, and the word arrives later on ram_rvalid.  SIF0 is the
      -- first channel that moves RAM -> device and so the first to need it.
      ram_req       : out std_logic := '0';
      ram_rnw       : out std_logic := '0';
      ram_rdata     : in  std_logic_vector(31 downto 0) := (others => '0');
      ram_rvalid    : in  std_logic := '0';
      ram_addr      : out std_logic_vector(23 downto 0) := (others => '0');
      ram_wdata     : out std_logic_vector(31 downto 0) := (others => '0');
      ram_gnt       : in  std_logic;

      -- device side for channel 3 (CDVD): a word is taken when both are high
      dev_valid     : in  std_logic := '0';
      dev_data      : in  std_logic_vector(31 downto 0) := (others => '0');
      dev_ready     : out std_logic := '0';

      -- device side for channel 10 (SIF1, EE -> IOP).  Unlike every other
      -- channel the destination and the length are not in MADR and BCR: SIF1
      -- takes a four-word tag from the head of the stream itself (PCSX2
      -- Sif1.cpp), so the channel reads the tag before it knows where the data
      -- goes.  See docs/sif.md.
      -- Bring-up aid: start channel 10 without a CHCR write.  Whether the BIOS
      -- ever arms SIF1 is an open question (docs/sif.md), and without this a
      -- silent channel cannot be told apart from a broken data path.  It is a
      -- host-driven pulse and nothing in the console uses it.
      sif1_kick     : in  std_logic := '0';

      -- device side for channel 9 (SIF0, IOP -> EE).  The tag is not in the
      -- stream this time: it sits in IOP memory at TADR, so this is the one
      -- channel that has to read RAM.  Four words of the EE's own tag, taken
      -- from TADR+8, go into the stream ahead of the data, which is what the
      -- EE reads to learn where to put it (PCSX2 Sif0.cpp).
      sif0_we       : out std_logic := '0';
      sif0_data     : out std_logic_vector(31 downto 0) := (others => '0');
      sif0_full     : in  std_logic := '0';
      dbg_sif0_addr : out std_logic_vector(23 downto 0) := (others => '0');
      dbg_sif0_len  : out std_logic_vector(23 downto 0) := (others => '0');
      dbg_sif0_tags : out unsigned(15 downto 0) := (others => '0');

      sif1_valid    : in  std_logic := '0';
      sif1_data     : in  std_logic_vector(31 downto 0) := (others => '0');
      sif1_ready    : out std_logic := '0';

      -- the tag as it was consumed, for the host to check its own framing
      dbg_sif1_addr : out std_logic_vector(23 downto 0) := (others => '0');
      dbg_sif1_len  : out std_logic_vector(23 downto 0) := (others => '0');
      dbg_sif1_tags : out unsigned(15 downto 0) := (others => '0');

      -- to the INTC, bit 3
      irq           : out std_logic := '0';

      -- diagnostics for the host: which channel last ran and how many words
      dbg_channel   : out unsigned(3 downto 0) := (others => '0');
      dbg_words     : out unsigned(23 downto 0) := (others => '0');
      dbg_running   : out std_logic := '0';

      -- A window onto one channel's registers, so the host can see what the
      -- BIOS programmed rather than infer it.  Whether SIFCMD arms SIF1 at
      -- boot, and in normal or chain mode, is a question about CHCR and TADR
      -- that nothing else here can answer.
      -- The controller's own enables and flags.  Whether a completed transfer
      -- becomes an interrupt is decided here, and nothing outside could see it:
      -- a channel that finishes and a handler that runs are different events.
      dbg_dpcr      : out std_logic_vector(31 downto 0) := (others => '0');
      dbg_dicr      : out std_logic_vector(31 downto 0) := (others => '0');
      dbg_dpcr2     : out std_logic_vector(31 downto 0) := (others => '0');
      dbg_dicr2     : out std_logic_vector(31 downto 0) := (others => '0');
      dbg_irq       : out std_logic := '0';

      dbg_sel       : in  unsigned(3 downto 0) := (others => '0');
      dbg_madr      : out std_logic_vector(31 downto 0) := (others => '0');
      dbg_bcr       : out std_logic_vector(31 downto 0) := (others => '0');
      dbg_chcr      : out std_logic_vector(31 downto 0) := (others => '0');
      dbg_tadr      : out std_logic_vector(31 downto 0) := (others => '0')
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
   type t_state is (IDLE, SIF0RUN, SIF1RUN, RUN, FINISH);
   signal state    : t_state := IDLE;
   signal ch       : integer range 0 to 12 := 0;
   signal cur_addr : unsigned(23 downto 0) := (others => '0');
   signal words    : unsigned(23 downto 0) := (others => '0');
   signal decr     : std_logic := '0';
   signal tagcount : unsigned(15 downto 0) := (others => '0');
   -- Channel 10 keeps its own state rather than borrowing the engine's.  It is
   -- armed for long stretches with nothing arriving, and the engine runs one
   -- transfer at a time: parking it in the shared registers would stop CDVD and
   -- OTC dead for as long as the EE stayed quiet.
   -- Channel 9's own state, for the same reason channel 10 has one: it reads
   -- IOP RAM, and a read is two-sided -- the grant says the access went out,
   -- the word comes back later -- so it cannot borrow the engine's registers.
   signal s0_armed  : std_logic := '0';
   signal s0_phase  : std_logic := '0';              -- 0 reading the tag, 1 moving data
   signal s0_issued : std_logic := '0';              -- a read is out, waiting for the word
   signal s0_tw     : integer range 0 to 5 := 0;
   signal s0_addr   : unsigned(23 downto 0) := (others => '0');
   signal s0_words  : unsigned(23 downto 0) := (others => '0');
   signal s0_tadr   : unsigned(23 downto 0) := (others => '0');
   signal s0_tags   : unsigned(15 downto 0) := (others => '0');

   signal s1_armed : std_logic := '0';
   signal s1_phase : std_logic := '0';               -- 0 reading the tag, 1 moving data
   signal s1_tagw  : integer range 0 to 3 := 0;
   signal s1_addr  : unsigned(23 downto 0) := (others => '0');
   signal s1_words : unsigned(23 downto 0) := (others => '0');

   -- The master enable is passed in rather than taken from `en`, because there
   -- is only one of it and it does not live in both banks.  DICR bit 23 is the
   -- master channel interrupt enable for **DICR and DICR2 alike**; DICR2 bit 23
   -- is unused (ps2tek, IOP DMA).  Reading it out of DICR2 -- which is what
   -- this did -- means no channel from 7 to 12 can ever raise an interrupt:
   -- SIF0, SIF1, SIO2in, SIO2out, DEV9 and SPU2's second core, all silent,
   -- while bank 1 works and hides it.  The BIOS sets DICR to 0x00800000 and
   -- DICR2 to 0x000c0400, which is exactly this arrangement.
   function master_flag(master : std_logic;
                        en : std_logic_vector(7 downto 0);
                        fl : std_logic_vector(6 downto 0);
                        lo : std_logic_vector(15 downto 0)) return std_logic is
   begin
      if (lo(15) = '1') then return '1'; end if;                 -- force IRQ
      if (master = '1' and (en(6 downto 0) and fl) /= "0000000") then return '1'; end if;
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

   irq         <= master_flag(dicr_en(7), dicr_en, dicr_fl, dicr_lo)
               or master_flag(dicr_en(7), dicr2_en, dicr2_fl, dicr2_lo);
   dbg_channel <= to_unsigned(ch, 4);
   dbg_madr <= madr(to_integer(dbg_sel)) when dbg_sel <= 12 else (others => '0');
   dbg_bcr  <= bcr (to_integer(dbg_sel)) when dbg_sel <= 12 else (others => '0');
   dbg_chcr <= chcr(to_integer(dbg_sel)) when dbg_sel <= 12 else (others => '0');
   dbg_tadr <= tadr(to_integer(dbg_sel)) when dbg_sel <= 12 else (others => '0');
   dbg_words   <= words;
   dbg_running <= '1' when state /= IDLE else '0';
   -- dev_ready means "this word is taken", not "I am listening". A word is
   -- only consumed when the RAM write for it is granted, so gating on the
   -- state alone let the device advance faster than the DMA consumed and the
   -- word count never reached zero -- a stall, not a data error.
   dev_ready   <= '1' when (state = RUN and ch = 3 and ram_gnt = '1') else '0';
   -- "this word is taken", as with dev_ready.  Never asserted without a word
   -- to take: an unconditional ready would pop the stream while it was empty
   -- and make every idle cycle look like a transfer.
   sif1_ready  <= '1' when (state = SIF1RUN and sif1_valid = '1'
                            and not (s1_phase = '1' and s1_words = 0)
                            and (s1_phase = '0' or ram_gnt = '1')) else '0';
   dbg_sif1_tags <= tagcount;
   dbg_sif0_tags <= s0_tags;
   dbg_dpcr  <= dpcr;
   dbg_dpcr2 <= dpcr2;
   dbg_dicr  <= master_flag(dicr_en(7), dicr_en, dicr_fl, dicr_lo) & dicr_fl & dicr_en & dicr_lo;
   dbg_dicr2 <= master_flag(dicr_en(7), dicr2_en, dicr2_fl, dicr2_lo) & dicr2_fl & dicr2_en & dicr2_lo;
   dbg_irq   <= master_flag(dicr_en(7), dicr_en, dicr_fl, dicr_lo)
             or master_flag(dicr_en(7), dicr2_en, dicr2_fl, dicr2_lo);

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
         ram_rnw       <= '0';
         sif0_we       <= '0';
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
               bus_dataRead <= master_flag(dicr_en(7), dicr_en, dicr_fl, dicr_lo)
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
                  when 1 => bus2_dataRead <= master_flag(dicr_en(7), dicr2_en, dicr2_fl, dicr2_lo)
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
            -- Channel 10's state lives outside the shared engine, so it has to
            -- be reset explicitly.  Left out, a reset returns every register to
            -- zero while the channel stays armed mid-tag, and the next word the
            -- EE sends is read as the middle of a transfer that no longer
            -- exists.  tagcount is deliberately not cleared: it counts tags
            -- since the bitstream was loaded, which is what makes it useful
            -- across a reset.
            s0_armed <= '0'; s0_phase <= '0'; s0_issued <= '0'; s0_tw <= 0;
            s0_addr  <= (others => '0'); s0_words <= (others => '0');
            s1_armed <= '0'; s1_phase <= '0'; s1_tagw <= 0;
            s1_addr  <= (others => '0'); s1_words <= (others => '0');
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
                           if (idx = 10) then
                              s1_armed <= '1';       -- wait for the EE, off the engine
                              s1_phase <= '0';
                              s1_tagw  <= 0;
                           elsif (idx = 9) then
                              s0_armed  <= '1';
                              s0_phase  <= '0';
                              s0_issued <= '0';
                              s0_tw     <= 0;
                              s0_tadr   <= unsigned(tadr(9)(23 downto 0));
                           else
                              start := idx; start_chcr := wr;
                           end if;
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
                  elsif (sif1_kick = '1') then
                     s1_armed <= '1';
                     s1_phase <= '0';
                     s1_tagw  <= 0;
                  elsif (s1_armed = '1' and sif1_valid = '1') then
                     state <= SIF1RUN;                 -- only once there is something
                  elsif (s0_armed = '1' and sif0_full = '0') then
                     state <= SIF0RUN;                 -- only once there is room
                  end if;

               when SIF0RUN =>
                  if (s0_phase = '1' and s0_words = 0 and s0_issued = '0') then
                     tadr(9)     <= x"00" & std_logic_vector(s0_tadr + 16);
                     madr(9)     <= x"00" & std_logic_vector(s0_addr);
                     chcr(9)     <= chcr(9) and x"FEFFFFFF";
                     dicr2_fl(2) <= '1';               -- channel 9 -> DICR2 bit 2
                     s0_armed    <= '0';
                     s0_phase    <= '0';
                     s0_tw       <= 0;
                     s0_tags     <= s0_tags + 1;
                     state       <= IDLE;
                  elsif (s0_issued = '1') then
                     -- The word the port owes us.  A read is the only access
                     -- here whose grant is not its completion.
                     if (ram_rvalid = '1') then
                        s0_issued <= '0';
                        if (s0_phase = '0') then
                           case s0_tw is
                              when 0 =>
                                 s0_addr       <= unsigned(ram_rdata(23 downto 0));
                                 dbg_sif0_addr <= ram_rdata(23 downto 0);
                              when 1 =>
                                 s0_words     <= x"0" & unsigned(ram_rdata(19 downto 0));
                                 dbg_sif0_len <= x"0" & ram_rdata(19 downto 0);
                              when others =>
                                 sif0_we   <= '1';     -- the EE's half of the tag
                                 sif0_data <= ram_rdata;
                           end case;
                           if (s0_tw = 5) then s0_phase <= '1';
                           else                s0_tw    <= s0_tw + 1; end if;
                        else
                           sif0_we   <= '1';
                           sif0_data <= ram_rdata;
                           s0_words  <= s0_words - 1;
                           s0_addr   <= s0_addr + 4;
                        end if;
                     end if;
                  elsif (sif0_full = '1') then
                     state <= IDLE;                    -- yield until the host drains
                  else
                     ram_req <= '1';
                     ram_rnw <= '1';
                     if (s0_phase = '0') then
                        ram_addr <= std_logic_vector(s0_tadr + to_unsigned(s0_tw * 4, 24));
                     else
                        ram_addr <= std_logic_vector(s0_addr);
                     end if;
                     if (ram_gnt = '1') then s0_issued <= '1'; end if;
                  end if;

               when SIF1RUN =>
                  -- Completion first: the transfer ends on its word count, not
                  -- on the stream running dry, and the word that follows a
                  -- finished transfer belongs to the next tag.
                  if (s1_phase = '1' and s1_words = 0) then
                     madr(10)    <= x"00" & std_logic_vector(s1_addr);
                     chcr(10)    <= chcr(10) and x"FEFFFFFF";
                     dicr2_fl(3) <= '1';               -- channel 10 -> DICR2 bit 3
                     s1_armed    <= '0';
                     s1_phase    <= '0';
                     s1_tagw     <= 0;
                     state       <= IDLE;
                  elsif (sif1_valid = '0') then
                     state <= IDLE;                    -- yield; keep what we have
                  elsif (s1_phase = '0') then
                     -- Four words: the IOP address, the length, then the EE's
                     -- own DMA tag, which is the EE's business and not ours.
                     -- The masks are PCSX2's: 24 bits of address, and a length
                     -- whose low two bits are dropped.
                     case s1_tagw is
                        when 0 =>
                           s1_addr       <= unsigned(sif1_data(23 downto 0));
                           dbg_sif1_addr <= sif1_data(23 downto 0);
                        when 1 =>
                           s1_words     <= unsigned(sif1_data(23 downto 0)) and x"0FFFFC";
                           dbg_sif1_len <= std_logic_vector(unsigned(sif1_data(23 downto 0)) and x"0FFFFC");
                        when others => null;
                     end case;
                     if (s1_tagw = 3) then
                        tagcount <= tagcount + 1;
                        s1_phase <= '1';
                     else
                        s1_tagw <= s1_tagw + 1;
                     end if;
                  else
                     ram_req   <= '1';
                     ram_addr  <= std_logic_vector(s1_addr);
                     ram_wdata <= sif1_data;
                     if (ram_gnt = '1') then
                        s1_words <= s1_words - 1;
                        s1_addr  <= s1_addr + 4;       -- a tag address only counts up
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
