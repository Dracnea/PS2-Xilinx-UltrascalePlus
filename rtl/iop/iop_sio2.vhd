-- iop_sio2.vhd -- the IOP's SIO2 (controller / memory-card serial interface)
-- at 0x1F808200, with a digital pad answering on port 0.
--
-- Register map (byte offsets from 0x1F808200; ps2tek's address list, PCSX2's
-- Sio2 for the semantics -- there is no public Sony documentation of this
-- block):
--   0x00-0x3F  SEND3[0..15]  command queue: bits 1:0 port, bits 17:8 byte
--                            count; the first entry with a zero count ends
--                            the queue
--   0x40-0x4F  SEND1[0..3]   port control 1 (stored, not interpreted)
--   0x50-0x5F  SEND2[0..3]   port control 2 (stored, not interpreted)
--   0x60       FIFO in       byte written by the IOP (or DMA channel 11, absent)
--   0x64       FIFO out      byte read by the IOP (or DMA channel 12, absent)
--   0x68       CTRL          bit 0 start transfer (self-clearing here), bits
--                            3:2 written as 0xC reset the FIFOs and queue
--   0x6C       RECV1         0x1100 device answered on the last port,
--                            0x1D100 no device (PCSX2's CONNECTED /
--                            DISCONNECTED values)
--   0x70       RECV2         0xF
--   0x74       RECV3         0
--   0x78/0x7C  FIFO tx/rx positions (stored, not interpreted)
--   0x80       I_STAT        bit 0 set on transfer complete; write 1 clears
-- A transfer walks the queue: for each entry it takes `count` bytes from the
-- in FIFO, gives them to the device on that port, and pushes the replies into
-- the out FIFO; then it sets I_STAT(0) and pulses irq (INTC bit 17).
--
-- Devices: port 0 is a digital pad following the PS1 pad protocol (psx-spx):
-- a command starting 0x01 gets 0xFF, 0x41 (digital pad, one data halfword),
-- 0x5A, buttons(7:0), buttons(15:8), then 0xFF; buttons are active low and
-- come from the pad0_buttons port.  Every other port, and any command not
-- starting with 0x01 (memory cards start 0x81), answers 0xFF.
--
-- NOTE (unverified): the SEND3 bit layout, the RECV1 values and the reset
-- and start bits are from emulator source, not from hardware.  Verify by:
-- running the IOP kernel's sio2man/padman against this block.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity iop_sio2 is
   port
   (
      clk1x         : in  std_logic;
      reset         : in  std_logic;
      pad0_buttons  : in  std_logic_vector(15 downto 0);   -- active low, PS1 bit order
      bus_addr      : in  unsigned(7 downto 0);
      bus_writeMask : in  std_logic_vector(3 downto 0);   -- stores arrive word-aligned, lanes in the mask
      bus_dataWrite : in  std_logic_vector(31 downto 0);
      bus_read      : in  std_logic;
      bus_write     : in  std_logic;
      bus_dataRead  : out std_logic_vector(31 downto 0) := (others => '0');
      irq           : out std_logic := '0'
   );
end entity;

architecture arch of iop_sio2 is

   type t_regs32 is array (0 to 15) of std_logic_vector(31 downto 0);
   signal send3     : t_regs32 := (others => (others => '0'));
   type t_regs8x32 is array (0 to 7) of std_logic_vector(31 downto 0);
   signal send12    : t_regs8x32 := (others => (others => '0'));
   signal ctrl      : std_logic_vector(31 downto 0) := (others => '0');
   signal recv1     : std_logic_vector(31 downto 0) := x"0001D100";
   signal txpos, rxpos : std_logic_vector(31 downto 0) := (others => '0');
   signal istat     : std_logic := '0';

   type t_fifo is array (0 to 255) of std_logic_vector(7 downto 0);
   signal fifo_in, fifo_out : t_fifo := (others => (others => '0'));
   signal in_wr, in_rd   : unsigned(7 downto 0) := (others => '0');
   signal out_wr, out_rd : unsigned(7 downto 0) := (others => '0');

   type t_state is (IDLE, ENTRY, XFER, DONE);
   signal state     : t_state := IDLE;
   signal qentry     : unsigned(3 downto 0) := (others => '0');
   signal remaining : unsigned(9 downto 0) := (others => '0');
   signal byte_idx  : unsigned(9 downto 0) := (others => '0');
   signal port_sel  : unsigned(1 downto 0) := (others => '0');
   signal is_pad    : std_logic := '0';
   signal answered  : std_logic := '0';

   -- the byte a device on port `prt` returns for byte `idx` of a command whose
   -- first byte was `first`
   function reply(prt : unsigned(1 downto 0); pad : std_logic; idx : unsigned(9 downto 0);
                  buttons : std_logic_vector(15 downto 0)) return std_logic_vector is
   begin
      if (prt /= 0 or pad = '0') then
         return x"FF";
      end if;
      case (to_integer(idx)) is
         when 0      => return x"FF";
         when 1      => return x"41";
         when 2      => return x"5A";
         when 3      => return buttons(7 downto 0);
         when 4      => return buttons(15 downto 8);
         when others => return x"FF";
      end case;
   end function;

