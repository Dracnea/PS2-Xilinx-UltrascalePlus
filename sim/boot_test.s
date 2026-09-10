# boot_test.s -- IOP subsystem bring-up ROM.  Runs from the reset vector
# (0xBFC00000, uncached) and reports through the POST register 0x1F802070.
#   01  alive               02  RAM word test         03  byte/half access
#   04  code copied to RAM and run cached (KSEG0)     05  timer 3 polled
#   06  timer 3 interrupt taken through the BEV=1 vector at 0xBFC00180
#   07  SPU2 core 0 / core 1 voice registers written and read back (16-bit)
#   08  SPU2 core 0 transfer FIFO: 4 halfwords written to work RAM at 0x2000
#       (the testbench checks the RAM contents when the test passes)
#   09  SIO2: a 5-byte pad poll on port 0 answered FF 41 5A 3C 5A (the
#       testbench drives pad0_buttons = 0x5A3C), RECV1 = 0x1100, I_STAT and
#       INTC bit 17 set and acknowledged
#   0A  CDVD: no disc, N ready 0x4A, S command 03/00 returns 03 06 02 00,
#       N command 00 completes with I_STAT bit 0 and INTC bit 2
#   0B  byte enables on a register stub: sw, then sh low, sh high, sb
#   0C  SIF mailbox: SMFLAG set, wait for the bench to set MSFLAG bit 16,
#       clear it, read MSCOM, write/read SMCOM
#   0D  DMA channel 6 (OTC): builds a four-entry ordering table in RAM, checks
#       the linked list and the end marker, the DICR flag and INTC bit 3
#   0E  CDVD read of sector 16 delivered by DMA channel 3: checks the ISO9660
#       volume-descriptor signature in RAM and INTC bit 2
#   AA  all passed          EE  a check failed (the failing stage is the
#                               POST value before it)

.org 0xBFC00000
        j       start
        nop

# ---- general exception vector while BEV=1 -------------------------------
.org 0xBFC00180
        mfc0    $k0, $13                # CAUSE
        nop
        andi    $k0, $k0, 0x7C          # ExcCode
        bne     $k0, $zero, fail        # anything but an interrupt is a failure
        nop
        li      $k1, 0x1F801070
        li      $k0, 0xFFFEBFFF         # acknowledge timer 3 (bit 14) and timer 5 (bit 16).
        sw      $k0, 0($k1)             # Acknowledging only the source this handler was
                                        # written for leaves any other one asserted, and a
                                        # level-triggered source that is never cleared
                                        # re-enters the handler forever -- which looks like
                                        # a hung test rather than an unacknowledged interrupt.
        li      $k0, 0x1F801484
        lw      $k1, 0($k0)             # timer 3 MODE: reading clears the reached flags
        li      $k0, 0x1F8014A4
        lw      $k1, 0($k0)             # timer 5 MODE, likewise
        nop
        li      $k0, 0xA0001000
        li      $k1, 1
        sw      $k1, 0($k0)             # flag for the main loop
        li      $k0, 0x1F802070
        li      $k1, 0x5A
        sb      $k1, 0($k0)
        mfc0    $k0, $14                # EPC
        nop
        jr      $k0
        rfe

# ---- main -----------------------------------------------------------------
start:
        li      $sp, 0x801FFF00
        li      $s7, 0x1F802070         # POST
        li      $t0, 1
        sb      $t0, 0($s7)

# SSBUS configuration the real IOPBOOT does first; the values are stored and
# read back through memctrl, nothing here depends on them yet
        li      $t0, 0x1F801000
        li      $t1, 0x1F000000
        sw      $t1, 0x00($t0)          # EXP1 base
        li      $t1, 0x1F802000
        sw      $t1, 0x04($t0)          # EXP2 base
        li      $t1, 0x0013243F
        sw      $t1, 0x10($t0)          # BIOS ROM delay/size
        lw      $t2, 0x10($t0)
        nop
        bne     $t2, $t1, fail          # must read back
        nop
        li      $t1, 0x00000B88
        sw      $t1, 0x60($t0)          # RAM_SIZE
        lw      $t2, 0x60($t0)
        nop
        bne     $t2, $t1, fail
        nop

# ---- 02: RAM word test, uncached ------------------------------------------
        li      $t0, 0xA0010000
        li      $t1, 256
        li      $t2, 0x12345678
w_loop: sw      $t2, 0($t0)
        addiu   $t2, $t2, 0x1111
        addiu   $t0, $t0, 4
        addiu   $t1, $t1, -1
        bne     $t1, $zero, w_loop
        nop
        li      $t0, 0xA0010000
        li      $t1, 256
        li      $t2, 0x12345678
r_loop: lw      $t3, 0($t0)
        nop
        bne     $t3, $t2, fail
        nop
        addiu   $t2, $t2, 0x1111
        addiu   $t0, $t0, 4
        addiu   $t1, $t1, -1
        bne     $t1, $zero, r_loop
        nop
        li      $t0, 2
        sb      $t0, 0($s7)

