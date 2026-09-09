// tb_mem.sv -- the GS local memory and the EE main memory, checked together.
//
// Two blocks, two questions:
//
//   gs_lmem  -- does a 4 MB UltraRAM with a 256-bit dual port return what was
//               written, at the right address, with byte enables honoured?
//
//   ee_ram   -- does a write-through cache in front of a *behavioural HBM with
//               real latency* return what was written, and does it actually
//               cache?  The second half matters more than the first: a cache
//               that is merely correct and never hits is a slow memory with
//               extra bugs, so the bench checks the hit and miss counters and
//               fails if the numbers are not what the access pattern implies.
//
// The HBM model answers after AXI_LATENCY cycles rather than immediately, which
// is the whole reason the cache exists; with a zero-latency model the design
// would pass while hiding nothing.

`timescale 1ns/1ps

module tb_mem;

   localparam AXI_LATENCY = 30;      // ~120 ns at 250 MHz, HBM's rough figure

   reg clk = 0, reset = 1;
   always #2 clk = ~clk;             // 250 MHz
   integer errors = 0;

   task check(input [255:0] got, input [255:0] want, input [255:0] what);
      begin
         if (got !== want) begin
            $display("FAIL %0s: got %064x want %064x", what, got, want);
            errors = errors + 1;
         end
      end
   endtask

   // ---------------------------------------------------------------- gs_lmem
   reg          gs_wr_en = 0, gs_rd_en = 0;
   reg  [16:0]  gs_wr_addr = 0, gs_rd_addr = 0;   // 256-bit words, 2^17 = 4 MB
   reg  [255:0] gs_wr_data = 0;
   reg  [31:0]  gs_wr_be   = 0;
   wire [255:0] gs_rd_data;
   wire         gs_rd_valid;

   gs_lmem #(.ADDR_BITS(17), .DATA_WIDTH(256)) gs (
      .clk(clk),
      .wr_en(gs_wr_en), .wr_addr(gs_wr_addr), .wr_data(gs_wr_data), .wr_be(gs_wr_be),
      .rd_en(gs_rd_en), .rd_addr(gs_rd_addr), .rd_data(gs_rd_data), .rd_valid(gs_rd_valid)
   );

   task gs_write(input [16:0] a, input [255:0] d, input [31:0] be);
      begin
         @(posedge clk); gs_wr_en <= 1; gs_wr_addr <= a; gs_wr_data <= d; gs_wr_be <= be;
         @(posedge clk); gs_wr_en <= 0;
      end
   endtask

   task gs_read(input [16:0] a, output [255:0] d);
      begin
         @(posedge clk); gs_rd_en <= 1; gs_rd_addr <= a;
         @(posedge clk); gs_rd_en <= 0;
         @(posedge clk); @(posedge clk);   // two-cycle URAM latency
         d = gs_rd_data;
      end
   endtask

   // ----------------------------------------------------------------- ee_ram
   reg          ee_req = 0, ee_we = 0;
   reg  [24:0]  ee_addr = 0;
   reg  [127:0] ee_wdata = 0;
   reg  [15:0]  ee_wbe = 0;
   wire         ee_ack;
   wire [127:0] ee_rdata;
   wire [31:0]  ee_hits, ee_miss;

   wire [32:0]  awaddr, araddr;
   wire [7:0]   awlen, arlen;
   wire         awvalid, wvalid, wlast, bready, arvalid, rready;
   wire [255:0] wdata_axi;
   wire [31:0]  wstrb;
   reg          awready = 0, wready = 0, bvalid = 0, arready = 0, rvalid = 0, rlast = 0;
   reg  [255:0] rdata_axi = 0;

   ee_ram #(.ADDR_BITS(25), .LINE_LOG2(6), .INDEX_LOG2(9)) ee (
      .clk(clk), .reset(reset),
      .req(ee_req), .we(ee_we), .addr(ee_addr), .wdata(ee_wdata), .wbe(ee_wbe),
      .ack(ee_ack), .rdata(ee_rdata),
      .stat_hits(ee_hits), .stat_miss(ee_miss),
      .m_awaddr(awaddr), .m_awlen(awlen), .m_awsize(), .m_awburst(),
      .m_awvalid(awvalid), .m_awready(awready),
      .m_wdata(wdata_axi), .m_wstrb(wstrb), .m_wlast(wlast), .m_wvalid(wvalid), .m_wready(wready),
      .m_bvalid(bvalid), .m_bready(bready),
      .m_araddr(araddr), .m_arlen(arlen), .m_arsize(), .m_arburst(),
      .m_arvalid(arvalid), .m_arready(arready),
      .m_rdata(rdata_axi), .m_rlast(rlast), .m_rvalid(rvalid), .m_rready(rready)
   );

   // ---- behavioural HBM: a sparse memory that answers slowly ---------------
   reg [255:0] hbm [0:65535];        // sparse-ish window, indexed by beat
   integer     i;
   // 6 GiB base, in 32-byte beats
   localparam [32:0] HBM_BASE = 33'h1_8000_0000;
   function [15:0] beat_of(input [32:0] a);
      beat_of = (a - HBM_BASE) >> 5;
   endfunction

   // write channel
   initial begin
      forever begin
         @(posedge clk);
         if (awvalid) begin
            repeat (AXI_LATENCY) @(posedge clk);
            awready <= 1; @(posedge clk); awready <= 0;
            wready  <= 1;
            while (!(wvalid && wlast)) @(posedge clk);
            begin : do_write
               reg [255:0] cur;
               integer b;
               cur = hbm[beat_of(awaddr)];
               for (b = 0; b < 32; b = b + 1)
                  if (wstrb[b]) cur[b*8 +: 8] = wdata_axi[b*8 +: 8];
               hbm[beat_of(awaddr)] = cur;
            end
            @(posedge clk); wready <= 0;
            repeat (2) @(posedge clk);
            bvalid <= 1;
            while (!bready) @(posedge clk);
            @(posedge clk); bvalid <= 0;
         end
      end
   end

   // read channel: a burst of arlen+1 beats, after the latency
   initial begin
      forever begin
         @(posedge clk);
         if (arvalid) begin
            repeat (AXI_LATENCY) @(posedge clk);
            arready <= 1; @(posedge clk); arready <= 0;
            begin : do_read
               integer n;
               for (n = 0; n <= arlen; n = n + 1) begin
                  rdata_axi <= hbm[beat_of(araddr) + n];
                  rlast     <= (n == arlen);
                  rvalid    <= 1;
                  @(posedge clk);
                  while (!rready) @(posedge clk);
               end
               rvalid <= 0; rlast <= 0;
            end
         end
      end
   end

   task ee_write(input [24:0] a, input [127:0] d, input [15:0] be);
      begin
         @(posedge clk); ee_req <= 1; ee_we <= 1; ee_addr <= a; ee_wdata <= d; ee_wbe <= be;
         @(posedge clk); ee_req <= 0;
         while (!ee_ack) @(posedge clk);
      end
   endtask

   task ee_read(input [24:0] a, output [127:0] d);
      begin
         @(posedge clk); ee_req <= 1; ee_we <= 0; ee_addr <= a;
         @(posedge clk); ee_req <= 0;
         while (!ee_ack) @(posedge clk);
         d = ee_rdata;
      end
   endtask

   // Cycle trace of the AXI handshakes, switched on around one access.  Only
   // plain SV signals: a $display touching the VHDL enum `ee.state` produced no
   // output at all in xsim rather than an error.
   reg probe_on = 0; integer probe_n = 0;
   always @(posedge clk) if (probe_on && probe_n < 120) begin
      probe_n <= probe_n + 1;
      $display("   t%0t aw %b/%b  w %b/%b last%b  b %b/%b  ar %b/%b  r %b/%b last%b  ack %b",
               $time, awvalid, awready, wvalid, wready, wlast,
               bvalid, bready, arvalid, arready, rvalid, rready, rlast, ee_ack);
   end

   // ------------------------------------------------------------------ test
   reg [255:0] q;
   reg [127:0] d;
   integer     t0, t_miss, t_hit;
   integer     h0, m0;

   initial begin
      for (i = 0; i < 65536; i = i + 1) hbm[i] = 256'h0;
      repeat (10) @(posedge clk);
      reset <= 0;
      repeat (5) @(posedge clk);

      // ---- gs_lmem ------------------------------------------------------
      $display("-- gs_lmem: 4 MB, 256-bit port");
      gs_write(17'd0,     {8{32'hA5A5_0000}}, 32'hFFFFFFFF);
      gs_write(17'd2,     {8{32'h1234_5678}}, 32'hFFFFFFFF);
      gs_write(17'd262142,{8{32'hDEAD_BEEF}}, 32'hFFFFFFFF);   // last access in 4 MB
      gs_read(17'd0,      q); check(q, {8{32'hA5A5_0000}}, "gs row 0");
      gs_read(17'd2,      q); check(q, {8{32'h1234_5678}}, "gs row 2");
      gs_read(17'd262142, q); check(q, {8{32'hDEAD_BEEF}}, "gs last word");
      gs_read(17'd0,      q); check(q, {8{32'hA5A5_0000}}, "gs row 0 still");

      // byte enables must leave the rest alone
      gs_write(17'd4, {8{32'h0000_0000}}, 32'hFFFFFFFF);
      gs_write(17'd4, 256'hFF, 32'h00000001);
      gs_read (17'd4, q);
      check(q, 256'hFF, "gs byte enable");

      // ---- ee_ram -------------------------------------------------------
      $display("-- ee_ram: 32 MB in HBM behind a write-through cache");

      // a write, then a read of the same address: the write goes to HBM, the
      // read misses (write-through does not allocate) and fetches the line
      // set probe_on around any access to get a cycle trace of the handshakes
      ee_write(25'h00_1000, 128'hCAFEBABE_00000000_00000000_00001111, 16'hFFFF);
      ee_read (25'h00_1000, d);
      check({128'h0, d}, {128'h0, 128'hCAFEBABE_00000000_00000000_00001111}, "ee write then read");

      // the rest of that line came from HBM as zeros; check a neighbour in the
      // same line reads back zero rather than stale bus data
      ee_read (25'h00_1010, d);
      check({128'h0, d}, 256'h0, "ee neighbour in line");

      // ---- does it actually cache? --------------------------------------
      // First touch of a fresh line must miss and take the HBM latency; the
      // second touch of the same line must hit and be quick.
      h0 = ee_hits; m0 = ee_miss;
      t0 = $time; ee_read(25'h01_0000, d); t_miss = $time - t0;
      t0 = $time; ee_read(25'h01_0010, d); t_hit  = $time - t0;
      $display("   miss %0d ns, hit %0d ns, hits +%0d, misses +%0d",
               t_miss, t_hit, ee_hits - h0, ee_miss - m0);
      if (ee_miss - m0 != 1) begin
         $display("FAIL: expected exactly one miss for a fresh line, got %0d", ee_miss - m0);
         errors = errors + 1;
      end
      if (ee_hits - h0 != 1) begin
         $display("FAIL: expected the second access in the line to hit, got %0d hits", ee_hits - h0);
         errors = errors + 1;
      end
      if (t_hit >= t_miss) begin
         $display("FAIL: a hit (%0d ns) is not faster than a miss (%0d ns) -- the cache hides nothing",
                  t_hit, t_miss);
         errors = errors + 1;
      end

      // a write hit must update the cached line, not just HBM
      ee_write(25'h01_0000, 128'h11112222_33334444_55556666_77778888, 16'hFFFF);
      ee_read (25'h01_0000, d);
      check({128'h0, d}, {128'h0, 128'h11112222_33334444_55556666_77778888}, "ee write hit updates the line");

      // and the line it replaces must really come back from HBM when revisited
      ee_read (25'h02_0000, d);                 // same index, different tag: evicts
      ee_read (25'h01_0000, d);                 // must refetch, and see the written value
      check({128'h0, d}, {128'h0, 128'h11112222_33334444_55556666_77778888}, "ee value survived eviction");

      $display("");
      if (errors == 0) $display("PASS");
      else             $display("FAIL: %0d error(s)", errors);
      $finish;
   end

   // On a hang, say where.  A timeout with no state is the least useful thing a
   // bench can print, and this design has three AXI handshakes any one of which
   // can stall on its own.
   initial begin
      #500000;
      $display("FAIL: timeout");
      $display("   ee state=%0d  req=%b ack=%b  hits=%0d miss=%0d",
               ee.state, ee_req, ee_ack, ee_hits, ee_miss);
      $display("   AW addr=%011x valid=%b ready=%b | W valid=%b ready=%b last=%b | B valid=%b ready=%b",
               awaddr, awvalid, awready, wvalid, wready, wlast, bvalid, bready);
      $display("   AR addr=%011x valid=%b ready=%b len=%0d | R valid=%b ready=%b last=%b",
               araddr, arvalid, arready, arlen, rvalid, rready, rlast);
      $finish;
   end

endmodule