begin

   process (clk1x)
      variable idx  : integer range 0 to 63;
      variable cnt  : unsigned(9 downto 0);
      variable din  : std_logic_vector(7 downto 0);
   begin
      if rising_edge(clk1x) then
         bus_dataRead <= (others => '0');
         irq <= '0';
         idx := to_integer(bus_addr(7 downto 2));

         if (reset = '1') then
            state <= IDLE; istat <= '0'; ctrl <= (others => '0');
            in_wr <= (others => '0'); in_rd <= (others => '0');
            out_wr <= (others => '0'); out_rd <= (others => '0');
            recv1 <= x"0001D100";
         else
            -- reads (valid the cycle after the strobe, zero otherwise: the mux ORs all buses)
            if (bus_read = '1') then
               if (bus_addr < x"40") then
                  bus_dataRead <= send3(idx);
               elsif (bus_addr < x"60") then
                  bus_dataRead <= send12(idx - 16);
               else
                  case (bus_addr(7 downto 2)) is
                     when "011001" =>          -- 0x64 FIFO out
                        if (out_rd /= out_wr) then
                           bus_dataRead <= x"000000" & fifo_out(to_integer(out_rd));
                           out_rd <= out_rd + 1;
                        else
                           bus_dataRead <= x"000000FF";
                        end if;
                     when "011010" => bus_dataRead <= ctrl;                    -- 0x68
                     when "011011" => bus_dataRead <= recv1;                   -- 0x6C
                     when "011100" => bus_dataRead <= x"0000000F";             -- 0x70 RECV2
                     when "011101" => bus_dataRead <= x"00000000";             -- 0x74 RECV3
                     when "011110" => bus_dataRead <= txpos;                   -- 0x78
                     when "011111" => bus_dataRead <= rxpos;                   -- 0x7C
                     when "100000" => bus_dataRead <= (31 downto 1 => '0') & istat;   -- 0x80
                     when others   => null;
                  end case;
               end if;
            end if;

            -- writes
            if (bus_write = '1') then
               if (bus_addr < x"40") then
                  send3(idx) <= bus_dataWrite;
               elsif (bus_addr < x"60") then
                  send12(idx - 16) <= bus_dataWrite;
               else
                  case (bus_addr(7 downto 2)) is
                     when "011000" =>          -- 0x60 FIFO in (byte in the lane the mask says)
                        if    (bus_writeMask(0) = '1') then din := bus_dataWrite(7 downto 0);
                        elsif (bus_writeMask(1) = '1') then din := bus_dataWrite(15 downto 8);
                        elsif (bus_writeMask(2) = '1') then din := bus_dataWrite(23 downto 16);
                        else                                din := bus_dataWrite(31 downto 24);
                        end if;
                        fifo_in(to_integer(in_wr)) <= din;
                        in_wr <= in_wr + 1;
                     when "011010" =>          -- 0x68 CTRL
                        ctrl <= bus_dataWrite;
                        if (bus_dataWrite(3 downto 2) = "11") then   -- 0xC: reset
                           in_wr <= (others => '0'); in_rd <= (others => '0');
                           out_wr <= (others => '0'); out_rd <= (others => '0');
                           state <= IDLE;
                        end if;
                        if (bus_dataWrite(0) = '1' and state = IDLE) then
                           state    <= ENTRY;
                           qentry    <= (others => '0');
                           answered <= '0';
                        end if;
                     when "011110" => txpos <= bus_dataWrite;
                     when "011111" => rxpos <= bus_dataWrite;
                     when "100000" =>          -- 0x80 I_STAT: write 1 to clear
                        if (bus_dataWrite(0) = '1') then istat <= '0'; end if;
                     when others   => null;
                  end case;
               end if;
            end if;

            -- the transfer engine
            case (state) is
               when IDLE => null;

               when ENTRY =>
                  cnt := unsigned(send3(to_integer(qentry))(17 downto 8));
                  if (cnt = 0) then
                     state <= DONE;
                  else
                     port_sel  <= unsigned(send3(to_integer(qentry))(1 downto 0));
                     remaining <= cnt;
                     byte_idx  <= (others => '0');
                     is_pad    <= '0';
                     state     <= XFER;
                  end if;

               when XFER =>
                  if (remaining = 0) then
                     if (qentry = 15) then
                        state <= DONE;
                     else
                        qentry <= qentry + 1;
                        state <= ENTRY;
                     end if;
                  else
                     -- take one command byte (0xFF if the IOP gave fewer than promised)
                     if (in_rd /= in_wr) then
                        din := fifo_in(to_integer(in_rd));
                        in_rd <= in_rd + 1;
                     else
                        din := x"FF";
                     end if;
                     if (byte_idx = 0) then
                        if (din = x"01" and port_sel = 0) then
                           is_pad   <= '1';
                           answered <= '1';
                           fifo_out(to_integer(out_wr)) <= x"FF";
                        else
                           is_pad <= '0';
                           fifo_out(to_integer(out_wr)) <= x"FF";
                        end if;
                     else
                        fifo_out(to_integer(out_wr)) <= reply(port_sel, is_pad, byte_idx, pad0_buttons);
                     end if;
                     out_wr    <= out_wr + 1;
                     byte_idx  <= byte_idx + 1;
                     remaining <= remaining - 1;
                  end if;

               when DONE =>
                  if (answered = '1') then
                     recv1 <= x"00001100";
                  else
                     recv1 <= x"0001D100";
                  end if;
                  ctrl(0) <= '0';
                  istat   <= '1';
                  irq     <= '1';
                  state   <= IDLE;
            end case;
         end if;
      end if;
   end process;

end architecture;