# ---- 03: byte and halfword access -----------------------------------------
        li      $t0, 0xA0020000
        li      $t1, 0xAABBCCDD
        sw      $t1, 0($t0)
        lbu     $t2, 0($t0)             # little endian: 0xDD
        nop
        li      $t3, 0xDD
        bne     $t2, $t3, fail
        nop
        lbu     $t2, 3($t0)
        nop
        li      $t3, 0xAA
        bne     $t2, $t3, fail
        nop
        lhu     $t2, 2($t0)
        nop
        li      $t3, 0xAABB
        bne     $t2, $t3, fail
        nop
        li      $t3, 0x11
        sb      $t3, 1($t0)
        lw      $t2, 0($t0)
        nop
        li      $t3, 0xAABB11DD
        bne     $t2, $t3, fail
        nop
        li      $t3, 0x2233
        sh      $t3, 2($t0)
        lw      $t2, 0($t0)
        nop
        li      $t3, 0x223311DD
        bne     $t2, $t3, fail
        nop
        lh      $t2, 0($t0)             # sign-extended 0x11DD
        nop
        li      $t3, 0x11DD
        bne     $t2, $t3, fail
        nop
        lb      $t2, 3($t0)             # sign-extended 0x22
        nop
        li      $t3, 0x22
        bne     $t2, $t3, fail
        nop
        li      $t0, 3
        sb      $t0, 0($s7)

# ---- 04: copy a routine into RAM and run it cached --------------------------
        la      $t0, ram_code
        la      $t1, ram_code_end
        li      $t2, 0xA0002000
copy:   lw      $t3, 0($t0)
        nop
        sw      $t3, 0($t2)
        addiu   $t0, $t0, 4
        addiu   $t2, $t2, 4
        bne     $t0, $t1, copy
        nop
        li      $t0, 0x80002000         # cached alias
        jalr    $t0
        nop
        li      $t1, 5050
        bne     $v0, $t1, fail
        nop
        li      $t0, 4
        sb      $t0, 0($s7)

# ---- 05: timer 3, polled ----------------------------------------------------
        li      $t0, 0x1F801480
        li      $t1, 2000
        sw      $t1, 8($t0)             # TARGET
        li      $t1, 0x0008             # reset on target, no IRQ
        sw      $t1, 4($t0)             # MODE (also zeroes COUNT)
poll:   lw      $t2, 4($t0)
        nop
        andi    $t2, $t2, 0x0800        # reached target
        beq     $t2, $zero, poll
        nop
        lw      $t2, 0($t0)             # COUNT must have wrapped to a small value
        nop
        sltiu   $t2, $t2, 2000
        beq     $t2, $zero, fail
        nop
        li      $t0, 5
        sb      $t0, 0($s7)

# ---- 06: timer 3 interrupt --------------------------------------------------
        li      $t0, 0xA0001000
        sw      $zero, 0($t0)           # flag
        li      $t1, 0x1F801070
        li      $t2, 0x00004000         # I_MASK: RTC3
        sw      $t2, 4($t1)
        sw      $zero, 0($t1)           # I_STAT: clear everything
        li      $t2, 1
        sw      $t2, 8($t1)             # I_CTRL: enable
        li      $t1, 0x1F801480
        li      $t2, 3000
        sw      $t2, 8($t1)             # TARGET
        li      $t2, 0x0058             # reset on target | IRQ on target | repeat
        sw      $t2, 4($t1)
        li      $t2, 0x00400401         # SR: BEV | IM2 | IEc.  BEV must stay set: the
        mtc0    $t2, $12                # vector is 0xBFC00180 only while it is (found in sim)
        nop
        li      $t3, 200000
wait:   lw      $t2, 0($t0)
        addiu   $t3, $t3, -1
        beq     $t3, $zero, fail
        nop
        beq     $t2, $zero, wait
        nop
        li      $t2, 0x00400000
        mtc0    $t2, $12                # interrupts off again, BEV kept
        nop
        li      $t0, 6
        sb      $t0, 0($s7)

# ---- 07: SPU2 voice registers on both cores (PSX register layout for now) ---
        li      $t0, 0x1F900000
        li      $t1, 0x1234
        sh      $t1, 4($t0)             # core 0 voice 0 pitch
        li      $t1, 0x0ABC
        sh      $t1, 6($t0)             # core 0 voice 0 start address (odd halfword: bits 31:16 of the bus)
        li      $t1, 0x0DEF
        sh      $t1, 0x404($t0)         # core 1 voice 0 pitch
        li      $t1, 0x0123
        sh      $t1, 0x406($t0)         # core 1 voice 0 start address
        lhu     $t2, 4($t0)
        nop
        li      $t3, 0x1234
        bne     $t2, $t3, fail
        nop
        lhu     $t2, 6($t0)
        nop
        li      $t3, 0x0ABC
        bne     $t2, $t3, fail
        nop
        lhu     $t2, 0x404($t0)
        nop
        li      $t3, 0x0DEF
        bne     $t2, $t3, fail
        nop
        lhu     $t2, 0x406($t0)
        nop
        li      $t3, 0x0123
        bne     $t2, $t3, fail
        nop
        li      $t0, 7
        sb      $t0, 0($s7)

