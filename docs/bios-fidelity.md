# Patching the BIOS, and what it costs in fidelity

The IOP's boot messages are the best diagnostic this project has, and a retail
BIOS throws them away: `printf` formats into a buffer and flushes through IOMAN
to file descriptor 1, and with no tty device bound the bytes are discarded. They
never reach SIO1, which is the port `rtl/iop/iop_console.vhd` implements.

`tools/ps2iop/bios_patch.py` replaces the kernel's character sink with eight
instructions that store each character to SIO1's data register. That produces a
**modified BIOS**, and this page is about what that does and does not
compromise, because the answer decides whether results obtained with it mean
anything.

## The hardware is not touched

The gateware is byte-identical with or without the patch. No register changes
behaviour, no timing changes, nothing is stubbed or special-cased. SIO1 at
`0x1F801050` is a real IOP peripheral that a real IOP has; the patched BIOS
writes to it the way any program may, and `iop_console.vhd` answers exactly as
the hardware does — status reports TX ready, writes to DATA are accepted.

That is the distinction that matters. **This project simulates PS2 hardware.
The BIOS is an input to that hardware, not part of it.** A patched BIOS is a
different program running on the same machine, in the same sense that any
homebrew, any custom firmware, or any of the modified BIOS images the scene has
used for twenty years is a different program. None of those make the console
underneath less real.

The test for whether a change compromises fidelity is: *would this make the
hardware behave differently for an unmodified program?* The answer here is no.
Compare with a change that would fail that test — special-casing a register a
particular BIOS reads, or short-circuiting a handshake because the real one is
inconvenient. Those alter the machine. This alters a program that runs on it.

## Running a custom BIOS is a goal, not a workaround

A full hardware simulation must be able to run whatever the user puts in ROM.
The ROM image arrives from the host (`iop_post.py load`), so custom images were
always going to be supported, and this is the first thing that exercises that
path seriously. If a patched image had failed to boot, that would have been a
finding about the ROM path worth having.

It boots identically. The eleven lines the patched BIOS prints are the stock
boot sequence, in order, with the same modules resident and the same POST codes.

## What it does cost

Three things, stated so a result that depends on them can be discounted:

* **The image is not bit-identical**, so anything checksumming the ROM sees a
  different BIOS. Nothing here does, but a future integrity check would.
* **The character sink no longer buffers.** The original accumulated into a
  buffer and flushed; the patch stores each character as it arrives. That is a
  store per character instead of one IOMAN call per line, so the timing of a
  printing module differs slightly from stock. It is *less* work than the
  original path, not more, because the IOMAN call is gone.
* **Control codes are dropped.** The sink's non-character commands (512, 513)
  are ignored rather than handled, so `\r` insertion is lost. Output is `\n`
  terminated rather than `\r\n`. Nothing depends on this.

None of it touches the console being simulated, and none of it is needed for
anything but reading the log. **The stock BIOS is what gets tested; the patched
one is what gets read** — and where a result rests on the patched image, the
place it is written down says so.

## What it bought

Immediately, and after three rounds of disassembly had failed to settle it: the
boot log showed FILEIO printing its banner and then stopping, which located the
block precisely, and led to the discovery that `SIF_CMD_INIT_CMD` carries a
second meaning in its `opt` field — `opt == 0` records the EE's buffer, `opt != 0`
releases the modules waiting to register their RPC services. That is one branch
in one handler, and no amount of reading structures from the outside was going
to reveal it.
