// tb_pcrtc.sv -- run one PCRTC case and print the frame it produces.
//
//   xsim tb -R -testplusarg "dir=CASEDIR"
//
// The memory here is the same shape gs_lmem presents: 256 bits wide, two clocks
// of read latency, one read per clock accepted.  It is modelled rather than
// instantiated because this is a test of the read circuit, not of the memory --
// gs_lmem has its own -- and because a model can be loaded from a file in one
// line.
`timescale 1ns/1ps

module tb_pcrtc;
   localparam ADDR_BITS = 11;          // 2048 lines of 256 bits, eight pages

   logic clk = 0, reset = 1;
   always #5 clk = ~clk;

   logic        pr_we = 0;
   logic [7:0]  pr_addr = 0;
   logic [63:0] pr_data = 0;
   logic [11:0] h_total, v_total;
   logic        enable = 0;

   logic                  rd_en;
   logic [ADDR_BITS-1:0]  rd_addr;
   logic [255:0]          rd_data;
   logic                  rd_valid;

   logic        px_valid;
   logic [23:0] px_rgb;
   logic [11:0] px_x, px_y;
   logic        px_sof;

   gs_pcrtc #(.ADDR_BITS(ADDR_BITS)) dut
     (.clk(clk), .reset(reset),
      .pr_we(pr_we), .pr_addr(pr_addr), .pr_data(pr_data),
      .h_total(h_total), .v_total(v_total), .enable(enable),
      .rd_en(rd_en), .rd_addr(rd_addr), .rd_data(rd_data), .rd_valid(rd_valid),
      .px_valid(px_valid), .px_rgb(px_rgb), .px_x(px_x), .px_y(px_y),
      .px_sof(px_sof));

   // ---- the memory: two clocks, in order ------------------------------------
   logic [255:0] mem [0:(1<<ADDR_BITS)-1];
   logic [255:0] d1, d2;
   logic         v1, v2;
   always @(posedge clk) begin
      d1 <= mem[rd_addr];  v1 <= rd_en && !reset;
      d2 <= d1;            v2 <= v1;
   end
   assign rd_data  = d2;
   assign rd_valid = v2;

   string dir;
   int    fh, htot, vtot, n, npix, npx_exp;
   logic [63:0] regs [0:5];
   localparam int RADDR [0:5] = '{8'h00, 8'h70, 8'h80, 8'h90, 8'hA0, 8'hE0};

   initial begin
      if (!$value$plusargs("dir=%s", dir)) begin
         $display("FAIL no dir"); $finish;
      end
      $readmemh({dir, "/mem.hex"}, mem);

      fh = $fopen({dir, "/cfg.txt"}, "r");
      if (fh == 0) begin $display("FAIL no cfg"); $finish; end
      n = $fscanf(fh, "%d %d\n", htot, vtot);
      for (int i = 0; i < 6; i++) n = $fscanf(fh, "%h\n", regs[i]);
      $fclose(fh);

      h_total = htot[11:0];
      v_total = vtot[11:0];
      npx_exp  = htot * vtot;

      repeat (4) @(posedge clk);
      reset <= 0;
      @(posedge clk);

      // The registers go in before the raster starts, which is what `enable`
      // being separate from reset is for.
      for (int i = 0; i < 6; i++) begin
         @(posedge clk);
         pr_we <= 1; pr_addr <= RADDR[i][7:0]; pr_data <= regs[i];
      end
      @(posedge clk);
      pr_we <= 0;
      @(posedge clk);
      enable <= 1;
   end

   // A frame of H x V pixels, and a generous ceiling on how long it may take:
   // two reads and their latency per pixel is the worst case, so ten clocks a
   // pixel is loose enough not to fire on a slow case and tight enough that a
   // block which has stopped producing is reported rather than hanging.
   initial begin
      wait (npx_exp != 0);
      repeat (npx_exp * 10 + 1000) @(posedge clk);
      $display("STALLED after %0d of %0d pixels", npix, npx_exp);
      $finish;
   end

   always @(posedge clk) begin
      if (px_valid) begin
         $display("%4d %4d %06h", px_x, px_y, px_rgb);
         npix <= npix + 1;
         if (npix + 1 == npx_exp) begin
            $display("DONE %0d", npix + 1);
            $finish;
         end
      end
   end

   initial npix = 0;
endmodule
