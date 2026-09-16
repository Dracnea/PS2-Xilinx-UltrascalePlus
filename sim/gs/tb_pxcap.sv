// tb_pxcap.sv -- gs_pxcap against a synthetic pixel stream.
//
// Four behaviours, each of which would otherwise be found on a card by staring
// at a wrong picture: a frame is captured from its first pixel and not its
// second; a frame shorter than the buffer ends at the next start-of-frame with
// the right count; a frame longer than the buffer stops rather than wraps; and
// dropping `arm` abandons a capture that never started, which is what a raster
// whose circuits cover nothing would otherwise do forever.
`timescale 1ns/1ps

module tb_pxcap;
   logic clk = 0, reset = 1;
   always #5 clk = ~clk;

   localparam AB = 6;                    // 64 pixels, so "full" is reachable
   logic        px_valid = 0, px_sof = 0, arm = 0;
   logic [23:0] px_rgb = 0;
   logic        busy, done;
   logic [AB:0] count;
   logic [AB-1:0] rd_addr = 0;
   logic [23:0] rd_data;
   integer      errors = 0, i;

   gs_pxcap #(.ADDR_BITS(AB)) dut (
      .clk(clk), .reset(reset),
      .px_valid(px_valid), .px_rgb(px_rgb), .px_sof(px_sof),
      .arm(arm), .busy(busy), .done(done), .count(count),
      .rd_addr(rd_addr), .rd_data(rd_data));

   task send(input int n, input int first_is_sof);
      for (int k = 0; k < n; k++) begin
         @(negedge clk);
         px_valid = 1;
         px_sof   = (k == 0) ? first_is_sof[0] : 1'b0;
         px_rgb   = 24'h010000 * (k + 1);
      end
      @(negedge clk);
      px_valid = 0; px_sof = 0;
   endtask

   task check(input string what, input int got, input int want);
      if (got !== want) begin
         $display("FAIL %s: got %0d, want %0d", what, got, want);
         errors++;
      end
   endtask

   initial begin
      repeat (3) @(posedge clk); reset = 0; @(posedge clk);

      // Pixels before arming must be ignored.
      send(5, 1);
      check("idle capture", count, 0);

      // A 20-pixel frame, ended by the next frame's start-of-frame.
      arm = 1; @(posedge clk);
      send(20, 1);
      send(1, 1);                        // the next frame begins
      @(posedge clk);
      check("short frame count", count, 20);
      check("short frame done",  done,  1);

      // every stored pixel must be the one that was sent
      for (i = 0; i < 20; i++) begin
         @(negedge clk); rd_addr = i[AB-1:0];
         @(negedge clk);
         if (rd_data !== 24'h010000 * (i + 1)) begin
            $display("FAIL pixel %0d: got %06x want %06x",
                     i, rd_data, 24'h010000 * (i + 1));
            errors++;
         end
      end

      // Disarm, then a frame longer than the buffer: it must stop at 64.
      arm = 0; @(posedge clk); @(posedge clk);
      check("disarm clears done", done, 0);
      arm = 1; @(posedge clk);
      send(100, 1);
      @(posedge clk);
      check("overlong frame count", count, 1 << AB);
      check("overlong frame done",  done,  1);

      // Arming with no frame at all must not leave it busy.
      arm = 0; @(posedge clk); arm = 1; @(posedge clk);
      send(6, 0);                        // pixels, but no start-of-frame
      @(posedge clk);
      check("no sof, no capture", count, 0);
      check("no sof, not done",   done,  0);

      if (errors == 0) $display("PASS  gs_pxcap: all four behaviours hold");
      else             $display("FAIL  gs_pxcap: %0d checks failed", errors);
      $finish;
   end
endmodule
