// tb_gs.sv -- feed GIF quadwords to gs_gif and print the state it produced, in
// the format sim/gs/gs_ref.py --raw prints, so the two can be diffed.
//
// Every register address from 0x00 to 0x7f is printed, not just the defined
// ones: a write to an address the manual does not define must leave it alone,
// and printing only the defined registers would never notice if it did not.
`timescale 1ns/1ps

module tb_gs;
   logic clk = 0, reset = 1;
   always #5 clk = ~clk;

   logic         gif_valid, gif_ready;
   logic [127:0] gif_data;
   logic         wr_en;
   logic [16:0]  wr_addr;
   logic [255:0] wr_data;
   logic [31:0]  wr_be;
   logic         rd_en;
   logic [16:0]  rd_addr;
   logic [255:0] rd_data;
   logic         rd_valid;
   logic [6:0]   dbg_sel = 0;
   logic [63:0]  dbg_reg;
   logic [15:0]  dbg_unknown;
   logic [31:0]  dbg_pixels;

   gs_gif dut (
      .clk(clk), .reset(reset),
      .gif_valid(gif_valid), .gif_data(gif_data), .gif_ready(gif_ready),
      .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data), .wr_be(wr_be),
      .rd_en(rd_en), .rd_addr(rd_addr), .rd_data(rd_data), .rd_valid(rd_valid),
      .dbg_sel(dbg_sel), .dbg_reg(dbg_reg), .dbg_unknown(dbg_unknown), .dbg_pixels(dbg_pixels));

   integer sent, npkt;
   integer n, r, budget;
   logic [31:0] vmsum;
   integer dump_base, dump_len;
   string  pktfile;
   logic [127:0] pkts [0:4095];

   // ---- local memory: 4 MB, written 256 bits at a time with byte enables ---
   localparam VMBYTES = 4*1024*1024;
   logic [7:0] vm [0:VMBYTES-1];
   integer b;
   always_ff @(posedge clk) begin
      if (wr_en)
         for (b = 0; b < 32; b = b + 1)
            if (wr_be[b]) vm[{wr_addr, 5'd0} + b] <= wr_data[b*8 +: 8];
   end

   // Read port, two clocks of latency, as gs_lmem gives with its UltraRAM
   // output registers.  A masked write is a read-modify-write, so the draw path
   // has to tolerate that latency rather than assume the value is just there.
   logic [255:0] rd_s1;
   logic         rd_v1;
   integer       c;
   always_ff @(posedge clk) begin
      rd_v1 <= rd_en;
      if (rd_en)
         for (c = 0; c < 32; c = c + 1)
            rd_s1[c*8 +: 8] <= vm[{rd_addr, 5'd0} + c];
      rd_data  <= rd_s1;
      rd_valid <= rd_v1;
   end

   // ---- feed the packets --------------------------------------------------
   // A quadword moves on an edge where valid and ready are both high, and both
   // are sampled inside this clocked block so they are read as they were
   // *before* the edge -- which is the whole content of the rule.  Reading
   // ready after the edge instead advances the producer on an edge where
   // nothing was taken, and loses a quadword exactly when the consumer stops
   // to do some work.
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
      for (n = 0; n < 4096; n = n + 1) pkts[n] = 128'h0;
      $readmemh(pktfile, pkts);
      // the generator writes a count on the first line as a comment, so instead
      // count the trailing zero quadwords off the end
      npkt = 4096;
      while (npkt > 0 && pkts[npkt-1] === 128'h0) npkt = npkt - 1;

      repeat (4) @(posedge clk);
      reset <= 0;
      @(posedge clk);

      // Sized for the slowest consumer, not the average one: a triangle holds
      // ready low for a long divide per edge and then a pixel per clock -- or
      // four per pixel when the write is masked -- so a budget scaled for
      // register writes runs out mid-stream, the rest of the packets are never
      // fed, and the result looks like the two models disagreeing about
      // registers rather than a testbench giving up.
      budget = npkt * 4096 + 65536;
      while (sent < npkt && budget > 0) begin
         @(posedge clk);
         budget = budget - 1;
      end
      n = sent;
      // Let everything still in flight land.  This has to be generous: a
      // triangle's setup is two long divisions per edge before a single pixel
      // is written, so a drain sized for a transfer ends the simulation in the
      // middle of the setup and the framebuffer comes out empty -- which looks
      // exactly like a rasteriser that does not work.
      repeat (200000) @(posedge clk);
      if (budget <= 0) $display("# STALLED after %0d of %0d quadwords", n, npkt);

      for (r = 0; r < 128; r = r + 1) begin
         dbg_sel = r[6:0];
         #0.1 $write("REG %02x %016x\n", r, dbg_reg);
      end
      for (n = dump_base; n < dump_base + dump_len; n = n + 16)
         $write("VM %08x %02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x\n",
                n, vm[n+15], vm[n+14], vm[n+13], vm[n+12], vm[n+11], vm[n+10],
                vm[n+9], vm[n+8], vm[n+7], vm[n+6], vm[n+5], vm[n+4],
                vm[n+3], vm[n+2], vm[n+1], vm[n+0]);
      // the same checksum the reference prints, over all 4 MB
      vmsum = 32'h811C9DC5;
      for (n = 0; n < VMBYTES; n = n + 1)
         vmsum = (vmsum ^ vm[n]) * 32'h01000193;
      $write("VMSUM %08x\n", vmsum);
      if (dbg_unknown != 0) $display("# unknown register writes: %0d", dbg_unknown);
      $display("# pixels drawn: %0d", dbg_pixels);
      $finish;
   end
endmodule
