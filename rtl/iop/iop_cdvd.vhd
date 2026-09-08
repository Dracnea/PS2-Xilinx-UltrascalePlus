-- iop_cdvd.vhd -- the CDVD drive controller's register block at 0x1F402000,
-- as seen by the IOP, with no disc in it.
--
-- The CDVD/MechaCon protocol is not publicly documented by Sony; the register
-- list is ps2tek's and every value here follows PCSX2's CDVD.cpp, so all of
-- it is unverified against a drive.  Byte registers, offsets from 0x1F402000:
--   0x04  N command (R/W)      writing runs the command; here every N command
--                              completes at once, read commands with error 0x12
--                              (no disc), and raises I_STAT bit 0 and INTC bit 2
--   0x05  N ready (R)          0x4A: data-empty | mecha-init | drive-ready
--         N parameter (W)      stored (up to 16 bytes)
--   0x06  error (R)            last error, cleared by the read
--   0x07  BREAK (W)            ignored
--   0x08  I_STAT (R/W)         bit 0 command complete; write clears the bits written
--   0x0A  drive status (R)     0x00 stopped
--   0x0B  status sticky (R)    0x00
--   0x0F  disc type (R)        0x00 no disc
--   0x13  speed (R)            0x00
--   0x15  reserved (R)         0x00
--   0x16  S command (R/W)      writing runs the command with the parameters
--                              written to 0x17 since the last command
--   0x17  S ready (R)          0x40 while no result byte is left, else 0x00
--         S parameter (W)      parameter byte
--   0x18  S data out (R)       next result byte
-- S commands answered (bytes as PCSX2 returns them): 0x03/0x00 mecha version
-- 03 06 02 00; 0x05 tray state 00; 0x08 RTC 00 ss mm hh 00 dd MM yy (BCD,
-- fixed at 2000-01-01 00:00:00); 0x12 i.LINK id 00 00 AC FF FF FF FF B9 86;
-- 0x15 forbid DVD 05; 0x1A boot certify 01; 0x1B, 0x1C, 0x24, 0x29, 0x40,
-- 0x42, 0x43 -> 00; 0x1E remote 00 14 00 00 00; 0x22 wake-up time ten zeros;
-- 0x36 region params 03 06 02 00 then eleven zeros; 0x41 read config 16
-- zeros; anything else 0x81 (unsupported), one byte.  The sector path (N
-- read, the DMA channel 3 data port) is not here: "no disc" is the answer.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity iop_cdvd is
   port
   (
      clk1x         : in  std_logic;
      reset         : in  std_logic;
      bus_addr      : in  unsigned(5 downto 0);
      bus_writeMask : in  std_logic_vector(3 downto 0);   -- stores arrive word-aligned, lanes in the mask
      bus_dataWrite : in  std_logic_vector(31 downto 0);
      bus_read      : in  std_logic;
      bus_write     : in  std_logic;
      bus_dataRead  : out std_logic_vector(31 downto 0) := (others => '0');
      irq           : out std_logic := '0'
   );
end entity;

architecture arch of iop_cdvd is

   signal ncmd      : std_logic_vector(7 downto 0) := (others => '0');
   signal err       : std_logic_vector(7 downto 0) := (others => '0');
   signal istat     : std_logic_vector(7 downto 0) := (others => '0');
   signal scmd      : std_logic_vector(7 downto 0) := (others => '0');
   type t_bytes is array (0 to 15) of std_logic_vector(7 downto 0);
   signal sparam    : t_bytes := (others => (others => '0'));
   signal sparam_n  : unsigned(3 downto 0) := (others => '0');
   signal sres_n    : unsigned(4 downto 0) := (others => '0');   -- result bytes left
   signal sres_pos  : unsigned(4 downto 0) := (others => '0');
   signal ncmd_pend : unsigned(4 downto 0) := (others => '0');   -- N command completes when this counts down

   -- result byte `i` (0-based) of S command `cmd` with first parameter `p0`, and the count
   function s_count(cmd : std_logic_vector(7 downto 0); p0 : std_logic_vector(7 downto 0)) return integer is
   begin
      case (cmd) is
         when x"03"  => if (p0 = x"00") then return 4; else return 1; end if;
         when x"05" | x"15" | x"1A" | x"1B" | x"1C" | x"24" | x"29" | x"40" | x"42" | x"43" => return 1;
         when x"08"  => return 8;
         when x"12"  => return 9;
         when x"1E"  => return 5;
         when x"22"  => return 10;
         when x"36"  => return 15;
         when x"41"  => return 16;
         when others => return 1;
      end case;
   end function;

   function s_byte(cmd : std_logic_vector(7 downto 0); p0 : std_logic_vector(7 downto 0); i : integer) return std_logic_vector is
      constant mecha : t_bytes := (x"03", x"06", x"02", x"00", others => x"00");
      constant ilink : t_bytes := (x"00", x"00", x"AC", x"FF", x"FF", x"FF", x"FF", x"B9", x"86", others => x"00");
      constant rtc   : t_bytes := (x"00", x"00", x"00", x"00", x"00", x"01", x"01", x"00", others => x"00");
      constant rem2  : t_bytes := (x"00", x"14", x"00", x"00", x"00", others => x"00");
   begin
      case (cmd) is
         when x"03"  => if (p0 = x"00") then return mecha(i); else return x"81"; end if;
         when x"08"  => return rtc(i);
         when x"12"  => return ilink(i);
         when x"15"  => return x"05";
         when x"1A"  => return x"01";
         when x"1E"  => return rem2(i);
         when x"36"  => return mecha(i);
         when x"05" | x"1B" | x"1C" | x"22" | x"24" | x"29" | x"40" | x"41" | x"42" | x"43" => return x"00";
         when others => return x"81";
      end case;
   end function;

