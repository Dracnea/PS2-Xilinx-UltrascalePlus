// tb_ee_core.sv -- run a program on the R5900 integer datapath and print the
// architectural state after every retired instruction, in the format
// sim/ee/r5900_ref.py prints, so the two can be diffed line for line.
//
// The memories answer with a cycle of latency rather than combinationally.  A
// core that only works with zero-latency memory passes its testbench and fails
// on the card, and the wait states are where a state machine gets its handshake
// wrong.
`timescale 1ns/1ps

module tb_ee_core;
   logic clk = 0, reset = 1;
   always #5 clk = ~clk;

   logic [31:0] i_addr, i_data;
   logic        i_read, i_ready;
   logic [31:0] d_addr;
   logic        d_read, d_write, d_ready;
   logic [7:0]  d_be;
   logic [63:0] d_wdata, d_rdata;
   logic        retire;
   logic [63:0] retire_pc, dbg_gpr, dbg_hi, dbg_lo;
   logic [4:0]  dbg_sel = 0;
   logic [15:0] dbg_traps;

   ee_core dut (
      .clk(clk), .reset(reset), .pc_reset(32'h0000_0000),
      .i_addr(i_addr), .i_read(i_read), .i_data(i_data), .i_ready(i_ready),
      .d_addr(d_addr), .d_read(d_read), .d_write(d_write), .d_be(d_be),
      .d_wdata(d_wdata), .d_rdata(d_rdata), .d_ready(d_ready),
      .retire(retire), .retire_pc(retire_pc),
      .dbg_sel(dbg_sel), .dbg_gpr(dbg_gpr), .dbg_hi(dbg_hi), .dbg_lo(dbg_lo),
      .dbg_traps(dbg_traps));

   localparam MEMBYTES = 1 << 16;
   logic [7:0]  mem      [0:MEMBYTES-1];
   logic [31:0] memwords [0:4095];

   // ---- instruction port: one cycle of latency -----------------------------
   always_ff @(posedge clk) begin
      i_ready <= 1'b0;
      if (i_read && !i_ready) begin
         i_data  <= {mem[i_addr+3], mem[i_addr+2], mem[i_addr+1], mem[i_addr]};
         i_ready <= 1'b1;
      end
   end

   // ---- data port: 64 bits with byte enables, one cycle of latency ---------
   integer bi;
   always_ff @(posedge clk) begin
      d_ready <= 1'b0;
      if ((d_read || d_write) && !d_ready) begin
         if (d_write)
            for (bi = 0; bi < 8; bi = bi + 1)
               if (d_be[bi]) mem[(d_addr & ~32'h7) + bi] <= d_wdata[bi*8 +: 8];
         for (bi = 0; bi < 8; bi = bi + 1)
            d_rdata[bi*8 +: 8] <= mem[(d_addr & ~32'h7) + bi];
         d_ready <= 1'b1;
      end
   end

   // ---- run and report -----------------------------------------------------
   string  progfile;   // 'program' is a SystemVerilog keyword
   integer steps, n, r, fh;
   logic [63:0] regs [1:31];

   initial begin
      if (!$value$plusargs("program=%s", progfile)) progfile = "prog.hex";
      if (!$value$plusargs("steps=%d", steps))     steps = 64;
      for (n = 0; n < MEMBYTES; n = n + 1) mem[n] = 8'h00;
      $readmemh(progfile, memwords);
      // $readmemh fills 32-bit words; spread them into the byte array
      for (n = 0; n < 4096; n = n + 1) begin
         mem[n*4+0] = memwords[n][7:0];
         mem[n*4+1] = memwords[n][15:8];
         mem[n*4+2] = memwords[n][23:16];
         mem[n*4+3] = memwords[n][31:24];
      end
      repeat (4) @(posedge clk);
      reset <= 0;

      n = 0;
      while (n < steps) begin
         // Sample a short way past the edge, not on it: retire and retire_pc
         // are driven by the same edge that would be read here, and reading
         // them on the edge while reading the registers after it takes the two
         // from different cycles -- which shows up as a PC shifted by exactly
         // one instruction while every register still matches.
         @(posedge clk);
         #0.1;
         if (retire) begin
            // dbg_gpr is combinational from dbg_sel, so all 31 can be read
            // between edges; 31 x 0.1ns stays well inside a 10ns period.
            for (r = 1; r <= 31; r = r + 1) begin
               dbg_sel = r[4:0];
               #0.1 regs[r] = dbg_gpr;
            end
            $write("%4d pc=%016x hi=%016x lo=%016x", n, retire_pc, dbg_hi, dbg_lo);
            for (r = 1; r <= 31; r = r + 1) $write(" r%02d=%016x", r, regs[r]);
            $write("\n");
            n = n + 1;
         end
      end
      // The same region the reference dumps: a store to the wrong address is
      // invisible in the registers until something loads it back.
      for (n = 'h2000; n < 'h2400; n = n + 8)
         $write("MEM %08x %02x%02x%02x%02x%02x%02x%02x%02x\n", n,
                mem[n+7], mem[n+6], mem[n+5], mem[n+4],
                mem[n+3], mem[n+2], mem[n+1], mem[n+0]);
      if (dbg_traps != 0) $display("# traps: %0d", dbg_traps);
      $finish;
   end

endmodule
