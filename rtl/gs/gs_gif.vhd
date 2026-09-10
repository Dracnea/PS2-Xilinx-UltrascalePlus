-- gs_gif.vhd -- the GIF: GIFtag decode, the general register file, and
-- host-to-local transfers.
--
-- This is the slice of the Graphics Synthesizer that can be checked without
-- drawing anything, and it is deliberately the first one built, for the same
-- reason the R5900's integer core came before its FPU: it produces state that
-- a reference model can be diffed against, so the harness is working before
-- there is anything hard to debug.  sim/gs/gs_ref.py is that model.
--
-- What it does:
--
--   * decodes a GIFtag and walks its register descriptor list, in PACKED,
--     REGLIST and IMAGE modes
--   * holds the 64 general registers, written either by a descriptor or
--     through the A+D path, which carries its own address
--   * runs a host-to-local transfer: BITBLTBUF, TRXPOS and TRXREG set it up,
--     a write to TRXDIR starts it, and the data arrives either through HWREG
--     or as an IMAGE-mode packet
--
-- The local memory swizzle is the part worth reading.  A PSMCT32 pixel's word
-- address is
--
--     page(8:0) & x5 & y4 & x4 & y3 & x3 & y2 & y1 & x2 & x1 & y0 & x0
--
-- -- the low eleven bits are nothing but the low bits of x and y interleaved in
-- a fixed order.  The GS manual presents this as three tables (page, block and
-- column), and PCSX2 stores two of them as literal arrays, but in hardware it
-- is a wire permutation and costs nothing at all.  Only the page number needs
-- arithmetic.  tools/gs/xcheck_swizzle.py checks the arithmetic form of this
-- against PCSX2 exhaustively.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity gs_gif is
   port
   (
      clk       : in  std_logic;
      reset     : in  std_logic;

      -- GIF input: one quadword at a time
      gif_valid : in  std_logic;
      gif_data  : in  std_logic_vector(127 downto 0);
      gif_ready : out std_logic;

      -- local memory write port, shaped for gs_lmem
      wr_en     : out std_logic := '0';
      wr_addr   : out std_logic_vector(16 downto 0) := (others => '0');
      wr_data   : out std_logic_vector(255 downto 0) := (others => '0');
      wr_be     : out std_logic_vector(31 downto 0) := (others => '0');

      -- for the testbench: read any general register, and count writes to
      -- addresses the manual does not define rather than inventing behaviour
      dbg_sel     : in  unsigned(6 downto 0) := (others => '0');
      dbg_reg     : out std_logic_vector(63 downto 0) := (others => '0');
      dbg_unknown : out unsigned(15 downto 0) := (others => '0')
   );
end entity;

