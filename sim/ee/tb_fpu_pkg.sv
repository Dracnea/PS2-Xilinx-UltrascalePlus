// Drive ee_fpu_pkg's conditioner and compares with vectors from a file and
// print what it produced, so sim/ee/run_fpu_diff.sh can diff it against
// ps2_float.py. The testbench decides nothing: it reads pairs, calls the
// functions, prints. Every judgement is in the diff.
`timescale 1ns/1ps
module tb_fpu_pkg;
   localparam integer MAXV = 4096;
   reg [31:0] a [0:MAXV-1];
   reg [31:0] b [0:MAXV-1];
   integer n, i, fd, code;
   string   path;

   wire [31:0] ca, cb, mx, mn, ab, ng;
   reg  [31:0] ia, ib;
   wire        eq, lt, le;

   fpu_wrap w (.a(ia), .b(ib), .ca(ca), .cb(cb),
               .eq(eq), .lt(lt), .le(le), .mx(mx), .mn(mn), .ab(ab), .ng(ng));

   initial begin
      if (!$value$plusargs("vec=%s", path)) path = "vectors.hex";
      fd = $fopen(path, "r");
      n  = 0;
      while (!$feof(fd) && n < MAXV) begin
         code = $fscanf(fd, "%h %h\n", a[n], b[n]);
         if (code == 2) n = n + 1;
      end
      $fclose(fd);
      for (i = 0; i < n; i = i + 1) begin
         ia = a[i];
         ib = b[i];
         #1;
         $display("V %08h %08h COND %08h %08h CMP %0d %0d %0d MAXMIN %08h %08h ABSNEG %08h %08h",
                  ia, ib, ca, cb, eq, lt, le, mx, mn, ab, ng);
      end
      $finish;
   end
endmodule
