// tb_gs_top.sv -- the same comparison tb_gs.sv makes, but against gs_top: the
// rasteriser wired to the *real* gs_lmem instead of to a model of it.
//
// Two things this can find that tb_gs.sv cannot.
//
// The arbiter.  gs_lmem has one read port and gs_top gives it two customers, so
// a read's data has to come back to whoever asked for it.  Nothing else
// exercises that.
//
// And the memory's own read-during-write behaviour.  tb_gs.sv forwards a write
// to a read at the same address in the same cycle -- it says so, and calls it a
// modelling artifact.  gs_lmem does not forward: its write is a VHDL signal
// assignment, so it lands at the end of the process and a read in that cycle
// sees the old contents.  Eight 32-bit pixels share a 256-bit word, so
// consecutive pixels of one scanline are the same address, and whether the
// rasteriser ever reads a word in the cycle it is written is not obvious from
// either side.  Running the identical stream through both answers it.
`timescale 1ns/1ps

module tb_gs_top;
   logic clk = 0, reset = 1;
   always #5 clk = ~clk;

   logic         gif_valid, gif_ready;
   logic [127:0] gif_data;
   logic         h_rd_en = 0, h_rd_valid;
   logic [16:0]  h_rd_addr = 0;
   logic [255:0] h_rd_data;
   logic [6:0]   dbg_sel = 0;
   logic [63:0]  dbg_reg;
   logic [15:0]  dbg_unknown;
   logic [31:0]  dbg_pixels;

   // ---- the display, for the contention test ------------------------------
   logic        pr_we = 0;
   logic [7:0]  pr_addr = 0;
   logic [63:0] pr_data = 0;
   logic        disp_enable = 0;
   logic [11:0] h_total = 12'd64, v_total = 12'd64;
   logic        px_valid, px_sof;
   logic [23:0] px_rgb;
   logic [11:0] px_x, px_y;
   logic [31:0] dbg_crtc_rd, dbg_crtc_stall;

   gs_top #(.ADDR_BITS(17)) dut (
      .clk(clk), .reset(reset),
      .gif_valid(gif_valid), .gif_data(gif_data), .gif_ready(gif_ready),
      .h_rd_en(h_rd_en), .h_rd_addr(h_rd_addr),
      .h_rd_data(h_rd_data), .h_rd_valid(h_rd_valid),
      .dbg_sel(dbg_sel), .dbg_reg(dbg_reg),
      .dbg_unknown(dbg_unknown), .dbg_pixels(dbg_pixels),
      .pr_we(pr_we), .pr_addr(pr_addr), .pr_data(pr_data),
      .h_total(h_total), .v_total(v_total), .disp_enable(disp_enable),
      .px_valid(px_valid), .px_rgb(px_rgb),
      .px_x(px_x), .px_y(px_y), .px_sof(px_sof),
      .dbg_crtc_rd(dbg_crtc_rd), .dbg_crtc_stall(dbg_crtc_stall));

   // The pixel stream, hashed the same way local memory is. Two runs of the
   // same packets with the display on must agree here, and the framebuffer
   // they draw must agree with a run that had the display off.
   logic [31:0] pxsum;
   integer      pxcount;
   always_ff @(posedge clk) begin
      if (reset) begin
         pxsum   <= 32'h811C9DC5;
         pxcount <= 0;
      end else if (px_valid) begin
         pxsum <= ((((((pxsum ^ px_rgb[7:0]) * 32'h01000193)
                        ^ px_rgb[15:8]) * 32'h01000193)
                        ^ px_rgb[23:16]) * 32'h01000193);
         pxcount <= pxcount + 1;
      end
   end

   localparam MAXPKT = 16384;
   logic [127:0] pkts [0:MAXPKT-1];
   localparam VMBYTES = 4*1024*1024;
   logic [7:0] vm [0:VMBYTES-1];

   integer sent, npkt, n, r, b, budget;
   integer waited, got_word;
   logic [31:0] vmsum;
   integer dump_base, dump_len;
   string  pktfile;

   // ---- feed the packets, exactly as tb_gs.sv does ------------------------
   always_ff @(posedge clk) begin
      if (reset) begin
         gif_valid <= 1'b0;
         gif_data  <= 128'h0;
         sent      <= 0;
      end else if (gif_valid && gif_ready) begin
         sent <= sent + 1;
         if (sent + 1 < npkt) begin
            gif_data  <= pkts[sent + 1];
            gif_valid <= 1'b1;
         end else begin
            gif_valid <= 1'b0;
         end
      end else if (!gif_valid && sent < npkt) begin
         gif_data  <= pkts[sent];
         gif_valid <= 1'b1;
      end
   end

   initial begin
      if (!$value$plusargs("packets=%s", pktfile)) pktfile = "packets.hex";
      if (!$value$plusargs("dumpbase=%d", dump_base)) dump_base = 0;
      if (!$value$plusargs("dumplen=%d", dump_len))   dump_len  = 256;
      for (n = 0; n < VMBYTES; n = n + 1) vm[n] = 8'h00;
      for (n = 0; n < MAXPKT; n = n + 1) pkts[n] = 128'h0;
      $readmemh(pktfile, pkts);
      npkt = MAXPKT;
      while (npkt > 0 && pkts[npkt-1] === 128'h0) npkt = npkt - 1;
      if (npkt == MAXPKT) begin
         $display("# tb_gs_top: %s fills all %0d packet slots -- truncated?",
                  pktfile, MAXPKT);
         $finish;
      end

      repeat (4) @(posedge clk);
      reset <= 0;
      @(posedge clk);

      // ---- optionally run the display against the rasteriser --------------
      //
      // One circuit covering the whole of a 64x64 raster, reading PSMCT32 from
      // the base of memory: every output pixel becomes a read, which is the
      // worst case for the one read port rather than a typical one. The
      // rasteriser is drawing into the same memory at the same time.
      //
      // The picture this makes is not checked here and is not the point --
      // tb_pcrtc.sv checks pictures against pcrtc_ref.py. What is checked is
      // that the rasteriser's framebuffer is bit-identical to the run where no
      // display existed, which is what a misrouted read would destroy.
      if ($value$plusargs("display=%d", n) && n != 0) begin
         @(negedge clk);
         pr_we <= 1;
         pr_addr <= 8'h00; pr_data <= 64'h0000_0000_0000_0001;   // PMODE: EN1
         @(negedge clk);
         pr_addr <= 8'h70; pr_data <= 64'h0000_0000_0000_0200;   // DISPFB1
         @(negedge clk);
         pr_addr <= 8'h80; pr_data <= 64'h003F_003F_0000_0000;   // DISPLAY1
         @(negedge clk);
         pr_addr <= 8'hE0; pr_data <= 64'h0;                     // BGCOLOR
         @(negedge clk);
         pr_we <= 0;
         @(posedge clk);
         disp_enable <= 1;
      end

      budget = npkt * 4096 + 65536;
      while (sent < npkt && budget > 0) begin
         @(posedge clk);
         budget = budget - 1;
      end
      n = sent;
      repeat (200000) @(posedge clk);
      if (budget <= 0) $display("# STALLED after %0d of %0d quadwords", n, npkt);

      for (r = 0; r < 128; r = r + 1) begin
         dbg_sel = r[6:0];
         #0.1 $write("REG %02x %016x\n", r, dbg_reg);
      end

      // ---- read the whole of local memory back through the host port ------
      // One request at a time rather than a pipeline: this runs once at the end
      // of a simulation and being obviously correct is worth more here than
      // being quick.
      // **The display stops before the framebuffer is read back.**
      //
      // The contention worth testing is the rasteriser against PCRTC while
      // drawing, and that has already happened by now -- dbg_crtc_rd and
      // dbg_crtc_stall are cumulative and hold what it came to. The readback is
      // only how the framebuffer is extracted, and leaving the display running
      // through it turns 131072 host reads into 131072 contended reads, each
      // retrying against a PCRTC that wants the port every few cycles. One seed
      // took an hour and a half and had three more behind it.
      //
      // It also makes the two runs symmetric: both now read back with the
      // display idle, so the checksums compare the framebuffers rather than the
      // conditions they were read under.
      disp_enable <= 0;
      @(posedge clk);

      // **The host request is retried, not held.**
      //
      // The host is the lowest priority of the read port's three customers and
      // may be refused outright -- true before the display existed, and routine
      // once it is running. Pulsing h_rd_en once and then waiting forever on
      // h_rd_valid deadlocks on the first refusal.
      //
      // Holding h_rd_en instead is worse, and it is worse in a way that looks
      // like an RTL bug: several reads go out, each answers with its own
      // h_rd_valid, and a trailing valid from one address is still asserted
      // when the next iteration starts. The wait then falls straight through
      // and stores the previous word. That corrupts the memory dump with the
      // display *off* as well, which is how it was caught -- the plain gs_top
      // differential started failing.
      //
      // So: one read, a bounded wait for the answer, and ask again if none
      // came. A refused read leaves nothing in flight, so a retry is clean.
      for (n = 0; n < (1 << 17); n = n + 1) begin
         got_word = 0;
         while (!got_word) begin
            @(negedge clk);
            h_rd_addr = n[16:0];
            h_rd_en   = 1'b1;
            @(negedge clk);
            h_rd_en   = 1'b0;
            waited = 0;
            while (!h_rd_valid && waited < 8) begin
               @(negedge clk);
               waited = waited + 1;
            end
            if (h_rd_valid) got_word = 1;
         end
         for (b = 0; b < 32; b = b + 1)
            vm[n*32 + b] = h_rd_data[b*8 +: 8];
      end

      for (n = dump_base; n < dump_base + dump_len; n = n + 16)
         $write("VM %08x %02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x\n",
                n, vm[n+15], vm[n+14], vm[n+13], vm[n+12], vm[n+11], vm[n+10],
                vm[n+9], vm[n+8], vm[n+7], vm[n+6], vm[n+5], vm[n+4],
                vm[n+3], vm[n+2], vm[n+1], vm[n+0]);
      vmsum = 32'h811C9DC5;
      for (n = 0; n < VMBYTES; n = n + 1)
         vmsum = (vmsum ^ vm[n]) * 32'h01000193;
      $write("VMSUM %08x\n", vmsum);
      if (dbg_unknown != 0) $display("# unknown register writes: %0d", dbg_unknown);
      $display("# pixels drawn: %0d", dbg_pixels);
      $write("CRTCRD %0d\n", dbg_crtc_rd);
      $write("CRTCSTALL %0d\n", dbg_crtc_stall);
      $write("PXCOUNT %0d\n", pxcount);
      $write("PXSUM %08x\n", pxsum);
      $finish;
   end
endmodule
