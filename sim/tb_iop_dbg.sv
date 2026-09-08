// tb_iop_dbg.sv -- tb_iop with a bus trace, for finding out why a ROM does not boot.
`timescale 1ns/1ps
module tb_iop_dbg;
   localparam real P1 = 27.1267;
   reg clk1x = 0, clk2x = 0, clk3x = 0, reset = 1;
   always #(P1/2) clk1x = ~clk1x;
   always #(P1/4) clk2x = ~clk2x;
   always #(P1/6) clk3x = ~clk3x;
   reg rom_wr = 0; reg [19:0] rom_addr = 0; reg [31:0] rom_data = 0;
   wire [7:0] post_code; wire post_wr, cpu_error, mem_idle;
   iop_top dut(.clk1x(clk1x), .clk2x(clk2x), .clk3x(clk3x), .reset(reset), .hblank(1'b0), .vblank(1'b0), .ext_irq(32'h0), .pad0_buttons(16'h5A3C),
      .rom_wr(rom_wr), .rom_addr(rom_addr), .rom_data(rom_data), .post_code(post_code), .post_wr(post_wr), .cpu_error(cpu_error), .mem_idle(mem_idle));
   reg [31:0] image [0:4095]; integer i;
   integer cyc = 0, ncycles, quiet, regs, rfrom, rto, pfrom, pto, tfrom;
   reg [31:0] pc_prev = 0;
   initial begin
      $readmemh("boot_test.hex", image);
      @(posedge clk1x);
      for (i = 0; i < 4096; i = i + 1) begin rom_wr <= 1; rom_addr <= i; rom_data <= image[i]; @(posedge clk1x); end
      rom_wr <= 0; repeat (8) @(posedge clk1x); reset <= 0; $display("[%0t] reset released", $time);
      $display("regfile altdpram params: width=%0d widthad=%0d numwords=%0d width_byteena=%0d BE=%0d memsize=%0d databits=%0d", dut.icpu.iregisterfile1.ialtdpram.width, dut.icpu.iregisterfile1.ialtdpram.widthad, dut.icpu.iregisterfile1.ialtdpram.numwords, dut.icpu.iregisterfile1.ialtdpram.width_byteena, dut.icpu.iregisterfile1.ialtdpram.BE, $size(dut.icpu.iregisterfile1.ialtdpram.mem), $bits(dut.icpu.iregisterfile1.ialtdpram.data));
      $display("regfile altdpram ports: byteena=%b rden=%b inclocken=%b outclocken=%b aclr=%b", dut.icpu.iregisterfile1.ialtdpram.byteena, dut.icpu.iregisterfile1.ialtdpram.rden, dut.icpu.iregisterfile1.ialtdpram.inclocken, dut.icpu.iregisterfile1.ialtdpram.outclocken, dut.icpu.iregisterfile1.ialtdpram.aclr);
      $display("icache altsyncram ports: byteena_a=%b rden_a=%b rden_b=%b clocken0=%b clocken1=%b", dut.icpu.gcache[0].icache.altsyncram_component.byteena_a, dut.icpu.gcache[0].icache.altsyncram_component.rden_a, dut.icpu.gcache[0].icache.altsyncram_component.rden_b, dut.icpu.gcache[0].icache.altsyncram_component.clocken0, dut.icpu.gcache[0].icache.altsyncram_component.clocken1);
      if (!$value$plusargs("cycles=%d", ncycles)) ncycles = 3000;
      if (!$value$plusargs("quiet=%d", quiet))   quiet = 0;     // 1: hide instruction fetches
      if (!$value$plusargs("regs=%d", regs))     regs = 0;      // 1: register-file trace
      if (!$value$plusargs("rfrom=%d", rfrom))   rfrom = 0;
      if (!$value$plusargs("rto=%d", rto))       rto = 0;
      if (!$value$plusargs("pfrom=%d", pfrom))   pfrom = 0;    // PC-jump trace window
      if (!$value$plusargs("pto=%d", pto))       pto = 0;
      if (!$value$plusargs("tfrom=%d", tfrom))   tfrom = 0;    // start of the transaction trace
      repeat (ncycles) @(posedge clk1x);
      $display("END last POST %02x cpu_error=%b", post_code, cpu_error); $finish;
   end
   // +spu=1: SPU core 0's work-RAM port and its transfer FIFO
   integer spu; reg [18:0] spu_adr; reg [31:0] spu_wd, spu_rd; reg [1:0] spu_ena, spu_rnw, spu_done;
   initial if (!$value$plusargs("spu=%d", spu)) spu = 0;
   always @(posedge clk1x) if (spu && !reset) begin
      if (dut.ispu2.gcores[0].ispu.ispu_ram.sdram_ena)
         $display("%8d SPU0 spu_ram.sdram_ena rnw=%b adr=%05x", cyc, dut.ispu2.gcores[0].ispu.ispu_ram.sdram_rnw, dut.ispu2.gcores[0].ispu.ispu_ram.sdram_Adr);
      if (dut.ispu2.gcores[0].iram.wbe != 0)
         $display("%8d SPU0 spuram wbe=%b wrow=%04x", cyc, dut.ispu2.gcores[0].iram.wbe, dut.ispu2.gcores[0].iram.wrow);
      if (dut.ispu2.gcores[0].iram.ram_ena && !dut.ispu2.gcores[0].iram.ram_rnw)
         $display("%8d SPU0 spuram WR adr=%05x wdata=%08x be=%b wbe=%b wrow=%05x", cyc, dut.ispu2.gcores[0].iram.ram_Adr, dut.ispu2.gcores[0].iram.ram_dataWrite, dut.ispu2.gcores[0].iram.ram_be, dut.ispu2.gcores[0].iram.wbe, dut.ispu2.gcores[0].iram.wrow);
      if (dut.ispu2.gcores[0].ispu.ram_request && !dut.ispu2.gcores[0].ispu.ram_rnw)
         $display("%8d SPU0 spu.ram_request WR adr=%05x data=%04x isTransfer=%b", cyc, dut.ispu2.gcores[0].ispu.ram_Adr, dut.ispu2.gcores[0].ispu.ram_dataWrite, dut.ispu2.gcores[0].ispu.ram_isTransfer);
      if (dut.ispu2.gcores[0].ispu.FifoIn_Wr) $display("%8d SPU0 fifo in  <= %04x", cyc, dut.ispu2.gcores[0].ispu.FifoIn_Din);
      if (dut.ispu2.gcores[0].ispu.FifoIn_Rd) $display("%8d SPU0 fifo out => %04x (empty=%b)", cyc, dut.ispu2.gcores[0].ispu.FifoIn_Dout, dut.ispu2.gcores[0].ispu.FifoIn_Empty);
   end
   // +rf=1: the register-file model's own view of its write port and array
   integer rf;
   initial if (!$value$plusargs("rf=%d", rf)) rf = 0;
   always @(posedge dut.icpu.iregisterfile1.ialtdpram.inclock) if (rf && !reset) begin
      if (cyc >= 264 && cyc <= 270) $display("%5d RF    edge wren=%b wraddress=%0d mem[29]=%08x", cyc, dut.icpu.iregisterfile1.ialtdpram.wren, dut.icpu.iregisterfile1.ialtdpram.wraddress, dut.icpu.iregisterfile1.ialtdpram.mem[29]);
      if (dut.icpu.iregisterfile1.ialtdpram.wren)
         $display("%5d RF    write wraddress=%0d data=%08x byteena=%b  (mem[29]=%08x mem[8]=%08x mem[0]=%08x)", cyc, dut.icpu.iregisterfile1.ialtdpram.wraddress, dut.icpu.iregisterfile1.ialtdpram.data, dut.icpu.iregisterfile1.ialtdpram.byteena,
            dut.icpu.iregisterfile1.ialtdpram.mem[29], dut.icpu.iregisterfile1.ialtdpram.mem[8], dut.icpu.iregisterfile1.ialtdpram.mem[0]);
   end
   always @(posedge clk1x) if (!reset) begin
      cyc = cyc + 1;
      if (cyc >= tfrom) begin
      if (dut.mem_request && !(quiet && !dut.mem_isData)) $display("%5d CPU  req rnw=%b isData=%b isCache=%b addrI=%08x addrD=%08x size=%d mask=%b wdata=%08x", cyc, dut.mem_rnw, dut.mem_isData, dut.mem_isCache, dut.mem_addressInstr, dut.mem_addressData, dut.mem_reqsize, dut.mem_writeMask, dut.mem_dataWrite);
      if (dut.mem_done && !quiet)    $display("%5d CPU  done data=%08x tagvalids=%b", cyc, dut.mem_dataRead, dut.mem_tagvalids);
      if (dut.ram_ena && !(quiet && dut.ram_Adr[23]))     $display("%5d RAM  ena rnw=%b adr=%07x be=%b cache=%b wdata=%08x", cyc, dut.ram_rnw, dut.ram_Adr, dut.ram_be, dut.ram_cache, dut.ram_dataWrite);
      if (dut.ram_done && !quiet)    $display("%5d RAM  done data=%08x", cyc, dut.ram_dataRead);
      if (dut.cache_wr != 0 && !quiet) $display("%5d RAM  cache_wr=%b addr=%02x data=%08x", cyc, dut.cache_wr, dut.cache_addr, dut.cache_data);
      if (dut.bus_memc_write)  $display("%5d MEMC write addr=%02x data=%08x", cyc, dut.bus_memc_addr, dut.bus_memc_dataWrite);
      if (dut.bus_memc_read)   $display("%5d MEMC read  addr=%02x -> %08x (next cycle)", cyc, dut.bus_memc_addr, dut.bus_memc_dataRead);
      if (dut.bus_memc2_write) $display("%5d MEMC2 write addr=%01x data=%08x", cyc, dut.bus_memc2_addr, dut.bus_memc2_dataWrite);
      if (dut.bus_memc2_read)  $display("%5d MEMC2 read  addr=%01x", cyc, dut.bus_memc2_addr);
      if (dut.bus_exp2_write) $display("%5d EXP2 write addr=%04x data=%02x", cyc, dut.bus_exp2_addr, dut.bus_exp2_dataWrite);
      if (post_wr) $display("%5d POST %02x", cyc, post_code);
      end
      // +pfrom/+pto: print every non-sequential PC change (jumps, branches, exceptions)
      if (cyc >= pfrom && cyc <= pto && dut.icpu.PC != pc_prev && dut.icpu.PC != pc_prev + 4)
         $display("%8d JUMP  %08x -> %08x  SR=%08x CAUSE=%08x EPC=%08x", cyc, pc_prev, dut.icpu.PC, dut.icpu.cop0_SR, dut.icpu.cop0_CAUSE, dut.icpu.cop0_EPC);
      pc_prev = dut.icpu.PC;
      // +regs=1: register-file activity in the window [rfrom, rto]
      if (regs && cyc >= rfrom && cyc <= rto) begin
         if (dut.icpu.regs_wren_a) $display("%5d REGW  r%0d <= %08x", cyc, dut.icpu.regs_address_a, dut.icpu.regs_data_a);
         $display("%5d REGS  PC=%08x op=%08x stall=%0d rd1 r%0d=%08x rd2 r%0d=%08x decV1=%08x decV2=%08x", cyc, dut.icpu.PC, dut.icpu.opcode0, dut.icpu.stall,
            dut.icpu.regs1_address_b, dut.icpu.regs1_q_b, dut.icpu.regs2_address_b, dut.icpu.regs2_q_b, dut.icpu.decodeValue1, dut.icpu.decodeValue2);
      end
   end
endmodule
