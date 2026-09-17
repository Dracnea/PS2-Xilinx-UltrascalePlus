// tb_texsample.sv -- fetch texels on the card's own logic and diff the colours.
//
//   xsim tb -R -testplusarg "dir=CASEDIR"
//
// gs_clut and gs_texsample are instantiated **together**, not separately with
// the palette poked in: the point of this test is the path from a UV coordinate
// to a colour, and the palette lookup is part of that path. A test that wrote
// the CLUT's contents directly would skip the one interface between these two
// blocks and pass whether or not it was wired correctly.
//
// The memory is modelled at the shape gs_lmem presents -- 256 bits, two clocks
// of read latency -- and both blocks get their own read port off the same
// array. That is not what the real design will have, and it is deliberate here:
// the arbitration between them is an open question (see the header of
// gs_texsample.vhd) and this test is not the place to prejudge it. What it
// tests is that each block asks for the right address and does the right thing
// with the answer.
`timescale 1ns/1ps

module tb_texsample;
   localparam MEM_LINES = 131072;         // the GS's real 4 MB

   logic clk = 0, reset = 1;
   always #5 clk = ~clk;

   // ---- memory, two ports on one array --------------------------------------
   logic [255:0] mem [0:MEM_LINES-1];

   logic         c_rd_en;
   logic [16:0]  c_rd_addr;
   logic [255:0] c_rd_data;
   logic         c_rd_valid;
   logic [255:0] c_d1, c_d2;
   logic         c_v1, c_v2;
   always @(posedge clk) begin
      c_d1 <= mem[c_rd_addr]; c_v1 <= c_rd_en && !reset;
      c_d2 <= c_d1;           c_v2 <= c_v1;
   end
   assign c_rd_data = c_d2;
   assign c_rd_valid = c_v2;

   logic         s_rd_en;
   logic [16:0]  s_rd_addr;
   logic [255:0] s_rd_data;
   logic         s_rd_valid;
   logic [255:0] s_d1, s_d2;
   logic         s_v1, s_v2;
   always @(posedge clk) begin
      s_d1 <= mem[s_rd_addr]; s_v1 <= s_rd_en && !reset;
      s_d2 <= s_d1;           s_v2 <= s_v1;
   end
   assign s_rd_data = s_d2;
   assign s_rd_valid = s_v2;

   // ---- the palette ---------------------------------------------------------
   logic        clut_we = 0;
   logic [63:0] clut_tex0 = 0, clut_texclut = 0;
   logic [7:0]  clut_idx;
   logic [31:0] clut_data;
   logic        clut_busy;
   logic [15:0] clut_loads;
   logic        clut_unsup;

   gs_clut palette
     (.clk(clk), .reset(reset),
      .we(clut_we), .tex0(clut_tex0), .texclut(clut_texclut),
      .rd_en(c_rd_en), .rd_addr(c_rd_addr), .rd_data(c_rd_data),
      .rd_valid(c_rd_valid),
      .idx(clut_idx), .entry(clut_data),
      .busy(clut_busy), .loads(clut_loads), .unsupported(clut_unsup));

   // ---- the sampler ---------------------------------------------------------
   logic               req = 0;
   logic signed [16:0] u_fixed = 0, v_fixed = 0;
   logic [31:0]        frag = 0;
   logic [63:0]        s_tex0 = 0, s_clamp = 0;
   logic               done, s_busy;
   logic [31:0]        colour;

   gs_texsample dut
     (.clk(clk), .reset(reset),
      .req(req), .u_fixed(u_fixed), .v_fixed(v_fixed), .frag(frag),
      .tex0(s_tex0), .clamp(s_clamp),
      .rd_en(s_rd_en), .rd_addr(s_rd_addr), .rd_data(s_rd_data),
      .rd_valid(s_rd_valid),
      .clut_idx(clut_idx), .clut_data(clut_data),
      .done(done), .colour(colour), .busy(s_busy));

   string dir;
   int    fh, code, n;
   longint c_u, c_v;
   logic [31:0] c_frag;
   logic [63:0] c_tex0, c_clamp;

   initial begin
      if (!$value$plusargs("dir=%s", dir)) begin
         $display("FAIL  no dir given"); $finish;
      end
      $readmemh({dir, "/mem.hex"}, mem);

      repeat (4) @(posedge clk);
      reset <= 0;
      repeat (2) @(posedge clk);

      // Load the palette first, once.
      fh = $fopen({dir, "/clut.txt"}, "r");
      code = $fscanf(fh, "%h %h\n", clut_tex0, clut_texclut);
      $fclose(fh);
      @(posedge clk);
      clut_we <= 1;
      @(posedge clk);
      clut_we <= 0;
      @(posedge clk);
      while (clut_busy) @(posedge clk);
      if (clut_unsup) begin
         $display("FAIL  the palette load was refused"); $finish;
      end

      fh = $fopen({dir, "/cases.txt"}, "r");
      if (fh == 0) begin
         $display("FAIL  cannot open %s/cases.txt", dir); $finish;
      end

      n = 0;
      forever begin
         code = $fscanf(fh, "%d %d %h %h %h\n",
                        c_u, c_v, c_frag, c_tex0, c_clamp);
         if (code != 5) break;

         @(posedge clk);
         u_fixed <= c_u[16:0];
         v_fixed <= c_v[16:0];
         frag    <= c_frag;
         s_tex0  <= c_tex0;
         s_clamp <= c_clamp;
         req     <= 1;
         @(posedge clk);
         req <= 0;

         while (!done) @(posedge clk);
         $display("%0d %08x", n, colour);
         n++;
      end
      $fclose(fh);
      $display("DONE %0d cases", n);
      $finish;
   end

   initial begin
      #200_000_000;
      $display("FAIL  STALLED -- a fetch never completed");
      $finish;
   end

endmodule
