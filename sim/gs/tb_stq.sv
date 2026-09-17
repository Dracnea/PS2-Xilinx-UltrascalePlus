// tb_stq.sv -- the perspective divide against gs_ref.stq_to_uv.
//
//   xsim tb -R -testplusarg "dir=CASEDIR"
`timescale 1ns/1ps

module tb_stq;
   logic clk = 0, reset = 1;
   always #5 clk = ~clk;

   logic        req = 0, done, busy;
   logic [31:0] s = 0, t = 0, qf = 0;
   logic [3:0]  tw = 0, th = 0;
   logic signed [18:0] u_out, v_out;

   gs_stq dut (.clk(clk), .reset(reset), .req(req),
               .s(s), .t(t), .qf(qf), .tw(tw), .th(th),
               .u_out(u_out), .v_out(v_out), .done(done), .busy(busy));

   string dir;
   int    fh, code, n, waited, ctw, cth;
   int    wmin = 9999, wmax = 0;
   logic [31:0] cs, ct, cq;

   initial begin
      if (!$value$plusargs("dir=%s", dir)) begin
         $display("FAIL  no dir given"); $finish;
      end
      repeat (4) @(posedge clk);
      reset <= 0;
      repeat (2) @(posedge clk);

      fh = $fopen({dir, "/cases.txt"}, "r");
      if (fh == 0) begin $display("FAIL  no cases.txt"); $finish; end
      n = 0;
      forever begin
         code = $fscanf(fh, "%h %h %h %d %d\n", cs, ct, cq, ctw, cth);
         if (code != 5) break;
         if (busy !== 1'b0) begin
            $display("FAIL  case %0d: busy before it was started", n); $finish;
         end
         @(posedge clk);
         s <= cs; t <= ct; qf <= cq; tw <= ctw[3:0]; th <= cth[3:0]; req <= 1;
         @(posedge clk);
         req <= 0;
         waited = 0;
         while (!done) begin
            @(posedge clk);
            waited++;
            if (waited > 400) begin
               $display("FAIL  STALLED on case %0d", n); $finish;
            end
         end
         if (waited < wmin) wmin = waited;
         if (waited > wmax) wmax = waited;
         $display("%0d %0d %0d", n, u_out, v_out);
         n++;
         @(posedge clk);
      end
      $fclose(fh);
      $display("LATENCY min=%0d max=%0d clocks from req to done", wmin, wmax);
      $display("DONE %0d cases", n);
      $finish;
   end
endmodule
