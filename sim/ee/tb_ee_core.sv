// tb_ee_core.sv -- run a program on the R5900 integer datapath and print the
// architectural state after every retired instruction, in the format
// sim/ee/r5900_ref.py prints, so the two can be diffed line for line.
//
// The memories answer with latency rather than combinationally.  A core that
// only works with zero-latency memory passes its testbench and fails on the
// card, and the wait states are where a state machine gets its handshake
// wrong.  Both ports take their latency from a plusarg:
//
//   +ilat=N  instruction port, cycles from request to reply (default 1)
//   +dlat=N  data port, likewise (default 1)
//
// The instruction port is pipelined -- a request every cycle is answered every
// cycle -- and that matters more than it looks.  The earlier model could only
// answer every other cycle, which meant dependent instructions were never
// adjacent in the pipeline, so not one forwarding path was ever exercised.  A
// testbench that cannot produce the hazard cannot find the bug.
`timescale 1ns/1ps

module tb_ee_core;
   logic clk = 0, reset = 1;
   always #5 clk = ~clk;

   logic [31:0] i_addr;
   wire  [31:0] i_data;
   logic        i_read;
   wire         i_ready;
   logic [31:0] d_addr;
   logic        d_read, d_write, d_ready;
   logic [7:0]  d_be;
   logic [63:0] d_wdata, d_rdata;
   logic        retire;
   logic [63:0] retire_pc, dbg_gpr, dbg_hi, dbg_lo, dbg_hi1, dbg_lo1;
   logic [4:0]  dbg_sel = 0;
   logic [15:0] dbg_traps;
   logic [2:0]  dbg_stall;
   integer      stallcnt [0:5];

   ee_core dut (
      .clk(clk), .reset(reset), .pc_reset(32'h0000_0000),
      .i_addr(i_addr), .i_read(i_read), .i_data(i_data), .i_ready(i_ready),
      .d_addr(d_addr), .d_read(d_read), .d_write(d_write), .d_be(d_be),
      .d_wdata(d_wdata), .d_rdata(d_rdata), .d_ready(d_ready),
      .retire(retire), .retire_pc(retire_pc),
      .dbg_sel(dbg_sel), .dbg_gpr(dbg_gpr), .dbg_hi(dbg_hi), .dbg_lo(dbg_lo),
      .dbg_hi1(dbg_hi1), .dbg_lo1(dbg_lo1),
      .dbg_traps(dbg_traps), .dbg_stall(dbg_stall));

   localparam MEMBYTES = 1 << 16;
   logic [7:0]  mem      [0:MEMBYTES-1];
   logic [31:0] memwords [0:4095];

   integer ilat = 1, dlat = 1;

   // ---- instruction port: pipelined, ilat cycles of latency ----------------
   // A delay line rather than a single pending request, because the core now
   // keeps several requests in flight and a model that tracks one would quietly
   // drop the rest -- which would look exactly like a core that cannot fetch.
   localparam MAXL = 16;
   logic [31:0] ipd [0:MAXL-1];
   logic        ipv [0:MAXL-1];
   integer      k;
   always_ff @(posedge clk) begin
      for (k = MAXL-1; k > 0; k = k - 1) begin
         ipd[k] <= ipd[k-1];
         ipv[k] <= ipv[k-1];
      end
      // The instruction address space is aliased to the size of this image, so
      // the exception vector at 0x80000180 lands inside a program that can be
      // loaded.  sim/ee/r5900_ref.py masks identically.  A harness convention,
      // not architecture: without it an exception test would need a megabyte of
      // mostly-empty image and the handler could never be reached.
      ipd[0] <= {mem[(i_addr & 32'hFFFF)+3], mem[(i_addr & 32'hFFFF)+2],
                 mem[(i_addr & 32'hFFFF)+1], mem[(i_addr & 32'hFFFF)]};
      ipv[0] <= i_read;
   end
   assign i_data  = ipd[ilat-1];
   assign i_ready = ipv[ilat-1];

   // ---- data port: 64 bits with byte enables, dlat cycles of latency -------
   integer      bi;
   logic        dpend = 0;
   integer      dcnt  = 0;
   logic [31:0] daddr_l;
   logic [63:0] dwdata_l;
   logic [7:0]  dbe_l;
   logic        dwr_l;

   task automatic do_access(input [31:0] ad, input [63:0] wd,
                            input [7:0] be, input wr);
      begin
         if (wr)
            for (bi = 0; bi < 8; bi = bi + 1)
               if (be[bi]) mem[(ad & ~32'h7) + bi] = wd[bi*8 +: 8];
         for (bi = 0; bi < 8; bi = bi + 1)
            d_rdata[bi*8 +: 8] <= mem[(ad & ~32'h7) + bi];
      end
   endtask

   always_ff @(posedge clk) begin
      d_ready <= 1'b0;
      if ((d_read || d_write) && !dpend && !d_ready) begin
         if (dlat <= 1) begin
            do_access(d_addr, d_wdata, d_be, d_write);
            d_ready <= 1'b1;
         end else begin
            dpend    <= 1'b1;
            dcnt     <= dlat - 1;
            daddr_l  <= d_addr;
            dwdata_l <= d_wdata;
            dbe_l    <= d_be;
            dwr_l    <= d_write;
         end
      end else if (dpend) begin
         if (dcnt > 1) dcnt <= dcnt - 1;
         else begin
            do_access(daddr_l, dwdata_l, dbe_l, dwr_l);
            d_ready <= 1'b1;
            dpend   <= 1'b0;
         end
      end
   end

   // ---- run and report -----------------------------------------------------
   string  progfile;   // 'program' is a SystemVerilog keyword
   integer steps, n, r, budget, cycles;
   logic [63:0] regs [1:31];

   initial begin
      if (!$value$plusargs("program=%s", progfile)) progfile = "prog.hex";
      if (!$value$plusargs("steps=%d", steps))     steps = 64;
      void'($value$plusargs("ilat=%d", ilat));
      void'($value$plusargs("dlat=%d", dlat));
      for (n = 0; n < MEMBYTES; n = n + 1) mem[n] = 8'h00;
      for (n = 0; n < MAXL; n = n + 1) begin ipd[n] = 32'h0; ipv[n] = 1'b0; end
      $readmemh(progfile, memwords);
      // $readmemh fills 32-bit words; spread them into the byte array
      for (n = 0; n < 4096; n = n + 1) begin
         mem[n*4+0] = memwords[n][7:0];
         mem[n*4+1] = memwords[n][15:8];
         mem[n*4+2] = memwords[n][23:16];
         mem[n*4+3] = memwords[n][31:24];
      end
      repeat (4) @(posedge clk);
      reset <= 0;

      n = 0;
      // A hang has to end as a report, not as a simulation that never returns.
      // The bound is generous: a divide is ~35 cycles and a stalled memory
      // access several more, so 200 cycles per instruction cannot be reached
      // by a core that is merely slow.
      budget = steps * 200 + 1000;
      cycles = 0;
      for (n = 0; n <= 5; n = n + 1) stallcnt[n] = 0;
      n = 0;
      while (n < steps && budget > 0) begin
         // Sample a short way past the edge, not on it: retire and retire_pc
         // are driven by the same edge that would be read here, and reading
         // them on the edge while reading the registers after it takes the two
         // from different cycles -- which shows up as a PC shifted by exactly
         // one instruction while every register still matches.
         @(posedge clk);
         #0.1;
         budget = budget - 1;
         cycles = cycles + 1;
         stallcnt[dbg_stall] = stallcnt[dbg_stall] + 1;
         if (retire) begin
            // dbg_gpr is combinational from dbg_sel, so all 31 can be read
            // between edges; 31 x 0.1ns stays well inside a 10ns period.
            for (r = 1; r <= 31; r = r + 1) begin
               dbg_sel = r[4:0];
               #0.1 regs[r] = dbg_gpr;
            end
            $write("%4d pc=%016x hi=%016x lo=%016x hi1=%016x lo1=%016x",
                   n, retire_pc, dbg_hi, dbg_lo, dbg_hi1, dbg_lo1);
            for (r = 1; r <= 31; r = r + 1) $write(" r%02d=%016x", r, regs[r]);
            $write("\n");
            n = n + 1;
         end
      end
      if (budget <= 0)
         $display("# STALLED after %0d of %0d instructions", n, steps);
      // Cycles per instruction, so a timing change that only bought its clock
      // back by inserting stalls shows up as such.  Fmax alone is the wrong
      // figure of merit for a pipeline; Fmax divided by CPI is the right one.
      // The line starts with '#' so it stays out of the diffed trace.
      $display("# cycles: %0d for %0d instructions (CPI %0d.%02d)",
               cycles, n, cycles / n, (cycles * 100 / n) % 100);
      $display("# where the cycles went: issued=%0d dport=%0d muldiv=%0d loaduse=%0d fetch=%0d flush=%0d",
               stallcnt[0], stallcnt[1], stallcnt[2], stallcnt[3], stallcnt[4], stallcnt[5]);
      // The same region the reference dumps: a store to the wrong address is
      // invisible in the registers until something loads it back.
      for (n = 'h2000; n < 'h2400; n = n + 8)
         $write("MEM %08x %02x%02x%02x%02x%02x%02x%02x%02x\n", n,
                mem[n+7], mem[n+6], mem[n+5], mem[n+4],
                mem[n+3], mem[n+2], mem[n+1], mem[n+0]);
      if (dbg_traps != 0) $display("# traps: %0d", dbg_traps);
      $finish;
   end

endmodule