architecture arch of gs_gif is
   type regfile_t is array (0 to 127) of std_logic_vector(63 downto 0);
   signal reg : regfile_t := (others => (others => '0'));

   signal unknown : unsigned(15 downto 0) := (others => '0');

   type state_t is (S_TAG, S_PACKED, S_REGLIST, S_IMAGE, S_PIXELS);
   signal state : state_t := S_TAG;

   -- the tag in flight
   signal t_nloop : unsigned(14 downto 0) := (others => '0');
   signal t_eop   : std_logic := '0';
   signal t_nreg  : unsigned(4 downto 0) := (others => '0');
   signal t_regs  : std_logic_vector(63 downto 0) := (others => '0');
   signal t_loop  : unsigned(14 downto 0) := (others => '0');
   signal t_ri    : unsigned(4 downto 0) := (others => '0');

   -- the host-to-local transfer
   signal x_active : std_logic := '0';
   signal x_bp     : unsigned(13 downto 0) := (others => '0');
   signal x_bw     : unsigned(5 downto 0) := (others => '0');
   signal x_psm    : unsigned(5 downto 0) := (others => '0');
   signal x_x0     : unsigned(10 downto 0) := (others => '0');
   signal x_w      : unsigned(11 downto 0) := (others => '0');
   signal x_cx     : unsigned(10 downto 0) := (others => '0');
   signal x_cy     : unsigned(10 downto 0) := (others => '0');
   signal x_left   : unsigned(23 downto 0) := (others => '0');  -- pixels remaining

   -- pixels waiting to be written, one per clock
   signal px_data  : std_logic_vector(127 downto 0) := (others => '0');
   signal px_n     : unsigned(2 downto 0) := (others => '0');
   signal px_ret   : state_t := S_TAG;

   -- Which register addresses the manual defines.  A write to anything else is
   -- counted, not performed: the alternative is to invent a behaviour and then
   -- be unable to tell an emulator bug from a game doing something odd.
   function defined(a : unsigned(6 downto 0)) return boolean is
   begin
      case to_integer(a) is
         when 16#00# to 16#0A# | 16#0C# | 16#0D#            => return true;
         when 16#14# to 16#1C#                              => return true;
         when 16#22#                                        => return true;
         when 16#34# to 16#37# | 16#3B# | 16#3D# | 16#3F#   => return true;
         when 16#40# to 16#4F#                              => return true;
         when 16#50# to 16#54#                              => return true;
         when 16#60# to 16#62#                              => return true;
         when others                                        => return false;
      end case;
   end function;

   -- PSMCT32 word address.  Everything below the page number is a permutation
   -- of the low bits of x and y; see the header.
   function pix_addr(bp : unsigned(13 downto 0); bw : unsigned(5 downto 0);
                     x, y : unsigned(10 downto 0)) return unsigned is
      variable page : unsigned(8 downto 0);
   begin
      page := resize(bp(13 downto 5) + resize(y(10 downto 5) * bw, 9)
                     + resize(x(10 downto 6), 9), 9);
      return page & x(5) & y(4) & x(4) & y(3) & x(3)
                  & y(2) & y(1) & x(2) & x(1) & y(0) & x(0);
   end function;
