-- iop_sif.vhd -- the IOP's half of the Sub-system InterFace (SIF), the mailbox
-- between the IOP and the Emotion Engine, at 0x1D000000.
--
-- Why this exists, and what it replaced: until 2026-09-08 the SIF was an
-- iop_regstub, a register file that stored what the IOP wrote and returned it.
-- With a real BIOS that is exactly enough to hang.  SIFMAN's init writes its
-- own ready flag and then polls MSFLAG for bit 16 until the EE answers:
--
--    SIFMAN .text+0x1c8   lui   $s1,0x0001        ; 0x00010000
--    SIFMAN .text+0x1f4   jal   sceSifGetMSFLAG
--    SIFMAN .text+0x208   and   $s0,$s0,$s1
--    SIFMAN .text+0x20c   beq   $s0,$zero,0x1ec   ; spin while clear
--
-- and a stub's MSFLAG is 0 forever, because MSFLAG is written by the EE and
-- never by the IOP.  Captured on the C1100 on 2026-09-08: the CPU looping on
-- LD 0xBD000020, LD 0xBD000020, a kernel flag in RAM, LD 0xBF801078, with the
-- stall detector reading 0 -- running, not hung.  There is no EE here, so this
-- block gives the host the EE's side of the mailbox instead.
--
-- Registers (IOP side).  Semantics from ps2tek, PS2SDK's sifman/sifcmd and
-- PCSX2; the flag registers are semaphores rather than plain storage:
--
--   0x00 MSCOM   main -> sub.  EE writes, IOP reads.  Read-only here.
--   0x10 SMCOM   sub -> main.  IOP writes, EE reads.
--   0x20 MSFLAG  EE SETS bits; an IOP write CLEARS the bits it names.
--   0x30 SMFLAG  IOP SETS bits (a write ORs them in); the EE clears them.
--   0x40 CTRL    control/handshake.  Stored, and bit 0x100 mirrored back the
--                way PCSX2 does, so SIFMAN's read-modify-write sequence sees a
--                value change.
--   0x60 BD6     SIFMAN reads this early and compares it with 0x1D000060.
--
-- > NOTE (unverified): the exact CTRL and BD6 semantics are taken from
-- > emulator behaviour, not measured on an IOP, and only the paths the boot
-- > exercises are implemented.
-- > *Verify by: running the BIOS past SIFMAN's init with the host setting
-- > MSFLAG bit 16 and checking that SIFCMD and EESYNC also proceed.*
--
-- The host side is the EE stand-in.  It is in the IOP clock domain; the board
-- target crosses it to the CSR domain.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity iop_sif is
   port
   (
      clk1x         : in  std_logic;
      reset         : in  std_logic;
      -- IOP bus
      bus_addr      : in  unsigned(6 downto 0);
      bus_writeMask : in  std_logic_vector(3 downto 0) := "1111";
      bus_dataWrite : in  std_logic_vector(31 downto 0);
      bus_read      : in  std_logic;
      bus_write     : in  std_logic;
      bus_dataRead  : out std_logic_vector(31 downto 0) := (others => '0');
      -- host side: the Emotion Engine's half of the mailbox
      --   sel 0 = MSCOM write, 1 = MSFLAG set, 2 = MSFLAG clear,
      --       3 = SMFLAG clear, 4 = CTRL write, 5 = BD6 write
      host_sel      : in  unsigned(2 downto 0)  := (others => '0');
      host_data     : in  std_logic_vector(31 downto 0) := (others => '0');
      host_we       : in  std_logic := '0';
      host_mscom    : out std_logic_vector(31 downto 0);
      host_smcom    : out std_logic_vector(31 downto 0);
      host_msflag   : out std_logic_vector(31 downto 0);
      host_smflag   : out std_logic_vector(31 downto 0);
      host_ctrl     : out std_logic_vector(31 downto 0)
   );
end entity;

