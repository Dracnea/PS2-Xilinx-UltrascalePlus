// tb_fdiv.sv -- the PS2-float divider against ps2_float.div.
//
//   xsim tb -R -testplusarg "dir=CASEDIR"
//
// The divider is sequential, so this drives one pair at a time and waits for
// `done`. It also checks that `busy` actually falls between cases: a divider
// that never released would still produce right answers here, one per test, and
// would deadlock the pixel path it is going into.
`timescale 1ns/1ps

module tb_fdiv;
   logic clk = 0, reset = 1;
   always #5 clk = ~clk;

   logic        start = 0, done, busy;
   logic [31:0] a = 0, b = 0, q;

   gs_fdiv dut (.clk(clk), .reset(reset), .start(start),
                .a(a), .b(b), .q(q), .done(done), .busy(busy));

   string dir;
   int    fh, code, n, waited;
   logic [31:0] ca, cb;

   initial begin
      if (!$value$plusargs("dir=%s", dir)) begin
         $display("FAIL  no dir given"); $finish;
      end
      repeat (4) @(posedge clk);
      reset <= 0;
      repeat (2) @(posedge clk);

      fh = $fopen({dir, "/cases.txt"}, "r");
      if (fh == 0) begin
         $display("FAIL  cannot open %s/cases.txt", dir); $finish;
      end
      n = 0;
      forever begin
         code = $fscanf(fh, "%h %h\n", ca, cb);
         if (code != 2) break;
         if (busy !== 1'b0) begin
            $display("FAIL  case %0d: still busy before it was started", n);
            $finish;
         end
         @(posedge clk);
         a <= ca; b <= cb; start <= 1;
         @(posedge clk);
         start <= 0;
         waited = 0;
         while (!done) begin
            @(posedge clk);
            waited++;
            if (waited > 200) begin
               $display("FAIL  STALLED on case %0d", n); $finish;
            end
         end
         $display("%0d %08x", n, q);
         n++;
         @(posedge clk);
      end
      $fclose(fh);
      $display("DONE %0d cases", n);
      $finish;
   end
endmodule