# ---- 08: SPU2 core 0 work RAM through the transfer FIFO ---------------------
        li      $t0, 0x1F900000
        li      $t1, 0xC010             # SPUCNT: enable, unmute, transfer mode 1 (manual write)
        sh      $t1, 0x1AA($t0)
        li      $t1, 0x0400             # TRANSFERADDR in 8-byte units: byte 0x2000
        sh      $t1, 0x1A6($t0)
        li      $t1, 0x1111
        sh      $t1, 0x1A8($t0)         # FIFO
        li      $t1, 0x2222
        sh      $t1, 0x1A8($t0)
        li      $t1, 0x3333
        sh      $t1, 0x1A8($t0)
        li      $t1, 0x4444
        sh      $t1, 0x1A8($t0)
        lhu     $t2, 0x1A6($t0)         # TRANSFERADDR reads back
        nop
        li      $t3, 0x0400
        bne     $t2, $t3, fail
        nop
        li      $t3, 400                # ~40k cycles: the SPU drains the FIFO one halfword per sample slot
d8:     addiu   $t3, $t3, -1
        bne     $t3, $zero, d8
        nop
        li      $t0, 8
        sb      $t0, 0($s7)

# ---- 09: SIO2 pad poll -------------------------------------------------------
        li      $t0, 0x1F808200
        li      $t1, 0x0000000C
        sw      $t1, 0x68($t0)          # CTRL: reset FIFOs
        li      $t1, 0x00000500         # SEND3[0]: port 0, 5 bytes
        sw      $t1, 0x00($t0)
        sw      $zero, 0x04($t0)        # SEND3[1]: end of queue
        li      $t1, 0x01
        sb      $t1, 0x60($t0)          # FIFO in: 01 42 00 00 00
        li      $t1, 0x42
        sb      $t1, 0x60($t0)
        sb      $zero, 0x60($t0)
        sb      $zero, 0x60($t0)
        sb      $zero, 0x60($t0)
        li      $t1, 0x00000001
        sw      $t1, 0x68($t0)          # CTRL: start
        li      $t3, 1000
w9:     lw      $t2, 0x80($t0)          # I_STAT
        addiu   $t3, $t3, -1
        beq     $t3, $zero, fail
        nop
        andi    $t2, $t2, 1
        beq     $t2, $zero, w9
        nop
        lw      $t2, 0x6C($t0)          # RECV1: device answered
        nop
        li      $t3, 0x1100
        bne     $t2, $t3, fail
        nop
        lbu     $t2, 0x64($t0)          # FIFO out: FF 41 5A 3C 5A
        nop
        li      $t3, 0xFF
        bne     $t2, $t3, fail
        nop
        lbu     $t2, 0x64($t0)
        nop
        li      $t3, 0x41
        bne     $t2, $t3, fail
        nop
        lbu     $t2, 0x64($t0)
        nop
        li      $t3, 0x5A
        bne     $t2, $t3, fail
        nop
        lbu     $t2, 0x64($t0)
        nop
        li      $t3, 0x3C
        bne     $t2, $t3, fail
        nop
        lbu     $t2, 0x64($t0)
        nop
        li      $t3, 0x5A
        bne     $t2, $t3, fail
        nop
        li      $t1, 1
        sw      $t1, 0x80($t0)          # acknowledge SIO2 I_STAT
        lw      $t2, 0x80($t0)
        nop
        bne     $t2, $zero, fail
        nop
        li      $t1, 0x1F801070         # INTC I_STAT bit 17 must be set
        lw      $t2, 0($t1)
        nop
        srl     $t2, $t2, 17
        andi    $t2, $t2, 1
        beq     $t2, $zero, fail
        nop
        li      $t2, 0xFFFDFFFF
        sw      $t2, 0($t1)             # acknowledge it
        li      $t0, 9
        sb      $t0, 0($s7)

# ---- 0A: CDVD, with or without a disc ---------------------------------------
# Everything here except the disc type is independent of whether a disc is in
# the drive, so the type is recorded rather than asserted to be zero and the
# same image runs both ways.  It has to: on hardware the disc is inserted by the
# host before reset, and a test that demanded an empty drive could never reach
# the sector read in 0E.  $s6 carries the answer to 0E.
        li      $t0, 0x1F402000
        lbu     $s6, 0x0F($t0)          # disc type: 00 none, 14 a PS2 DVD
        nop
        beq     $s6, $zero, adisc
        nop
        li      $t3, 0x14
        bne     $s6, $t3, fail          # present, but not a type we serve
        nop
adisc:
        lbu     $t2, 0x05($t0)          # N ready
        nop
        li      $t3, 0x4A
        bne     $t2, $t3, fail
        nop
        sb      $zero, 0x17($t0)        # S parameter 00
        li      $t1, 0x03
        sb      $t1, 0x16($t0)          # S command 03: mecha version
        lbu     $t2, 0x17($t0)          # S ready: data available
        nop
        andi    $t2, $t2, 0x40
        bne     $t2, $zero, fail
        nop
        lbu     $t2, 0x18($t0)          # 03 06 02 00
        nop
        li      $t3, 0x03
        bne     $t2, $t3, fail
        nop
        lbu     $t2, 0x18($t0)
        nop
        li      $t3, 0x06
        bne     $t2, $t3, fail
        nop
        lbu     $t2, 0x18($t0)
        nop
        li      $t3, 0x02
        bne     $t2, $t3, fail
        nop
        lbu     $t2, 0x18($t0)
        nop
        bne     $t2, $zero, fail
        nop
        lbu     $t2, 0x17($t0)          # exhausted
        nop
        andi    $t2, $t2, 0x40
        beq     $t2, $zero, fail
        nop
        sb      $zero, 0x04($t0)        # N command 00 (nop)
        li      $t3, 1000
