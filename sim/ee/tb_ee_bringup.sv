// Run a program through ee_bringup exactly as the card does, and dump the
// registers at the park.
//
// This testbench exists because ee_bringup did not have one, and that omission
// cost two bitstreams and several hours on the card. tb_ee_core.sv verifies the
// R5900 against a memory model written in SystemVerilog; ee_bringup is a
// *second* implementation of that same memory, in VHDL, and nothing checked it
// against the core at all. The program that passed in simulation failed twelve
// times out of twelve on silicon, and the difference was one guard the
// SystemVerilog memory had and the VHDL one did not.
//
// The sequence mirrors tools/ee/eerun.py step for step -- hold reset, write the
// program through the host port, release reset, let it reach the park, read the
// registers through the debug window -- so that a disagreement here is a
// disagreement the card would also show.
`timescale 1ns/1ps
module tb_ee_bringup;
   localparam WORDS_LOG2 = 12;

   logic clk = 0, reset = 1;
   always #1 clk = ~clk;

   logic [31:0]  pc_reset = 32'h0;
   logic         h_we = 0;
   logic [WORDS_LOG2-1:0] h_addr = 0;
   logic [127:0] h_wdata = 0;
   wire  [127:0] h_rdata;
   wire  [31:0]  retires;
   wire  [63:0]  last_pc;
   logic [4:0]   dbg_sel = 0;
   wire  [127:0] dbg_gpr;
   wire  [63:0]  dbg_hi, dbg_lo;
   wire  [15:0]  dbg_traps;
   wire  [2:0]   dbg_stall;
   wire  [31:0]  p_addr;
   wire          p_ready, p_write;
   wire  [127:0] p_rdata;

   ee_bringup #(.WORDS_LOG2(WORDS_LOG2)) dut (
      .clk(clk), .reset(reset), .pc_reset(pc_reset),
      .h_we(h_we), .h_addr(h_addr), .h_wdata(h_wdata), .h_rdata(h_rdata),
      .retires(retires), .last_pc(last_pc),
      .dbg_sel(dbg_sel), .dbg_gpr(dbg_gpr),
      .dbg_hi(dbg_hi), .dbg_lo(dbg_lo),
      .dbg_traps(dbg_traps), .dbg_stall(dbg_stall),
      .dbg_d_addr(p_addr), .dbg_d_ready(p_ready),
      .dbg_d_write(p_write), .dbg_d_rdata(p_rdata));

   integer   nready = 0, nwrite = 0;
   // A plain always block, not a fork. The forked version of this logger ran
   // and printed nothing, while this one works on the same signals -- so the
   // absence of output was the logger, not the design, and thirteen data
   // accesses had been happening all along.
   always @(negedge clk) if (!reset && p_ready) begin
      nready <= nready + 1;
      if (p_write) nwrite <= nwrite + 1;
      $display("D %08h %0d %032h", p_addr, p_write, p_rdata);
   end

   integer   fd, code, i, w;
   reg [31:0] words [0:4095];
   string    progfile;
   integer   cycles;

   initial begin
      if (!$value$plusargs("prog=%s", progfile)) progfile = "prog.hex";
      if (!$value$plusargs("cycles=%d", cycles))  cycles  = 40000;
      for (i = 0; i < 4096; i = i + 1) words[i] = 32'h0;
      fd = $fopen(progfile, "r");
      i  = 0;
      while (!$feof(fd) && i < 4096) begin
         code = $fscanf(fd, "%h\n", w);
         if (code == 1) begin words[i] = w; i = i + 1; end
      end
      $fclose(fd);

      // Load through the host port, four instructions to a 128-bit line.
      @(negedge clk);
      for (i = 0; i < 1024; i = i + 1) begin
         h_addr  = i[WORDS_LOG2-1:0];
         h_wdata = {words[4*i+3], words[4*i+2], words[4*i+1], words[4*i+0]};
         h_we    = 1;
         @(negedge clk);
      end
      h_we = 0;
      @(negedge clk);

      reset = 0;
      // Log the first few hundred retirements. When the registers disagree but
      // memory does not, the question is where the two machines stopped
      // executing the same program, and only a trace answers it.
      // last_pc is a port, so no hierarchical reference into the VHDL is
      // needed -- xsim will not resolve one across the language boundary.
      // Printing it whenever it changes gives the retirement order; a pc that
      // retires twice in a row is indistinguishable from one, which is fine
      // here because the question is where the two traces first diverge.
      fork
         begin
            integer seen;
            logic [31:0] prev;
            seen = 0;
            prev = 32'hFFFFFFFF;
            forever begin
               @(posedge clk);
               if (!reset && last_pc[31:0] !== prev && seen < 400) begin
                  $display("P %0d %08h", seen, last_pc[31:0]);
                  prev = last_pc[31:0];
                  seen = seen + 1;
               end
            end
         end
      join_none
      repeat (cycles) @(posedge clk);

      // Read the registers with the core still running. It is parked in a
      // branch to itself, so the register file is stable -- and asserting reset
      // first would clear it, which is what the first version of this file did
      // and why every register read as zero while the retire counter said
      // fifteen thousand instructions had executed. tools/ee/eerun.py reads
      // before it resets, for the same reason.
      $display("RETIRES %0d TRAPS %0d STALL %0d", retires, dbg_traps, dbg_stall);
      $display("DREADY_CYCLES %0d  DWRITES %0d", nready, nwrite);
      for (i = 0; i < 32; i = i + 1) begin
         dbg_sel = i[4:0];
         @(posedge clk); @(posedge clk); @(posedge clk);
         $display("R%0d %032h", i, dbg_gpr);
      end
      // Dump memory too. If the registers disagree, the next question is
      // always whether the stores went to the right places or the loads came
      // back with the wrong data, and a register trace cannot tell those apart.
      reset = 1;
      @(negedge clk);
      for (i = 0; i < 1024; i = i + 1) begin
         h_addr = i[WORDS_LOG2-1:0];
         h_we   = 0;
         @(negedge clk); @(negedge clk);
         if (h_rdata !== 128'h0)
            $display("M %04h %032h", i, h_rdata);
      end
      $finish;
   end
endmodule
