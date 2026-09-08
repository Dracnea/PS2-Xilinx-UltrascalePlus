-- iop_intc.vhd -- the PS2 IOP interrupt controller (I_STAT / I_MASK / I_CTRL).
--
-- 32 sources on a 32-bit status/mask pair at 0x1F801070 / 0x1F801074, and the
-- global enable at 0x1F801078.  Bit numbers follow PS2SDK intrman.h:
--   0 VBLANK  1 SBUS   2 CDVD   3 DMA    4-6 RTC0-2 (timers 0-2)  7 SIO0
--   8 SIO1    9 SPU   10 PIO   11 EVBLANK  12 DVD  13 DEV9  14-16 RTC3-5
--  17 SIO2   18-21 HTR0-3  22 USB  23 EXTR  24 ILINK  25 FDMA
-- Semantics (PSX INTC extended to 32 bits, ps2tek / PCSX2 IopHw):
--   I_STAT: a source's rising edge sets its bit; a write ANDs the register
--           with the written value (write 0 to acknowledge).
--   I_MASK: read/write.
--   I_CTRL: bit 0 is the master enable.  A write sets it; a READ returns the
--           old value and clears it (this is how the IOP kernel's
--           CpuSuspendIntr works), so reads have a side effect here.
--   irqRequest = I_CTRL(0) and (I_STAT and I_MASK) /= 0.
--
-- NOTE (unverified): the read-clears-I_CTRL behaviour and the edge-triggered
-- I_STAT set are taken from documentation and emulator source, not measured
-- on an IOP.  Verify by: running the IOP kernel's intrman against this block.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity iop_intc is
   port
   (
      clk1x         : in  std_logic;
      ce            : in  std_logic;
      reset         : in  std_logic;
      irq_in        : in  std_logic_vector(31 downto 0);   -- level inputs, set on rising edge
      bus_addr      : in  unsigned(3 downto 0);
      bus_dataWrite : in  std_logic_vector(31 downto 0);
      bus_read      : in  std_logic;
      bus_write     : in  std_logic;
      bus_dataRead  : out std_logic_vector(31 downto 0) := (others => '0');
      irqRequest    : out std_logic := '0'
   );
end entity;

architecture arch of iop_intc is
   signal i_stat   : std_logic_vector(31 downto 0) := (others => '0');
   signal i_mask   : std_logic_vector(31 downto 0) := (others => '0');
   signal i_ctrl   : std_logic := '0';
   signal irq_last : std_logic_vector(31 downto 0) := (others => '0');
begin

   -- The memory mux ORs every peripheral's read data together (PSX_MiSTer
   -- memorymux.vhd, dataFromBusses), so this must be zero except in the cycle
   -- after a read strobe, exactly as the PSX irq.vhd does it.
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         bus_dataRead <= (others => '0');
         if (bus_read = '1') then
            case (bus_addr(3 downto 2)) is
               when "00"   => bus_dataRead <= i_stat;
               when "01"   => bus_dataRead <= i_mask;
               when "10"   => bus_dataRead <= (31 downto 1 => '0') & i_ctrl;
               when others => bus_dataRead <= (others => '1');
            end case;
         end if;
         if (reset = '1') then
            i_stat     <= (others => '0');
            i_mask     <= (others => '0');
            i_ctrl     <= '0';
            irq_last   <= irq_in;
            irqRequest <= '0';
         elsif (ce = '1') then
            irq_last   <= irq_in;
            irqRequest <= '0';
            if (i_ctrl = '1' and (i_stat and i_mask) /= x"00000000") then
               irqRequest <= '1';
            end if;
            -- rising edges set status bits; a bus write to I_STAT is applied
            -- in the same cycle, acknowledge first, then new edges
            if (bus_write = '1') then
               case (bus_addr(3 downto 2)) is
                  when "00"   => i_stat <= (i_stat and bus_dataWrite) or (irq_in and not irq_last);
                  when "01"   => i_mask <= bus_dataWrite;
                  when "10"   => i_ctrl <= bus_dataWrite(0);
                  when others => null;
               end case;
            else
               i_stat <= i_stat or (irq_in and not irq_last);
            end if;
            if (bus_read = '1' and bus_addr(3 downto 2) = "10") then
               i_ctrl <= '0';
            end if;
         end if;
      end if;
   end process;

end architecture;