begin

   -- Combinational, because valid/ready only means anything if both sides agree
   -- on which edge the transfer happened.  A registered ready lags the state it
   -- describes by a cycle, and the producer then advances on an edge where
   -- nothing was taken -- which loses a quadword exactly when the consumer
   -- stops to do some work, which is the one case that matters.
   gif_ready <= '0' when reset = '1' else
                '0' when state = S_PIXELS else '1';

   dbg_reg     <= reg(to_integer(dbg_sel));
   dbg_unknown <= unknown;

   process (clk)
      variable qw      : std_logic_vector(127 downto 0);
      variable desc    : std_logic_vector(3 downto 0);
      variable w_addr  : unsigned(6 downto 0);
      variable w_data  : std_logic_vector(63 downto 0);
      variable w_do    : boolean;
      variable wa      : unsigned(19 downto 0);
      variable lane    : integer range 0 to 7;
      variable last    : boolean;
      variable vri     : unsigned(4 downto 0);
      variable vloop   : unsigned(14 downto 0);
      variable vdone   : boolean;
   begin
      if rising_edge(clk) then
         wr_en     <= '0';

         if reset = '1' then
            state    <= S_TAG;
            unknown  <= (others => '0');
            x_active <= '0';
            px_n     <= (others => '0');
            reg      <= (others => (others => '0'));

         else
            case state is

               when S_TAG =>
                  if gif_valid = '1' then
                     qw := gif_data;
                     t_nloop <= unsigned(qw(14 downto 0));
                     t_eop   <= qw(15);
                     t_regs  <= qw(127 downto 64);
                     if qw(63 downto 60) = "0000" then
                        t_nreg <= to_unsigned(16, 5);
                     else
                        t_nreg <= resize(unsigned(qw(63 downto 60)), 5);
                     end if;
                     t_loop <= (others => '0');
                     t_ri   <= (others => '0');
                     -- PRE loads PRIM ahead of the data, except in IMAGE mode
                     if qw(46) = '1' and qw(59 downto 58) /= "10" then
                        reg(0) <= std_logic_vector(resize(unsigned(qw(57 downto 47)), 64));
                     end if;
                     if unsigned(qw(14 downto 0)) = 0 then
                        state <= S_TAG;            -- an empty packet is just a tag
                     else
                        case qw(59 downto 58) is
                           when "00"   => state <= S_PACKED;
                           when "01"   => state <= S_REGLIST;
                           when "10"   => state <= S_IMAGE;
                           when others => state <= S_TAG;    -- "disable"
                        end case;
                     end if;
                  end if;

               when S_PACKED =>
                  if gif_valid = '1' then
                     qw   := gif_data;
                     desc := t_regs(to_integer(t_ri) * 4 + 3 downto to_integer(t_ri) * 4);

                     -- One descriptor decodes to at most one register write.
                     -- Keeping that a single path rather than a case per
                     -- register is what makes the A+D form -- which carries its
                     -- own address -- fall out as an ordinary case rather than
                     -- a second mechanism.
                     w_do   := true;
                     w_addr := to_unsigned(0, 7);
                     w_data := (others => '0');
                     case desc is
                        when x"0" => w_addr := to_unsigned(16#00#, 7);
                                     w_data := std_logic_vector(resize(unsigned(qw(10 downto 0)), 64));
                        when x"1" => w_addr := to_unsigned(16#01#, 7);
                                     w_data := x"00000000" & qw(103 downto 96) & qw(71 downto 64)
                                               & qw(39 downto 32) & qw(7 downto 0);
                        when x"2" => w_addr := to_unsigned(16#02#, 7); w_data := qw(63 downto 0);
                        when x"3" => w_addr := to_unsigned(16#03#, 7);
                                     w_data := x"00000000" & "00" & qw(45 downto 32)
                                               & "00" & qw(13 downto 0);
                        when x"4" => w_addr := to_unsigned(16#04#, 7);
                                     w_data := qw(107 downto 100) & qw(91 downto 68)
                                               & qw(47 downto 32) & qw(15 downto 0);
                        when x"5" => w_addr := to_unsigned(16#05#, 7);
                                     w_data := qw(95 downto 64)
                                               & qw(47 downto 32) & qw(15 downto 0);
                        when x"6" | x"7" | x"8" | x"9" | x"A" =>
                                     w_addr := resize(unsigned(desc), 7);
                                     w_data := qw(63 downto 0);
                        when x"C" => w_addr := to_unsigned(16#0C#, 7);
                                     w_data := qw(107 downto 100) & qw(91 downto 68)
                                               & qw(47 downto 32) & qw(15 downto 0);
                        when x"D" => w_addr := to_unsigned(16#0D#, 7);
                                     w_data := qw(95 downto 64)
                                               & qw(47 downto 32) & qw(15 downto 0);
                        when x"E" => w_addr := unsigned(qw(70 downto 64));
                                     w_data := qw(63 downto 0);
                        when others => w_do := false;      -- 0xF is NOP, 0xB reserved
                     end case;
                     if desc = x"B" then
                        unknown <= unknown + 1;
                     end if;

                     if w_do then
                        if not defined(w_addr) then
                           unknown <= unknown + 1;
                        else
                           reg(to_integer(w_addr)) <= w_data;
                           if w_addr = 16#53# and w_data(1 downto 0) = "00" then
                              -- TRXDIR: host-to-local.  The set-up registers
                              -- were written on earlier cycles, so reading them
                              -- here reads what the host put there.
                              x_active <= '1';
                              x_bp   <= unsigned(reg(16#50#)(45 downto 32));
                              x_bw   <= unsigned(reg(16#50#)(53 downto 48));
                              x_psm  <= unsigned(reg(16#50#)(61 downto 56));
                              x_x0   <= unsigned(reg(16#51#)(42 downto 32));
                              x_cx   <= unsigned(reg(16#51#)(42 downto 32));
                              x_cy   <= unsigned(reg(16#51#)(58 downto 48));
                              x_w    <= unsigned(reg(16#52#)(11 downto 0));
                              x_left <= resize(unsigned(reg(16#52#)(11 downto 0))
                                               * unsigned(reg(16#52#)(43 downto 32)), 24);
                           elsif w_addr = 16#54# then
                              -- HWREG: two PSMCT32 pixels of transfer data
                              px_data <= x"0000000000000000" & w_data;
                              px_n    <= to_unsigned(2, 3);
                           end if;
                        end if;
                     end if;

                     -- advance the descriptor and loop counters together
                     last := false;
                     if t_ri + 1 = t_nreg then
                        t_ri <= (others => '0');
                        if t_loop + 1 = t_nloop then
                           last := true;
                        else
                           t_loop <= t_loop + 1;
                        end if;
                     else
                        t_ri <= t_ri + 1;
                     end if;

                     if w_do and defined(w_addr) and w_addr = 16#54# then
                        px_ret <= S_PACKED;
                        if last then px_ret <= S_TAG; end if;
                        state  <= S_PIXELS;
                     elsif last then
                        state <= S_TAG;
                     end if;
                  end if;

               when S_REGLIST =>
                  -- Two registers per quadword.  The descriptor list is walked
                  -- once per register, not once per quadword: with NREG = 1 the
                  -- second half of a quadword is the *next loop iteration* and
                  -- uses descriptor 0 again.  Indexing it as descriptor 1 reads
                  -- past the end of the list and writes whatever register
                  -- happens to be named there, which is invisible until a
                  -- packet uses a short list -- and a short list is the common
                  -- case, since that is what REGLIST is for.
                  --
                  -- A+D is not meaningful here: there is no room for an
                  -- address, so it is counted rather than guessed at.
                  if gif_valid = '1' then
                     qw    := gif_data;
                     vri   := t_ri;
                     vloop := t_loop;
                     vdone := false;
                     for h in 0 to 1 loop
                        if not vdone then
                           desc := t_regs(to_integer(vri) * 4 + 3
                                          downto to_integer(vri) * 4);
                           if desc = x"E" or desc = x"B" then
                              unknown <= unknown + 1;
                           elsif desc /= x"F" then
                              if defined(resize(unsigned(desc), 7)) then
                                 reg(to_integer(unsigned(desc))) <=
                                    qw(64 * h + 63 downto 64 * h);
                              else
                                 unknown <= unknown + 1;
                              end if;
                           end if;
                           if vri + 1 = t_nreg then
                              vri := (others => '0');
                              if vloop + 1 = t_nloop then
                                 vdone := true;
                              else
                                 vloop := vloop + 1;
                              end if;
                           else
                              vri := vri + 1;
                           end if;
                        end if;
                     end loop;
                     t_ri   <= vri;
                     t_loop <= vloop;
                     if vdone then
                        state <= S_TAG;
                     end if;
                  end if;

               when S_IMAGE =>
                  if gif_valid = '1' then
                     px_data <= gif_data;
                     px_n    <= to_unsigned(4, 3);
                     if t_loop + 1 = t_nloop then
                        px_ret <= S_TAG;
                     else
                        px_ret <= S_IMAGE;
                     end if;
                     t_loop <= t_loop + 1;
                     state  <= S_PIXELS;
                  end if;

               when S_PIXELS =>
                  -- one pixel per clock into local memory
                  if px_n = 0 then
                     state <= px_ret;
                  else
                     if x_active = '1' and x_psm = 0 and x_left /= 0 then
                        wa   := pix_addr(x_bp, x_bw, x_cx, x_cy);
                        lane := to_integer(wa(2 downto 0));
                        wr_en   <= '1';
                        wr_addr <= std_logic_vector(wa(19 downto 3));
                        wr_data <= std_logic_vector(shift_left(
                                      resize(unsigned(px_data(31 downto 0)), 256),
                                      32 * lane));
                        wr_be   <= std_logic_vector(shift_left(
                                      resize(unsigned'(x"F"), 32), 4 * lane));
                        if x_cx + 1 = x_x0 + x_w then
                           x_cx <= x_x0;
                           x_cy <= x_cy + 1;
                        else
                           x_cx <= x_cx + 1;
                        end if;
                        x_left <= x_left - 1;
                     end if;
                     px_data <= x"00000000" & px_data(127 downto 32);
                     px_n    <= px_n - 1;
                  end if;

            end case;
         end if;
      end if;
   end process;

end architecture;