wa:     lbu     $t2, 0x08($t0)          # CDVD I_STAT
        addiu   $t3, $t3, -1
        beq     $t3, $zero, fail
        nop
        andi    $t2, $t2, 1
        beq     $t2, $zero, wa
        nop
        li      $t1, 1
        sb      $t1, 0x08($t0)          # acknowledge
        lbu     $t2, 0x08($t0)
        nop
        bne     $t2, $zero, fail
        nop
        li      $t1, 0x1F801070         # INTC I_STAT bit 2 (CDVD)
        lw      $t2, 0($t1)
        nop
        andi    $t2, $t2, 0x0004
        beq     $t2, $zero, fail
        nop
        li      $t2, 0xFFFFFFFB
        sw      $t2, 0($t1)
        li      $t0, 0x0A
        sb      $t0, 0($s7)

# ---- 0B: byte enables reach the register stubs ------------------------------
# The DMA block is a read-back stub, but it has to store the lanes a store
# actually names.  SIFMAN writes DMA block counts with `sh` (0x1F8010A4,
# 0x1F801524, 0x1F801534), and until 2026-09-08 iop_regstub stored whole words
# and silently zeroed the other half.  Channel 4's MADR is untouched by the
# rest of this test, so it is used as scratch.
        li      $t0, 0x1F8010C0
        li      $t1, 0xAABBCCDD
        sw      $t1, 0($t0)
        lw      $t2, 0($t0)
        nop
        bne     $t2, $t1, fail          # the word write must read back whole
        nop
        li      $t1, 0x1234
        sh      $t1, 0($t0)             # low halfword only
        lw      $t2, 0($t0)
        nop
        li      $t3, 0xAABB1234
        bne     $t2, $t3, fail
        nop
        li      $t1, 0x5678
        sh      $t1, 2($t0)             # high halfword only
        lw      $t2, 0($t0)
        nop
        li      $t3, 0x56781234
        bne     $t2, $t3, fail
        nop
        li      $t1, 0x99
        sb      $t1, 1($t0)             # one byte only
        lw      $t2, 0($t0)
        nop
        li      $t3, 0x56789934
        bne     $t2, $t3, fail
        nop
        li      $t0, 0x0B
        sb      $t0, 0($s7)

# ---- 0C: the SIF mailbox, both sides ----------------------------------------
# This is SIFMAN's init handshake in miniature.  The IOP sets its own ready bit
# in SMFLAG, then spins on MSFLAG bit 16 until the EE answers -- which on real
# hardware is the EE and here is the testbench.  With the SIF as a plain
# read-back stub this loop never ends, which is exactly where a real BIOS
# stopped on the C1100 on 2026-09-08.
        li      $t0, 0x1D000030         # SMFLAG
        li      $t1, 0x00010000
        sw      $t1, 0($t0)             # IOP sets its ready bit
        lw      $t2, 0($t0)
        nop
        bne     $t2, $t1, fail          # a write to SMFLAG sets, so it reads back
        nop
        li      $t0, 0x1D000020         # MSFLAG
sifw:   lw      $t2, 0($t0)             # wait for the bench to set bit 16
        nop
        andi    $t2, $t2, 0x0000
        lw      $t2, 0($t0)
        nop
        li      $t3, 0x00010000
        and     $t2, $t2, $t3
        beq     $t2, $zero, sifw
        nop
        sw      $t3, 0($t0)             # a write to MSFLAG clears
        lw      $t2, 0($t0)
        nop
        and     $t2, $t2, $t3
        bne     $t2, $zero, fail        # bit 16 must be gone
        nop
        li      $t0, 0x1D000000         # MSCOM: written by the bench, read-only here
        lw      $t2, 0($t0)
        nop
        li      $t3, 0x5A5A1234
        bne     $t2, $t3, fail
        nop
        li      $t0, 0x1D000010         # SMCOM: the IOP's own mailbox word
        li      $t1, 0x0BADF00D
        sw      $t1, 0($t0)
        lw      $t2, 0($t0)
        nop
        bne     $t2, $t1, fail
        nop
        li      $t0, 0x0C
        sb      $t0, 0($s7)

# ---- 0D: DMA channel 6 (OTC) builds an ordering table ------------------------
# The one DMA channel that needs no peripheral: it walks backwards through RAM
# writing a linked list, each word holding the address of the previous entry
# and the last word written holding 0x00FFFFFF. That makes it the channel that
# can prove the DMA controller with nothing else present.
#   MADR = the highest address, BCR = the number of entries,
#   CHCR = 0x11000002: decrement (bit 1), SyncMode 0, start/busy (bit 24),
#                      trigger (bit 28)
        li      $t0, 0x1F8010F0         # DPCR: enable channel 6 (bits 27-24)
        lw      $t1, 0($t0)
        nop
        lui     $t2, 0x0800
        or      $t1, $t1, $t2
        sw      $t1, 0($t0)
        li      $t0, 0x1F8010F4         # DICR: master enable + channel 6 enable
        lui     $t1, 0x00C0             # bit 23 master enable, bit 22 channel 6
        sw      $t1, 0($t0)             #   (DICR enables are bits 16-22 for ch 0-6)
        lw      $t1, 0($t0)
        nop
        lui     $t2, 0x00C0
        and     $t1, $t1, $t2
        bne     $t1, $t2, fail          # both bits must read back

        li      $t0, 0x1F8010E0         # channel 6 MADR
        li      $t1, 0x0003FFFC         # highest entry: 4 words at 0x3FFF0..0x3FFFC
        sw      $t1, 0($t0)
        li      $t1, 4                  # BCR: four entries
        sw      $t1, 4($t0)
        li      $t1, 0x11000002         # CHCR: decrement, start
        sw      $t1, 8($t0)

        li      $t3, 0x00100000         # spin until start/busy clears
