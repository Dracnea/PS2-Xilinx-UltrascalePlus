// tb_edge_dda.sv -- run edges through gs_edge_dda and print ceil(x) per scanline,
// in the format sim/gs/gen_edges.py prints, so the two can be diffed.
//
// The unit is checked on its own rather than inside the rasteriser because a
// wrong span and a wrong pixel loop look identical in a framebuffer, and only
// one of them is a arithmetic problem.
`timescale 1ns/1ps

module tb_edge_dda;
   logic clk = 0, reset = 1;
   always #5 clk = ~clk;

   logic               start = 0, step = 0, busy;
   logic signed [15:0] x0, y0, x1, y1;
   logic signed [11:0] ytop;
   logic signed [12:0] x;

   gs_edge_dda dut (.clk(clk), .reset(reset), .start(start),
                    .x0(x0), .y0(y0), .x1(x1), .y1(y1), .ytop(ytop),
                    .busy(busy), .step(step), .x(x));

   // one edge per line: x0 y0 x1 y1 ytop nscan, all decimal
   integer fh, n, e, ns, rc, budget;
   integer vx0, vy0, vx1, vy1, vyt, vns;

   initial begin
      fh = $fopen("edges.txt", "r");
      if (fh == 0) begin $display("# no edges.txt"); $finish; end
      repeat (4) @(posedge clk);
      reset <= 0;
      @(posedge clk);

      e = 0;
      while (!$feof(fh)) begin
         rc = $fscanf(fh, "%d %d %d %d %d %d\n", vx0, vy0, vx1, vy1, vyt, vns);
         if (rc != 6) break;
         x0 <= vx0; y0 <= vy0; x1 <= vx1; y1 <= vy1; ytop <= vyt;
         start <= 1'b1;
         @(posedge clk);
         start <= 1'b0;
         // Sample a short way past the edge, not on it.  busy is driven by the
         // same edge this process wakes on, and reading it there gets the value
         // from before the edge -- so the wait falls straight through and every
         // result is read out of a unit that has not started yet.  The EE
         // testbench had the identical race on retire_pc.
         #0.1;
         budget = 4000;
         while (busy && budget > 0) begin
            @(posedge clk);
            #0.1;
            budget = budget - 1;
         end
         if (budget <= 0) begin
            $display("# STALLED on edge %0d", e);
            $finish;
         end
         for (n = 0; n < vns; n = n + 1) begin
            #0.1 $write("E %0d %0d %0d\n", e, n, x);
            step <= 1'b1;
            @(posedge clk);
            step <= 1'b0;
         end
         e = e + 1;
      end
      $fclose(fh);
      $finish;
   end
endmodule
