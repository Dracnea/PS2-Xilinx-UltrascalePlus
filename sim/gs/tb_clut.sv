// tb_clut.sv -- apply the model's TEX0 writes to gs_clut and print the palette.
//
//   xsim tb -R -testplusarg "dir=CASEDIR"
//
// The memory here is the shape gs_lmem presents -- 256 bits wide, two clocks of
// read latency -- and is modelled rather than instantiated for the same reason
// tb_pcrtc models it: this is a test of what the CLUT asks memory for, not of
// the memory, and a model can be loaded from a file in one line.
//
// The cases are applied **in order and without reordering**, because CLD makes
// the CLUT a cache: what a write does depends on the writes before it. See the
// docstring of gen_clut.py.
//
// After each write this prints the load counter, the unsupported flag and all
// 256 entries. The load counter is not decoration: the half of CLD that matters
// is deciding *not* to reload, and a buffer that was correctly left alone looks
// exactly like one that was reloaded with the same bytes.
`timescale 1ns/1ps

module tb_clut;
   localparam MEM_LINES = 8192;            // 256 KB of 256-bit words

   logic clk = 0, reset = 1;
   always #5 clk = ~clk;

   logic        we = 0;
   logic [63:0] tex0 = 0, texclut = 0;

   logic         rd_en;
   logic [16:0]  rd_addr;
   logic [255:0] rd_data;
   logic         rd_valid;

   logic [7:0]  idx = 0;
   logic [31:0] entry;
   logic        busy;
   logic [15:0] loads;
   logic        unsupported;

   gs_clut dut
     (.clk(clk), .reset(reset),
      .we(we), .tex0(tex0), .texclut(texclut),
      .rd_en(rd_en), .rd_addr(rd_addr), .rd_data(rd_data), .rd_valid(rd_valid),
      .idx(idx), .entry(entry),
      .busy(busy), .loads(loads), .unsupported(unsupported));

   // ---- the memory: two clocks, in order ------------------------------------
   logic [255:0] mem [0:MEM_LINES-1];
   logic [255:0] d1, d2;
   logic         v1, v2;
   always @(posedge clk) begin
      d1 <= mem[rd_addr[12:0]];  v1 <= rd_en && !reset;
      d2 <= d1;                  v2 <= v1;
   end
   assign rd_data  = d2;
   assign rd_valid = v2;

   string dir;
   int    fh, code, n;
   logic [63:0] c_tex0, c_texclut;
   logic [31:0] snap [0:255];

   initial begin
      if (!$value$plusargs("dir=%s", dir)) begin
         $display("FAIL  no dir given"); $finish;
      end
      $readmemh({dir, "/mem.hex"}, mem);

      repeat (4) @(posedge clk);
      reset <= 0;
      repeat (2) @(posedge clk);

      fh = $fopen({dir, "/cases.txt"}, "r");
      if (fh == 0) begin
         $display("FAIL  cannot open %s/cases.txt", dir); $finish;
      end

      n = 0;
      forever begin
         code = $fscanf(fh, "%h %h\n", c_tex0, c_texclut);
         if (code != 2) break;

         @(posedge clk);
         tex0    <= c_tex0;
         texclut <= c_texclut;
         we      <= 1;
         @(posedge clk);
         we <= 0;

         // A load can take 256 accesses at two clocks each; wait for the block
         // to say it is done rather than counting cycles.
         @(posedge clk);
         while (busy) @(posedge clk);

         // Read the whole buffer. `entry` is registered, so the value for an
         // index appears the clock after it is applied.
         for (int i = 0; i < 256; i++) begin
            idx <= i[7:0];
            @(posedge clk);
            @(posedge clk);
            snap[i] = entry;
         end

         $write("%0d %0d %0d", n, loads, unsupported);
         for (int i = 0; i < 256; i++) $write(" %08x", snap[i]);
         $write("\n");
         n++;
      end
      $fclose(fh);
      $display("DONE %0d cases", n);
      $finish;
   end

   // A load that never finishes would otherwise hang the run with no output.
   initial begin
      #20_000_000;
      $display("FAIL  STALLED -- a CLUT load never completed");
      $finish;
   end

endmodule
