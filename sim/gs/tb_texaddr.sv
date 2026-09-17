// tb_texaddr.sv -- drive gs_texaddr with the model's cases and diff the answers.
//
//   xsim tb -R -testplusarg "dir=CASEDIR"
//
// gs_texaddr is combinational, so there is no clock here and nothing to
// sequence: each case is applied, settled with a delta delay, and compared.
// That is the point of keeping the unit combinational for now -- the test says
// nothing about pipelining because there is no pipelining to get wrong yet,
// and when the sampler puts registers around this, this test still holds.
//
// Every mismatch is printed rather than only the first.  A wrong wire in a
// permutation typically breaks a whole family of cases at once, and the shape
// of which ones fail is what identifies the wire -- one line of output would
// throw that away.  The count is capped so a completely wrong unit does not
// write a gigabyte of log.
`timescale 1ns/1ps

module tb_texaddr;

   logic signed [12:0] u_in, v_in;
   logic        [13:0] tbp;
   logic        [5:0]  tbw, psm;
   logic        [3:0]  tw, th;
   logic        [1:0]  wms, wmt;
   logic        [9:0]  minu, maxu, minv, maxv;

   logic [16:0] lm_addr;
   logic [7:0]  bit_off;
   logic [5:0]  width;
   logic [10:0] u_out, v_out;

   gs_texaddr dut
     (.u_in(u_in), .v_in(v_in),
      .tbp(tbp), .tbw(tbw), .psm(psm), .tw(tw), .th(th),
      .wms(wms), .wmt(wmt),
      .minu(minu), .maxu(maxu), .minv(minv), .maxv(maxv),
      .lm_addr(lm_addr), .bit_off(bit_off), .width(width),
      .u_out(u_out), .v_out(v_out));

   string dir;
   int    fh, n, bad, code;
   int    e_lm, e_off, e_w, e_u, e_v;
   int    c_u, c_v, c_tbp, c_tbw, c_psm, c_tw, c_th, c_wms, c_wmt;
   int    c_minu, c_maxu, c_minv, c_maxv;

   initial begin
      if (!$value$plusargs("dir=%s", dir)) begin
         $display("FAIL  no dir given"); $finish;
      end
      fh = $fopen({dir, "/vec.txt"}, "r");
      if (fh == 0) begin
         $display("FAIL  cannot open %s/vec.txt", dir); $finish;
      end

      n = 0; bad = 0;
      forever begin
         code = $fscanf(fh,
            "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n",
            c_u, c_v, c_tbp, c_tbw, c_psm, c_tw, c_th, c_wms, c_wmt,
            c_minu, c_maxu, c_minv, c_maxv, e_lm, e_off, e_w, e_u, e_v);
         if (code != 18) break;

         u_in = c_u;   v_in = c_v;
         tbp  = c_tbp; tbw  = c_tbw; psm = c_psm;
         tw   = c_tw;  th   = c_th;
         wms  = c_wms; wmt  = c_wmt;
         minu = c_minu; maxu = c_maxu; minv = c_minv; maxv = c_maxv;
         #1;

         if (lm_addr !== e_lm[16:0] || bit_off !== e_off[7:0] ||
             width !== e_w[5:0] || u_out !== e_u[10:0] || v_out !== e_v[10:0])
         begin
            bad++;
            if (bad <= 40)
               $display({"MISMATCH psm=%02h u=%0d v=%0d tbp=%0d tbw=%0d tw=%0d th=%0d wms=%0d wmt=%0d\n",
                         "    uv   rtl %0d,%0d  model %0d,%0d\n",
                         "    addr rtl word %0d bit %0d wide %0d  model word %0d bit %0d wide %0d"},
                        c_psm, c_u, c_v, c_tbp, c_tbw, c_tw, c_th, c_wms, c_wmt,
                        u_out, v_out, e_u, e_v,
                        lm_addr, bit_off, width, e_lm, e_off, e_w);
         end
         n++;
      end
      $fclose(fh);

      if (bad == 0) $display("PASS  %0d cases identical", n);
      else          $display("FAIL  %0d of %0d cases differ", bad, n);
      $finish;
   end

endmodule