begin

   process (clk1x)
      variable din : std_logic_vector(7 downto 0);
      variable sready : std_logic_vector(7 downto 0);
      variable wlane : integer range 0 to 3;
      variable waddr : integer range 0 to 63;
   begin
      if rising_edge(clk1x) then
         bus_dataRead <= (others => '0');
         irq <= '0';

         -- a byte store arrives word-aligned: the register is the word address
         -- plus the lane the mask names, and the byte is in that lane
         if    (bus_writeMask(0) = '1') then din := bus_dataWrite(7 downto 0);   wlane := 0;
         elsif (bus_writeMask(1) = '1') then din := bus_dataWrite(15 downto 8);  wlane := 1;
         elsif (bus_writeMask(2) = '1') then din := bus_dataWrite(23 downto 16); wlane := 2;
         else                                din := bus_dataWrite(31 downto 24); wlane := 3;
         end if;
         waddr := to_integer(bus_addr(5 downto 2)) * 4 + wlane;
         if (sres_pos < sres_n) then sready := x"00"; else sready := x"40"; end if;

         if (reset = '1') then
            ncmd <= (others => '0'); err <= (others => '0'); istat <= (others => '0');
            scmd <= (others => '0'); sparam_n <= (others => '0');
            sres_n <= (others => '0'); sres_pos <= (others => '0'); ncmd_pend <= (others => '0');
         else
            if (ncmd_pend /= 0) then
               ncmd_pend <= ncmd_pend - 1;
               if (ncmd_pend = 1) then
                  istat(0) <= '1';
                  irq <= '1';
               end if;
            end if;

            -- reads: the byte lands in the lane of its address so lb/lbu see it
            if (bus_read = '1') then
               case (to_integer(bus_addr)) is
                  when 16#04# => bus_dataRead <= x"000000" & ncmd;
                  when 16#05# => bus_dataRead <= x"0000" & x"4A" & x"00";
                  when 16#06# => bus_dataRead <= x"00" & err & x"0000";
                                 err <= (others => '0');
                  when 16#08# => bus_dataRead <= x"000000" & istat;
                  when 16#16# => bus_dataRead <= x"00" & scmd & x"0000";
                  when 16#17# => bus_dataRead <= sready & x"000000";
                  when 16#18# =>
                     if (sres_pos < sres_n) then
                        bus_dataRead <= x"000000" & s_byte(scmd, sparam(0), to_integer(sres_pos));
                        sres_pos <= sres_pos + 1;
                     else
                        bus_dataRead <= (others => '0');
                     end if;
                  when others => bus_dataRead <= (others => '0');   -- 0x0A, 0x0B, 0x0F, 0x13, 0x15: all zero
               end case;
            end if;

            -- writes
            if (bus_write = '1') then
               case (waddr) is
                  when 16#04# =>
                     ncmd <= din;
                     ncmd_pend <= to_unsigned(16, 5);
                     case (din) is
                        when x"06" | x"08" | x"0A" | x"0C" | x"0E" => err <= x"12";   -- read commands: no disc
                        when others => null;
                     end case;
                  when 16#08# => istat <= istat and not din;
                  when 16#16# =>
                     scmd     <= din;
                     sres_n   <= to_unsigned(s_count(din, sparam(0)), 5);
                     sres_pos <= (others => '0');
                     sparam_n <= (others => '0');
                  when 16#17# =>
                     sparam(to_integer(sparam_n)) <= din;
                     sparam_n <= sparam_n + 1;
                  when others => null;
               end case;
            end if;
         end if;
      end if;
   end process;

end architecture;
