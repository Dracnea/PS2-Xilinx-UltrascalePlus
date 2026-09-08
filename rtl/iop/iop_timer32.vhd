-- iop_timer32.vhd -- IOP timers 3, 4 and 5: the PS2 additions to the PSX's
-- three 16-bit root counters, 32 bits wide, at 0x1F801480 + n*0x10
-- (COUNT +0, MODE +4, TARGET +8).  Modelled on PSX_MiSTer's timer.vhd so the
-- two blocks behave alike; mode bits per psx-spx / PCSX2 IopCounters:
--   3  reset COUNT on target         4  IRQ on target      5  IRQ on overflow
--   6  IRQ repeat (0 = one-shot)     7  IRQ toggle (0 = pulse)
--   8  external clock (timer 3: hblank; timers 4/5: none, counts sysclk)
--  10  IRQ request flag (0 = requested), set to 1 by a MODE write
--  11  reached target (cleared on MODE read)   12  reached 0xFFFFFFFF (same)
--  13-14  prescaler, timers 4/5 only: 01 = /8, 10 = /16, 11 = /256
-- Bits 0-2 (gate) are stored but not acted on.
--
-- NOTE (unverified): gate modes and the exact prescaler bit positions are
-- from emulator source (PCSX2 IopCounters.cpp), not measured on an IOP.
-- Verify by: the IOP kernel's timrman / a known homebrew timer test.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity iop_timer32 is
   port
   (
      clk1x         : in  std_logic;
      ce            : in  std_logic;
      reset         : in  std_logic;
      hblank        : in  std_logic;
      irqRequest3   : out std_logic := '0';
      irqRequest4   : out std_logic := '0';
      irqRequest5   : out std_logic := '0';
      bus_addr      : in  unsigned(5 downto 0);
      bus_dataWrite : in  std_logic_vector(31 downto 0);
      bus_read      : in  std_logic;
      bus_write     : in  std_logic;
      bus_dataRead  : out std_logic_vector(31 downto 0)
   );
end entity;

architecture arch of iop_timer32 is
   type t_timer is record
      count     : unsigned(31 downto 0);
      mode      : unsigned(15 downto 0);
      target    : unsigned(31 downto 0);
      irqDone   : std_logic;
      blockNext : std_logic;
      prescale  : unsigned(7 downto 0);
   end record;
   type t_timers is array (0 to 2) of t_timer;
   signal t : t_timers := (others => ((others => '0'), (others => '0'), (others => '0'), '0', '0', (others => '0')));
   signal hblank_1 : std_logic := '0';
   signal irq_q    : std_logic_vector(2 downto 0) := (others => '0');
begin

   irqRequest3 <= irq_q(0);
   irqRequest4 <= irq_q(1);
   irqRequest5 <= irq_q(2);

   process (clk1x)
      variable channel : integer range 0 to 3;
      variable tick    : std_logic;
      variable newIRQ  : std_logic;
      variable div     : unsigned(7 downto 0);
   begin
      if rising_edge(clk1x) then
         bus_dataRead <= (others => '0');
         if (reset = '1') then
            for i in 0 to 2 loop
               t(i).count <= (others => '0'); t(i).mode <= (others => '0'); t(i).target <= (others => '0');
               t(i).mode(10) <= '1';   -- no request pending; 0 here would pulse the IRQ line once after reset
               t(i).irqDone <= '0'; t(i).blockNext <= '0'; t(i).prescale <= (others => '0');
            end loop;
            irq_q <= (others => '0');
         elsif (ce = '1') then
            hblank_1 <= hblank;
            for i in 0 to 2 loop
               if (t(i).mode(7) = '0') then
                  t(i).mode(10) <= '1';                                   -- pulse mode: request lasts one cycle
               end if;
               -- tick source
               tick := '1';
               if (i = 0) then
                  if (t(i).mode(8) = '1') then
                     tick := hblank and not hblank_1;
                  end if;
               else
                  case (t(i).mode(14 downto 13)) is
                     when "01"   => div := to_unsigned(7, 8);
                     when "10"   => div := to_unsigned(15, 8);
                     when "11"   => div := to_unsigned(255, 8);
                     when others => div := to_unsigned(0, 8);
                  end case;
                  if (t(i).prescale = div) then
                     t(i).prescale <= (others => '0');
                  else
                     t(i).prescale <= t(i).prescale + 1;
                     tick := '0';
                  end if;
               end if;
               -- count
               t(i).blockNext <= '0';
               if (tick = '1' and t(i).blockNext = '0') then
                  t(i).count <= t(i).count + 1;
                  newIRQ := '0';
                  if (t(i).count = t(i).target) then
                     t(i).mode(11) <= '1';
                     if (t(i).mode(4) = '1') then newIRQ := '1'; end if;
                     if (t(i).mode(3) = '1') then
                        t(i).count     <= (others => '0');
                        t(i).blockNext <= '1';
                     end if;
                  end if;
                  if (t(i).count = x"FFFFFFFF") then
                     t(i).mode(12) <= '1';
                     if (t(i).mode(5) = '1') then newIRQ := '1'; end if;
                  end if;
                  if (t(i).irqDone = '1' and t(i).mode(6) = '0') then
                     newIRQ := '0';
                  end if;
                  if (newIRQ = '1') then
                     t(i).irqDone <= '1';
                     if (t(i).mode(7) = '1') then
                        t(i).mode(10) <= not t(i).mode(10);
                     else
                        t(i).mode(10) <= '0';
                     end if;
                  end if;
               end if;
               -- the interrupt line follows the request flag (active low in the register)
               irq_q(i) <= not t(i).mode(10);
            end loop;
            -- bus
            channel := to_integer(bus_addr(5 downto 4));
            if (bus_read = '1' and channel < 3) then
               case (bus_addr(3 downto 0)) is
                  when x"0"   => bus_dataRead <= std_logic_vector(t(channel).count);
                  when x"4"   => bus_dataRead <= x"0000" & std_logic_vector(t(channel).mode);
                                 t(channel).mode(12 downto 11) <= "00";
                  when x"8"   => bus_dataRead <= std_logic_vector(t(channel).target);
                  when others => null;
               end case;
            end if;
            if (bus_write = '1' and channel < 3) then
               case (bus_addr(3 downto 0)) is
                  when x"0"   => t(channel).count <= unsigned(bus_dataWrite);
                                 t(channel).blockNext <= '1';
                  when x"4"   => t(channel).mode( 9 downto  0) <= unsigned(bus_dataWrite( 9 downto  0));
                                 t(channel).mode(15 downto 13) <= unsigned(bus_dataWrite(15 downto 13));
                                 t(channel).mode(10) <= '1';
                                 t(channel).irqDone   <= '0';
                                 t(channel).count     <= (others => '0');
                                 t(channel).prescale  <= (others => '0');
                                 t(channel).blockNext <= '1';
                  when x"8"   => t(channel).target <= unsigned(bus_dataWrite);
                  when others => null;
               end case;
            end if;
         end if;
      end if;
   end process;

end architecture;