otcw:   lw      $t1, 8($t0)
        nop
        andi    $t2, $t1, 0x0000
        lui     $t2, 0x0100
        and     $t2, $t1, $t2
        beq     $t2, $zero, otcd
        nop
        addiu   $t3, $t3, -1
        bne     $t3, $zero, otcw
        nop
        b       fail                    # never completed
        nop
otcd:
        li      $t0, 0xA003FFFC         # read the table back, uncached
        lw      $t1, 0($t0)
        nop
        li      $t2, 0x0003FFF8
        bne     $t1, $t2, fail          # top entry points at the one below
        nop
        lw      $t1, -4($t0)
        nop
        li      $t2, 0x0003FFF4
        bne     $t1, $t2, fail
        nop
        lw      $t1, -8($t0)
        nop
        li      $t2, 0x0003FFF0
        bne     $t1, $t2, fail
        nop
        lw      $t1, -12($t0)
        nop
        li      $t2, 0x00FFFFFF
        bne     $t1, $t2, fail          # the last word written is the end marker
        nop
        li      $t0, 0x1F8010F4         # DICR: channel 6 flag must be set
        lw      $t1, 0($t0)
        nop
        lui     $t2, 0x4000             # bit 30 = channel 6 flag
        and     $t2, $t1, $t2
        beq     $t2, $zero, fail
        nop
        li      $t0, 0x1F801070         # INTC I_STAT bit 3 (DMA)
        lw      $t1, 0($t0)
        nop
        andi    $t2, $t1, 0x0008
        beq     $t2, $zero, fail
        nop
        li      $t2, 0xFFFFFFF7
        sw      $t2, 0($t0)             # acknowledge
        li      $t0, 0x0D
        sb      $t0, 0($s7)

# ---- 0E: a CDVD sector read, delivered by DMA channel 3 ----------------------
# The read commands are 0x06, 0x07 and 0x08 -- taken from CDVDMAN itself, whose
# dispatcher has exactly three call sites passing eleven parameters (LBA in
# bytes 0-3, sector count in 4-7, then retry, spindle, mode).  Read sector 16,
# which on any ISO9660 disc is the primary volume descriptor: 0x01 'C' 'D' '0'
# '0' '1' 0x01, so word 0 reads back 0x30444301.
        li      $t0, 0x1F8010F0         # DPCR: enable channel 3 (bits 15-12)
        lw      $t1, 0($t0)
        nop
        ori     $t1, $t1, 0x8000
        sw      $t1, 0($t0)
        li      $t0, 0x1F8010F4         # DICR: master enable + channel 3
        lui     $t1, 0x0088             # bit 23 master, bit 19 channel 3
        sw      $t1, 0($t0)

        li      $t0, 0x1F8010B0         # channel 3 (CDVD)
        li      $t1, 0x00050000         # MADR: land the sector at 0x50000
        sw      $t1, 0($t0)
        li      $t1, 512                # BCR: 512 words = one 2048-byte sector
        sw      $t1, 4($t0)
        li      $t1, 0x01000000         # CHCR: to RAM, increment, start
        sw      $t1, 8($t0)

        li      $t0, 0x1F402005         # eleven N parameters
        li      $t1, 16                 # LBA = 16
        sb      $t1, 0($t0)
        sb      $zero, 0($t0)
        sb      $zero, 0($t0)
        sb      $zero, 0($t0)
        li      $t1, 1                  # sector count = 1
        sb      $t1, 0($t0)
        sb      $zero, 0($t0)
        sb      $zero, 0($t0)
        sb      $zero, 0($t0)
        sb      $zero, 0($t0)           # retry
        sb      $zero, 0($t0)           # spindle
        sb      $zero, 0($t0)           # mode: 2048-byte sectors
        li      $t0, 0x1F402004         # N command 0x06: read
        li      $t1, 0x06
        sb      $t1, 0($t0)

        li      $t3, 0x00020000         # wait for the CDVD completion interrupt
                                        # (short enough to report EE rather than
                                        #  outlive the bench's own timeout)
cdvw:   li      $t0, 0x1F402008         # CDVD I_STAT bit 0
        lbu     $t1, 0($t0)
        nop
        andi    $t1, $t1, 0x0001
        bne     $t1, $zero, cdvd
        nop
        addiu   $t3, $t3, -1
        bne     $t3, $zero, cdvw
        nop
        b       fail                    # the read never completed
        nop
cdvd:
        beq     $s6, $zero, cdvdnd      # no disc: a different, equally real check
        nop
        li      $t0, 0xA0050000         # read the sector back, uncached
        lw      $t1, 0($t0)
        nop
        li      $t2, 0x30444301         # 01 'C' 'D' '0'
        bne     $t1, $t2, fail
        nop
        lw      $t1, 4($t0)
        nop
        li      $t2, 0x00013130         # '0' '1' 01 00
        bne     $t1, $t2, fail
        nop
        b       cdvdi
        nop

