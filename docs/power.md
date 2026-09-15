# Power

A PlayStation 2 that draws a laptop's worth of power is a curiosity; one that
draws a PlayStation 2's worth is a product. This page records what the card
actually pulls, measured and modelled, and where it goes.

## The rails, and who sets them

The C1100's satellite controller owns VCCINT, VCCBRAM and VCCMEM, and the fabric
has no I2C route to the regulator. A card running **extended controller
firmware** implements a command that moves those rails; stock firmware does not.
[UltraScale+ Voltage
Control](https://github.com/Dracnea/UltrascalePlusVoltageControl) speaks that
protocol directly over a small bridge bitstream:

```sh
./changeVoltage.sh --vccint 720 --vccbram 720 --vccmem min
```

The setpoint is global and survives reconfiguration, so whatever is loaded next
inherits it.

**What this project runs on, and why each number:**

| rail | setting | reason |
|---|---|---|
| VCCINT | 720 mV | the `-2LV` speed model every timing closure here is signed off against is characterised at 0.72 V |
| VCCBRAM | 720 mV | UltraScale+ low-voltage operation has VCCBRAM track VCCINT; the GS build uses 23 BRAM tiles, so the rail is live |
| VCCMEM | 1050 mV | the GS build instantiates no HBM at all (`HBM_REF_CLK 0`, both BLI interfaces 0). It must go back to `default` before any build that uses HBM |

Verified on the card on 2026-09-14: SYSMON read back 720 mV on-die against a
commanded 720, and the GS then passed all fourteen differential streams by full
4 MB checksum, held 147.4562 MHz, and turned in the same fill rates as at
0.85 V. Undervolting to the low-voltage model cost nothing measurable.

## Where the 4.18 W goes

From `report_power` on the routed GS checkpoint. Note the part is
`xcu55n-fsvh2892-2LV-e`, so Vivado **already models VCCINT at 0.720 V** — the
figure was never an 0.85 V estimate that needed correcting, which is worth
stating because it is the obvious thing to assume and it is wrong.

```
  Vccint             0.720 V x 1.733 A =  1.248 W
  Vccaux             1.800 V x 0.664 A =  1.195 W
  VMGTAVTT (GTY)     1.200 V x 0.776 A =  0.931 W
  VMGTAVCC (GTY)     0.900 V x 0.242 A =  0.218 W
  Vccint_io          0.850 V x 0.205 A =  0.174 W
  VCC_IO_HBM         1.200 V x 0.082 A =  0.098 W
  VCC_HBM            1.200 V x 0.077 A =  0.092 W
  VCCAUX_HBM         2.500 V x 0.022 A =  0.055 W
  Vccaux_io          1.800 V x 0.028 A =  0.050 W
  VMGTVCCAUX (GTY)   1.800 V x 0.026 A =  0.047 W
  Vccbram            0.850 V x 0.049 A =  0.042 W
  Vccadc             1.800 V x 0.016 A =  0.029 W
  TOTAL                                    4.180 W
```

**The console logic is 1.25 W of that.** Everything else is the platform:

- **1.20 W of VCCAUX**, 83% of it static. This is the fixed cost of an
  UltraScale+ part being powered on at all. Nothing in a design changes it, and
  the satellite controller cannot move that rail.
- **1.20 W of GTY transceivers** driving the PCIe x4 Gen3 link. A PlayStation 2
  has no PCIe; this is the cost of the host being the display and the disc
  drive. It is the largest single item we could ever remove, and removing it
  means giving the card its own video and storage.
- **0.25 W of HBM rails** with no HBM instantiated — the stacks are on the
  package whether or not a design uses them. Dropping VCCMEM to 1050 mV trims
  this slightly; it cannot go to zero.

## Against the console being copied

A fat PlayStation 2 (SCPH-30000 series) draws roughly 45 W at the wall; the slim
SCPH-70000 roughly 35 W. Even allowing generously for the host PSU's efficiency
and for the EE, IOP, SPU2 and memory still to be added, **the power requirement
is met with a very large margin** — the card is an order of magnitude under the
console.

That reframes the constraint. Power is not the thing that limits how much of the
PlayStation 2 can be built here; the fabric's clock ceiling is. When the EE
lands, the interesting question will be whether it closes at 294.912 MHz, not
whether the card can afford to run it.

## What is not yet measured

Everything above is Vivado's model. The satellite controller's `0x05` SENSORS
command reads the card's own current sensors and would give a measured board
figure instead — that needs the card off the PCIe bus and the bridge bitstream
loaded, so it belongs in the same session as the next voltage change rather than
as a reason to interrupt one.
