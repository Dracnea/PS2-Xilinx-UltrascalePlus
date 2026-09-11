// tb_ee_top.sv -- the same retire trace tb_ee_core.sv prints, but with the core
// running out of ee_ram and a behavioural HBM instead of a flat model memory.
//
// What this can find that tb_ee_core.sv cannot: everything about the join.  The
// arbiter between the fetch and data ports, the conversion between the core's
// held strobes and ee_ram's req/ack, the fetch queue that holds three requests
// while the memory answers one at a time, and the cache itself -- a line fill
// takes tens of cycles, which is a latency the core has never been shown.
//
// The instruction address space aliases to 32 MB here rather than to the 64 KB
// tb_ee_core.sv uses, and the two agree for everything a generated program
// does: a program lives below 64 KB, and the exception vector 0x80000180 masks
// to 384 either way.
`timescale 1ns/1ps

module tb_ee_top;
   logic clk = 0, reset = 1;
   always #5 clk = ~clk;
   localparam AXI_LATENCY = 8;

   logic        retire;
   logic [63:0] retire_pc, dbg_hi, dbg_lo, dbg_hi1, dbg_lo1;
   logic [127:0] dbg_gpr;
   logic [4:0]  dbg_sel = 0;
   logic [3:0]  dbg_sa;
   logic [15:0] dbg_traps;
   logic [2:0]  dbg_stall;
   logic [31:0] hits, miss;

   logic [32:0] awaddr, araddr;
   logic [7:0]  awlen, arlen;
   logic        awvalid, arvalid, wvalid, wlast, bvalid, rvalid, rlast;
   logic        awready = 0, arready = 0, wready = 0, bready, rready;
   logic [255:0] wdata_axi, rdata_axi;
   logic [31:0]  wstrb;
   logic         bvalid_r = 0, rvalid_r = 0, rlast_r = 0;

   assign bvalid = bvalid_r;
   assign rvalid = rvalid_r;
   assign rlast  = rlast_r;

   ee_top #(.ADDR_BITS(25), .LINE_LOG2(6), .INDEX_LOG2(9)) dut (
      .clk(clk), .reset(reset), .pc_reset(32'h0000_0000),
      .stat_hits(hits), .stat_miss(miss),
      .m_awaddr(awaddr), .m_awlen(awlen), .m_awsize(), .m_awburst(),
      .m_awvalid(awvalid), .m_awready(awready),
      .m_wdata(wdata_axi), .m_wstrb(wstrb), .m_wlast(wlast),
      .m_wvalid(wvalid), .m_wready(wready),
      .m_bvalid(bvalid), .m_bready(bready),
      .m_araddr(araddr), .m_arlen(arlen), .m_arsize(), .m_arburst(),
      .m_arvalid(arvalid), .m_arready(arready),
      .m_rdata(rdata_axi), .m_rlast(rlast), .m_rvalid(rvalid), .m_rready(rready),
      .retire(retire), .retire_pc(retire_pc),
      .dbg_sel(dbg_sel), .dbg_gpr(dbg_gpr),
      .dbg_hi(dbg_hi), .dbg_lo(dbg_lo), .dbg_hi1(dbg_hi1), .dbg_lo1(dbg_lo1),
      .dbg_sa(dbg_sa), .dbg_traps(dbg_traps), .dbg_stall(dbg_stall));

   // ---- behavioural HBM, as sim/mem/tb_mem.sv models it --------------------
   reg [255:0] hbm [0:65535];
   localparam [32:0] HBM_BASE = 33'h1_8000_0000;
   function [15:0] beat_of(input [32:0] a);
      beat_of = (a - HBM_BASE) >> 5;
   endfunction

   initial begin : wr_ch
      forever begin
         @(posedge clk);
         if (awvalid) begin
            repeat (AXI_LATENCY) @(posedge clk);
            awready <= 1; @(posedge clk); awready <= 0;
            wready  <= 1;
            while (!(wvalid && wlast)) @(posedge clk);
            begin : do_write
               reg [255:0] cur; integer b;
               cur = hbm[beat_of(awaddr)];
               for (b = 0; b < 32; b = b + 1)
                  if (wstrb[b]) cur[b*8 +: 8] = wdata_axi[b*8 +: 8];
               hbm[beat_of(awaddr)] = cur;
            end
            @(posedge clk); wready <= 0;
            repeat (2) @(posedge clk);
            bvalid_r <= 1;
            while (!bready) @(posedge clk);
            @(posedge clk); bvalid_r <= 0;
         end
      end
   end

   initial begin : rd_ch
      forever begin
         @(posedge clk);
         if (arvalid) begin
            repeat (AXI_LATENCY) @(posedge clk);
            arready <= 1; @(posedge clk); arready <= 0;
            begin : do_read
               integer n;
               for (n = 0; n <= arlen; n = n + 1) begin
                  rdata_axi <= hbm[beat_of(araddr) + n];
                  rlast_r   <= (n == arlen);
                  rvalid_r  <= 1;
                  @(posedge clk);
                  while (!rready) @(posedge clk);
               end
               rvalid_r <= 0; rlast_r <= 0;
            end
         end
      end
   end

   // ---- run and report, in tb_ee_core.sv's format --------------------------
   string  progfile;
   integer steps, n, r, budget, cycles;
   logic [127:0] regs [1:31];
   logic [31:0] memwords [0:4095];

   initial begin
      if (!$value$plusargs("program=%s", progfile)) progfile = "prog.hex";
      if (!$value$plusargs("steps=%d", steps))     steps = 64;
      for (n = 0; n < 65536; n = n + 1) hbm[n] = 256'h0;
      $readmemh(progfile, memwords);
      // the program image, spread into HBM beats: eight 32-bit words per beat
      for (n = 0; n < 4096; n = n + 1)
         hbm[n / 8][(n % 8) * 32 +: 32] = memwords[n];

      repeat (4) @(posedge clk);
      reset <= 0;

      n = 0;
      // A line fill is tens of cycles and every miss pays it, so the budget is
      // far larger than tb_ee_core.sv's: a cold cache walking a program is the
      // normal case here, not a stall.
      budget = steps * 4000 + 200000;
      cycles = 0;
      while (n < steps && budget > 0) begin
         @(posedge clk);
         #0.1;
         budget = budget - 1;
         cycles = cycles + 1;
         if (retire) begin
            for (r = 1; r <= 31; r = r + 1) begin
               dbg_sel = r[4:0];
               #0.1 regs[r] = dbg_gpr;
            end
            $write("%4d pc=%016x hi=%016x lo=%016x hi1=%016x lo1=%016x sa=%02x",
                   n, retire_pc, dbg_hi, dbg_lo, dbg_hi1, dbg_lo1, dbg_sa);
            for (r = 1; r <= 31; r = r + 1) $write(" r%02d=%032x", r, regs[r]);
            $write("\n");
            n = n + 1;
         end
      end
      if (budget <= 0)
         $display("# STALLED after %0d of %0d instructions", n, steps);
      $display("# cycles: %0d for %0d instructions (CPI %0d.%02d)",
               cycles, n, cycles / n, (cycles * 100 / n) % 100);
      $display("# cache: %0d hits, %0d misses", hits, miss);
      $finish;
   end
endmodule