# With an empty drive the read must be refused, not quietly produce nothing:
# the CDVD answers a read command with error 0x12 and still raises the
# interrupt.  Checking the error code is what makes the empty-drive run a real
# negative control for the disc path rather than a skipped stage.
cdvdnd:
        li      $t0, 0x1F402000
        lbu     $t2, 0x06($t0)          # CDVD error byte
        nop
        li      $t3, 0x12               # 0x12 = no disc
        bne     $t2, $t3, fail
        nop

cdvdi:
        li      $t0, 0x1F801070         # INTC bit 2 (CDVD) must be set
        lw      $t1, 0($t0)
        nop
        andi    $t2, $t1, 0x0004
        beq     $t2, $zero, fail
        nop
        li      $t0, 0x0E
        sb      $t0, 0($s7)

# ---- 0F..11: walk ISO9660 the way the BIOS will ------------------------------
# Stage 0E proves one sector arrives.  These prove the disc is a *filesystem*:
# the volume descriptor names the root directory, the root directory names
# SYSTEM.CNF, and SYSTEM.CNF names the game.  That exercises what a single
# sector cannot -- several reads in a row, a directory walked record by record,
# and an LBA in the millions.  On the Battlefront II disc SYSTEM.CNF is at LBA
# 2,265,115 of 2,278,160, so an LBA truncated to 16 or 20 bits finds the volume
# descriptor and then fails here, which is the failure this stage exists for.
        beq     $s6, $zero, isodone     # no disc: 0A and 0E already covered that
        nop

# 0F: the root directory's extent, from the PVD already at 0x50000.  Byte 156
# of a volume descriptor starts the root directory record; its extent is the
# little-endian word at +2, so byte 158.  Not word-aligned, hence four loads.
        li      $t0, 0xA005009E
        lbu     $t1, 0($t0)
        lbu     $t2, 1($t0)
        lbu     $t3, 2($t0)
        lbu     $t4, 3($t0)
        nop
        sll     $t2, $t2, 8
        sll     $t3, $t3, 16
        sll     $t4, $t4, 24
        or      $s0, $t1, $t2
        or      $s0, $s0, $t3
        or      $s0, $s0, $t4
        beq     $s0, $zero, fail        # a root directory at LBA 0 is not one
        nop
        li      $t0, 0x0F
        sb      $t0, 0($s7)

# 10: read the root directory and find SYSTEM.CNF in it.
        move    $a0, $s0
        li      $a1, 0x00051000
        bgezal  $zero, rdsec
        nop

        li      $s2, 0xA0051000         # cursor over the directory records
        li      $s3, 0                  # bytes consumed
isoscan:
        lbu     $t7, 0($s2)             # record length; 0 ends the sector
        nop
        beq     $t7, $zero, fail        # ran out of records without a match
        nop
        lbu     $t8, 32($s2)            # name length
        nop
        li      $t9, 10
        beq     $t8, $t9, isolen        # "SYSTEM.CNF", or ...
        nop
        li      $t9, 12                 # ... "SYSTEM.CNF;1" -- ISO9660 keeps a
        bne     $t8, $t9, isonext       # version suffix, and this disc uses it
        nop
isolen:
        la      $a2, name_syscnf
        addiu   $a3, $s2, 33
        li      $t4, 10
isocmp:
        lbu     $t5, 0($a2)
        lbu     $t6, 0($a3)
        nop
        bne     $t5, $t6, isonext
        nop
        addiu   $a2, $a2, 1
        addiu   $a3, $a3, 1
        addiu   $t4, $t4, -1
        bne     $t4, $zero, isocmp
        nop
        b       isofound
        nop
isonext:
        addu    $s2, $s2, $t7
        addu    $s3, $s3, $t7
        li      $t9, 2048
        sltu    $t8, $s3, $t9
        bne     $t8, $zero, isoscan
        nop
        b       fail                    # SYSTEM.CNF is not in the first sector
        nop

isofound:
        lbu     $t1, 2($s2)             # the record's extent, little-endian
        lbu     $t2, 3($s2)
        lbu     $t3, 4($s2)
        lbu     $t4, 5($s2)
        nop
        sll     $t2, $t2, 8
        sll     $t3, $t3, 16
        sll     $t4, $t4, 24
        or      $s1, $t1, $t2
        or      $s1, $s1, $t3
        or      $s1, $s1, $t4
        beq     $s1, $zero, fail
        nop
        li      $t0, 0x10
        sb      $t0, 0($s7)

# 11: read SYSTEM.CNF itself and check it names a boot file.  This is the read
# at LBA 2,265,115 -- the one that needs the whole 32-bit LBA to survive the
# CDVD command, the DMA and the disc source.
        move    $a0, $s1
        li      $a1, 0x00052000
        bgezal  $zero, rdsec
        nop
        li      $t0, 0xA0052000
        lw      $t1, 0($t0)
        nop
        li      $t2, 0x544F4F42         # "BOOT"
        bne     $t1, $t2, fail
        nop
        li      $t0, 0x11
        sb      $t0, 0($s7)

# 12: the boot file SYSTEM.CNF names, found in the directory and read.
# "BOOT2 = cdrom0:\SLUS_212.40;1" -- take what follows the backslash up to the
# first control character, which is exactly the name the directory record
# carries, version suffix and all.  Nothing here knows this disc: the name is
# read off the disc and looked up on the disc.
        li      $s4, 0xA0052000
        li      $t9, 256                # bounded: it is a line, not a search