architecture arch of iop_sif is
   signal mscom  : std_logic_vector(31 downto 0) := (others => '0');
   signal smcom  : std_logic_vector(31 downto 0) := (others => '0');
   signal msflag : std_logic_vector(31 downto 0) := (others => '0');
   signal smflag : std_logic_vector(31 downto 0) := (others => '0');
   signal ctrl   : std_logic_vector(31 downto 0) := (others => '0');
   signal bd6    : std_logic_vector(31 downto 0) := (others => '0');

   -- the IOP's write data with only the lanes its store named
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
begin

   host_mscom  <= mscom;
   host_smcom  <= smcom;
   host_msflag <= msflag;
   host_smflag <= smflag;
   host_ctrl   <= ctrl;

   process (clk1x)
      constant zero32 : std_logic_vector(31 downto 0) := (others => '0');
      variable wr          : std_logic_vector(31 downto 0);
      variable iop_clr_ms  : std_logic_vector(31 downto 0);
      variable host_set_ms : std_logic_vector(31 downto 0);
      variable host_clr_ms : std_logic_vector(31 downto 0);
      variable iop_set_sm  : std_logic_vector(31 downto 0);
      variable host_clr_sm : std_logic_vector(31 downto 0);
   begin
      if rising_edge(clk1x) then
         -- the mux ORs every peripheral's read data together, so this must be
         -- zero except in the cycle after a read strobe
         bus_dataRead <= (others => '0');
         if (bus_read = '1') then
            case to_integer(bus_addr(6 downto 4)) is
               when 0      => bus_dataRead <= mscom;    -- 0x00
               when 1      => bus_dataRead <= smcom;    -- 0x10
               when 2      => bus_dataRead <= msflag;   -- 0x20
               when 3      => bus_dataRead <= smflag;   -- 0x30
               when 4      => bus_dataRead <= ctrl;     -- 0x40
               when 6      => bus_dataRead <= bd6;      -- 0x60
               when others => bus_dataRead <= (others => '0');
            end case;
         end if;

         if (reset = '1') then
            mscom <= (others => '0'); smcom <= (others => '0');
            msflag <= (others => '0'); smflag <= (others => '0');
            ctrl <= (others => '0'); bd6 <= (others => '0');
         else
            -- Both sides act in the same cycle rather than one overwriting the
            -- other: the IOP clears MSFLAG bits while the EE sets them, and the
            -- IOP sets SMFLAG bits while the EE clears them.  Sequencing those
            -- as two separate assignments would silently drop whichever lost,
            -- which in a mailbox is a hang waiting to happen.
            iop_clr_ms := (others => '0');
            host_set_ms := (others => '0');
            host_clr_ms := (others => '0');
            iop_set_sm := (others => '0');
            host_clr_sm := (others => '0');

            if (bus_write = '1') then
               wr := lanes(zero32, bus_dataWrite, bus_writeMask);
               case to_integer(bus_addr(6 downto 4)) is
                  when 1 => smcom <= lanes(smcom, bus_dataWrite, bus_writeMask);
                  when 2 => iop_clr_ms := wr;                       -- write-to-clear
                  when 3 => iop_set_sm := wr;                       -- write-to-set
                  when 4 => ctrl  <= lanes(ctrl, bus_dataWrite, bus_writeMask);
                  when 6 => bd6   <= lanes(bd6, bus_dataWrite, bus_writeMask);
                  when others => null;
               end case;
            end if;

            if (host_we = '1') then
               case to_integer(host_sel) is
                  when 0 => mscom <= host_data;
                  when 1 => host_set_ms := host_data;               -- the EE sets
                  when 2 => host_clr_ms := host_data;
                  when 3 => host_clr_sm := host_data;               -- the EE clears
                  when 4 => ctrl  <= host_data;
                  when 5 => bd6   <= host_data;
                  when others => null;
               end case;
            end if;

            msflag <= (msflag and not (iop_clr_ms or host_clr_ms)) or host_set_ms;
            smflag <= (smflag or iop_set_sm) and not host_clr_sm;
         end if;
      end if;
   end process;

end architecture;