isobs:  lbu     $t5, 0($s4)
        nop
        li      $t6, 0x5C               # '\\'
        beq     $t5, $t6, isobsf
        nop
        addiu   $s4, $s4, 1
        addiu   $t9, $t9, -1
        bne     $t9, $zero, isobs
        nop
        b       fail                    # no path separator: not a BOOT2 line
        nop
isobsf: addiu   $s4, $s4, 1             # first character of the name
        move    $t8, $s4
        li      $s5, 0                  # its length
isolen2:
        lbu     $t5, 0($t8)
        nop
        li      $t6, 0x21               # stop at CR, LF, space -- anything below '!'
        sltu    $t7, $t5, $t6
        bne     $t7, $zero, isolend
        nop
        addiu   $t8, $t8, 1
        addiu   $s5, $s5, 1
        li      $t6, 32
        bne     $s5, $t6, isolen2
        nop
isolend:
        beq     $s5, $zero, fail
        nop

        li      $s2, 0xA0051000         # walk the root directory again
        li      $s3, 0
isoscn2:
        lbu     $t7, 0($s2)
        nop
        beq     $t7, $zero, fail        # the named file is not in this directory
        nop
        lbu     $t8, 32($s2)
        nop
        bne     $t8, $s5, isonxt2
        nop
        move    $a2, $s4
        addiu   $a3, $s2, 33
        move    $t4, $s5
isocmp2:
        lbu     $t5, 0($a2)
        lbu     $t6, 0($a3)
        nop
        bne     $t5, $t6, isonxt2
        nop
        addiu   $a2, $a2, 1
        addiu   $a3, $a3, 1
        addiu   $t4, $t4, -1
        bne     $t4, $zero, isocmp2
        nop
        b       isofnd2
        nop
isonxt2:
        addu    $s2, $s2, $t7
        addu    $s3, $s3, $t7
        li      $t9, 2048
        sltu    $t8, $s3, $t9
        bne     $t8, $zero, isoscn2
        nop
        b       fail
        nop

isofnd2:
        lbu     $t1, 2($s2)
        lbu     $t2, 3($s2)
        lbu     $t3, 4($s2)
        lbu     $t4, 5($s2)
        nop
        sll     $t2, $t2, 8
        sll     $t3, $t3, 16
        sll     $t4, $t4, 24
        or      $a0, $t1, $t2
        or      $a0, $a0, $t3
        or      $a0, $a0, $t4
        beq     $a0, $zero, fail
        nop
        li      $a1, 0x00053000
        bgezal  $zero, rdsec
        nop
        li      $t0, 0xA0053000
        lw      $t1, 0($t0)
        nop
        li      $t2, 0x464C457F         # 0x7F 'E' 'L' 'F'
        bne     $t1, $t2, fail
        nop
        li      $t0, 0x12
        sb      $t0, 0($s7)
isodone:

# ---- 13: SIF0, the IOP sending to the EE -------------------------------------
# Every other channel here writes memory.  This one reads it: the tag is not in
# the stream, it is in RAM at TADR, so the DMA has to fetch six words and then
# the payload.  Needs no disc and no EE -- the host drains what comes out.
        li      $t0, 0xA0070000         # the tag
        li      $t1, 0x00071000         # word 0: where the payload is
        sw      $t1, 0($t0)
        li      $t1, 8                  # word 1: how many words of it
        sw      $t1, 4($t0)
        li      $t1, 0xEE7A6000         # words 2-5: the EE's own tag, which the
        sw      $t1, 8($t0)             # IOP forwards without reading
        li      $t1, 0xEE7A6001
        sw      $t1, 12($t0)
        li      $t1, 0xEE7A6002
        sw      $t1, 16($t0)
        li      $t1, 0xEE7A6003
        sw      $t1, 20($t0)

        li      $t0, 0xA0071000         # the payload
        li      $t2, 0
s0fill: sll     $t4, $t2, 2
        addu    $t5, $t0, $t4
        li      $t6, 0x5150F000
        or      $t6, $t6, $t2
        sw      $t6, 0($t5)
        addiu   $t2, $t2, 1
        li      $t3, 8
        bne     $t2, $t3, s0fill
        nop

        li      $t0, 0x1F801570         # DPCR2 bit 11 enables channel 9, and it
        lw      $t1, 0($t0)             # is clear out of reset
        nop
        ori     $t1, $t1, 0x0800
        sw      $t1, 0($t0)

        li      $t0, 0x1F801520         # channel 9
        li      $t1, 0x00070000         # TADR: the tag
        sw      $t1, 12($t0)
        li      $t1, 0x01000000         # CHCR: start
        sw      $t1, 8($t0)

        li      $t3, 0x00020000         # CHCR bit 24 clears when it is done
s0w:    lw      $t1, 8($t0)
        nop
        lui     $t2, 0x0100
        and     $t1, $t1, $t2
        beq     $t1, $zero, s0done
        nop
        addiu   $t3, $t3, -1
        bne     $t3, $zero, s0w
        nop
        b       fail
        nop
s0done:
        li      $t0, 0x13
        sb      $t0, 0($s7)

# ---- 14: timer 5 with each prescaler -----------------------------------------
# The BIOS drives the IOP's thread scheduler from timer 5, and INTC bit 16 --
# TIMER5 in intrman's numbering -- never fires on this design, so no module
# thread ever runs and no RPC server is ever registered.  Timers 4 and 5 have a
# prescaler in MODE bits 13-14 that timer 3 does not, and that prescaler is the
# one part of iop_timer32.vhd taken from an emulator rather than measured.
# Stage 06 proves timer 3's interrupt; this proves timer 5's, at each divisor.
# $s4 counts the settings that worked, so the POST code says how far it got.
        li      $s4, 0
        li      $s5, 0                  # 00 = /1, then 01 = /8, 10 = /16, 11 = /256
t5next:
        li      $t0, 0xA0001000
        sw      $zero, 0($t0)           # the handler's flag
        li      $t1, 0x1F801070
        li      $t2, 0x00010000         # I_MASK: TIMER5 is bit 16
        sw      $t2, 4($t1)
        sw      $zero, 0($t1)
        li      $t2, 1
        sw      $t2, 8($t1)

        li      $t1, 0x1F8014A0         # timer 5: 0x1F801480 + 2*0x10
        li      $t2, 4096               # reachable even at /256, and far enough away that
                                        # the handler returns before the next one is due --
                                        # 64 counts at /1 is 1.7 us, which re-enters faster
                                        # than the handler can finish and looks like a hang
        sw      $t2, 8($t1)
        sll     $t3, $s5, 13            # the prescaler under test
        li      $t2, 0x0018             # reset on target | IRQ on target, once only
        or      $t2, $t2, $t3
        sw      $t2, 4($t1)

        li      $t2, 0x00400401         # SR: BEV | IM2 | IEc
        mtc0    $t2, $12
        nop
        li      $t3, 3000000
t5wait: lw      $t2, 0($t0)
        addiu   $t3, $t3, -1
        beq     $t3, $zero, t5done      # this divisor never interrupted
        nop
        beq     $t2, $zero, t5wait
        nop
        addiu   $s4, $s4, 1             # this one worked
t5done:
        li      $t2, 0x00400000
        mtc0    $t2, $12
        nop
        addiu   $s5, $s5, 1
        li      $t2, 4
        bne     $s5, $t2, t5next
        nop

# POST 20 + however many of the four divisors raised their interrupt, so a
# partial result is legible: 20 means none, 24 means all four.
        li      $t1, 0xA0001010         # also in RAM: the POST register only holds the
        sw      $s4, 0($t1)             # last value written, and AA follows immediately
        addiu   $t0, $s4, 0x20
        sb      $t0, 0($s7)

# ---- done -----------------------------------------------------------------
        li      $t0, 0xAA
        sb      $t0, 0($s7)
halt:   b       halt
        nop

fail:   li      $t0, 0xEE
        sb      $t0, 0($s7)
fhalt:  b       fhalt
        nop

# ---- rdsec: read one 2048-byte sector -----------------------------------------
# $a0 = LBA, $a1 = destination in IOP RAM.  Clobbers $t0-$t3; DPCR and DICR are
# already set up by 0E.  I_STAT bit 0 is cleared *before* the command: it is
# write-1-to-clear and latches, so a second read would otherwise see the first
# read's completion still standing and return immediately with a stale buffer.
rdsec:
        li      $t0, 0x1F402008
        li      $t1, 0x01
        sb      $t1, 0($t0)             # clear the previous completion

        li      $t0, 0x1F8010B0         # channel 3 (CDVD)
        sw      $a1, 0($t0)             # MADR
        li      $t1, 512                # BCR: 512 words = one sector
        sw      $t1, 4($t0)
        li      $t1, 0x01000000         # CHCR: to RAM, increment, start
        sw      $t1, 8($t0)

        li      $t0, 0x1F402005         # eleven N parameters, LBA first
        sb      $a0, 0($t0)
        srl     $t1, $a0, 8
        sb      $t1, 0($t0)
        srl     $t1, $a0, 16
        sb      $t1, 0($t0)
        srl     $t1, $a0, 24
        sb      $t1, 0($t0)
        li      $t1, 1
        sb      $t1, 0($t0)             # one sector
        sb      $zero, 0($t0)
        sb      $zero, 0($t0)
        sb      $zero, 0($t0)
        sb      $zero, 0($t0)           # retry
        sb      $zero, 0($t0)           # spindle
        sb      $zero, 0($t0)           # mode: 2048-byte sectors
        li      $t0, 0x1F402004
        li      $t1, 0x06
        sb      $t1, 0($t0)

        li      $t3, 0x00020000
rdsecw: li      $t0, 0x1F402008
        lbu     $t1, 0($t0)
        nop
        andi    $t1, $t1, 0x0001
        bne     $t1, $zero, rdsecd
        nop
        addiu   $t3, $t3, -1
        bne     $t3, $zero, rdsecw
        nop
        b       fail
        nop
rdsecd: jr      $ra
        nop

.align 4
name_syscnf:
        .word   0x54535953              # 'S' 'Y' 'S' 'T'
        .word   0x432E4D45              # 'E' 'M' '.' 'C'
        .word   0x0000464E              # 'N' 'F'

# ---- routine that runs from RAM: sum 1..100 in $v0 ----------------------------
.align 4
ram_code:
        move    $v0, $zero
        li      $a0, 100
sum:    addu    $v0, $v0, $a0
        addiu   $a0, $a0, -1
        bne     $a0, $zero, sum
        nop
        jr      $ra
        nop
ram_code_end:
        nop
