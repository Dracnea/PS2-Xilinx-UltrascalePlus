// tb_iop.sv -- runs boot_test.hex on the IOP subsystem and watches the POST
// register.  PASS on 0xAA, FAIL on 0xEE, an unexpected exception, a CPU error
// flag, or the timeout.
`timescale 1ns/1ps
module tb_iop;
   // 36.864 MHz and its phase-aligned 2x / 3x, as the PSX core's PLL provides
   localparam real P1 = 27.1267;
   reg clk1x = 0, clk2x = 0, clk3x = 0, reset = 1;
   always #(P1/2) clk1x = ~clk1x;
   always #(P1/4) clk2x = ~clk2x;
   always #(P1/6) clk3x = ~clk3x;

   reg         rom_wr = 0;
   reg  [19:0] rom_addr = 0;
   reg  [31:0] rom_data = 0;
   wire [7:0]  post_code;
   wire        post_wr, cpu_error, mem_idle;
   wire        con_wr; wire [7:0] con_data;      // the IOP's serial console (Kprintf)
   always @(posedge clk1x) if (con_wr) $write("%c", con_data);
   reg         vblank = 0, hblank = 0;
   // the SIF's host side: the bench stands in for the Emotion Engine
   reg  [2:0]  sif_sel = 0;
   reg  [31:0] sif_data = 0;
   reg         sif_we = 0;
   wire [31:0] sif_mscom, sif_smcom, sif_msflag, sif_smflag, sif_ctrl;

   // CDVD: the bench is the disc. It answers a sector request with a
   // synthetic ISO9660 volume descriptor -- 0x01 "CD001" 0x01 -- which is what
   // sector 16 of a real disc holds, so the boot test can check for it.
   wire        cdvd_sec_req;
   wire [31:0] cdvd_sec_lba;
   reg  [8:0]  cdvd_sec_waddr = 0;
   reg  [31:0] cdvd_sec_wdata = 0;
   reg         cdvd_sec_we = 0, cdvd_sec_done = 0;
   // No disc to begin with: stage 0A checks the no-disc answers (a read must
   // report error 0x12) and would fail with one inserted. The bench "puts a
   // disc in the tray" once stage 0D has passed, which is the same thing the
   // host does on hardware with `iop_post.py cdvd disc on` before the read
   // test.
   reg         disc_present = 0;

   // memory peek: the host-side port that dumps IOP RAM/ROM while the CPU is reset
   reg         peek_req = 0;
   reg  [24:0] peek_addr = 0;
   wire [31:0] peek_data;
   wire        peek_valid;

   iop_top dut
   (
      .clk1x(clk1x), .clk2x(clk2x), .clk3x(clk3x), .reset(reset),
      .hblank(hblank), .vblank(vblank), .ext_irq(32'h0), .pad0_buttons(16'h5A3C),
      .rom_wr(rom_wr), .rom_addr(rom_addr), .rom_data(rom_data),
      .post_code(post_code), .post_wr(post_wr), .con_wr(con_wr), .con_data(con_data),
      .peek_req(peek_req), .peek_addr(peek_addr), .peek_data(peek_data), .peek_valid(peek_valid),
      .cdvd_disc_present(disc_present), .cdvd_disc_type(8'h14),
      .cdvd_sec_req(cdvd_sec_req), .cdvd_sec_lba(cdvd_sec_lba),
      .cdvd_sec_waddr(cdvd_sec_waddr), .cdvd_sec_wdata(cdvd_sec_wdata),
      .cdvd_sec_we(cdvd_sec_we), .cdvd_sec_done(cdvd_sec_done),
      .sif_host_sel(sif_sel), .sif_host_data(sif_data), .sif_host_we(sif_we),
      .sif_mscom(sif_mscom), .sif_smcom(sif_smcom), .sif_msflag(sif_msflag),
      .sif_smflag(sif_smflag), .sif_ctrl(sif_ctrl),
      .cpu_error(cpu_error), .mem_idle(mem_idle)
   );

   task sif_write(input [2:0] sel, input [31:0] d);
      begin
         @(posedge clk1x);
         sif_sel <= sel; sif_data <= d; sif_we <= 1;
         @(posedge clk1x);
         sif_we <= 0;
      end
   endtask

   // Stand in for the EE: once the IOP has published its ready bit in SMFLAG,
   // answer the way the EE does -- put a word in MSCOM and set MSFLAG bit 16,
   // which is the bit SIFMAN spins on.
   initial begin
      wait (sif_smflag[16] === 1'b1);
      $display("[%0t] bench(EE): IOP set SMFLAG=%08x, answering", $time, sif_smflag);
      sif_write(3'd0, 32'h5A5A1234);      // MSCOM
      sif_write(3'd1, 32'h00010000);      // set MSFLAG bit 16
   end

   // insert the disc after stage 0D, before the read test
   always @(posedge clk1x) begin
      if (post_wr && post_code == 8'h0D) begin
         disc_present <= 1;
         $display("[%0t] bench(disc): inserting a disc for the read test", $time);
      end
   end

   // serve sectors for as long as the test asks for them
   integer si;
   initial begin
      forever begin
         wait (cdvd_sec_req === 1'b1);
         $display("[%0t] bench(disc): sector %0d requested", $time, cdvd_sec_lba);
         for (si = 0; si < 512; si = si + 1) begin
            @(posedge clk1x);
            cdvd_sec_waddr <= si[8:0];
            // word 0 is the ISO9660 signature: 01 'C' 'D' '0' then '0' '1' 01
            if (si == 0)      cdvd_sec_wdata <= 32'h30444301;
            else if (si == 1) cdvd_sec_wdata <= 32'h00013130;
            else              cdvd_sec_wdata <= {cdvd_sec_lba[15:0], 7'b0, si[8:0]};
            cdvd_sec_we <= 1;
         end
         @(posedge clk1x); cdvd_sec_we <= 0;
         @(posedge clk1x); cdvd_sec_done <= 1;
         @(posedge clk1x); cdvd_sec_done <= 0;
         wait (cdvd_sec_req === 1'b0);
      end
   end

   reg [127:0] spu_row;
   reg [31:0] image [0:1048575];        // up to the full 4 MB ROM (a real BIOS)
   // where the CPU was: rings of the last instruction fetches and data accesses
   integer k;      // trap-dump loop variable (declared before first use)
   integer words;  // ROM words loaded; also sizes the runaway trap
   reg [31:0] fetch_ring [0:63]; reg [31:0] data_ring [0:31]; reg [31:0] data_ring_d [0:31]; reg data_ring_w [0:31]; reg [31:0] data_ring_pc [0:31];
   integer nfetch = 0, ndata = 0; reg [31:0] last_if = 0;
   always @(posedge clk1x) begin
      if (dut.mem_request && !dut.mem_isData && dut.mem_addressInstr != last_if) begin
         fetch_ring[nfetch % 64] <= dut.mem_addressInstr; nfetch <= nfetch + 1; last_if <= dut.mem_addressInstr;
      end
      if (dut.mem_request && dut.mem_isData) begin
         data_ring[ndata % 32] <= dut.mem_addressData; data_ring_d[ndata % 32] <= dut.mem_dataWrite; data_ring_w[ndata % 32] <= !dut.mem_rnw; data_ring_pc[ndata % 32] <= last_if; ndata <= ndata + 1;
      end
      // Runaway trap: the test image is well under 0xBFC02000, so a fetch above
      // that means the CPU has left the code and is grinding through zero-filled
      // ROM.  Catching it here shows where it went, instead of a ring full of
      // NOPs 75 ms later.
      if (!reset && ((post_wr && post_code == 8'h00) || dut.mem_addressInstr > (32'hBFC00000 + words*4 + 64) && dut.mem_addressInstr < 32'hC0000000)) begin
         $display("[%0t] TRAP: fetch at %08x, pc(last)=%08x, POST %02x", $time, dut.mem_addressInstr, last_if, post_code);
         $display("   dma state=%0d ch=%0d words=%0d ram_req=%b ram_gnt=%b",
                  dut.idma.state, dut.idma.ch, dut.idma.words, dut.idma.ram_req, dut.idma.ram_gnt);
         $display("   cdvd rd_state=%0d rd_pos=%0d rd_left=%0d dev_valid=%b dev_ready=%b istat=%02x irq=%b",
                  dut.icdvd.rd_state, dut.icdvd.rd_pos, dut.icdvd.rd_left,
                  dut.icdvd.dev_valid, dut.icdvd.dev_ready, dut.icdvd.istat, dut.icdvd.irq);
         $display("last %0d instruction fetches (oldest first):", nfetch < 64 ? nfetch : 64);
         for (k = (nfetch < 64 ? 0 : nfetch - 64); k < nfetch; k = k + 1) $display("   IF  %08x", fetch_ring[k % 64]);
         $display("last %0d data accesses (oldest first):", ndata < 32 ? ndata : 32);
         for (k = (ndata < 32 ? 0 : ndata - 32); k < ndata; k = k + 1) $display("   pc=%08x %s %08x %08x", data_ring_pc[k % 32], data_ring_w[k % 32] ? "ST" : "LD", data_ring[k % 32], data_ring_d[k % 32]);
         $finish;
      end
   end
   integer i, t0, run_ms;
   string romfile;

   // One peek: the CPU must already be in reset, which is the port's condition.
   task do_peek(input [24:0] a, output [31:0] d);
      integer guard;
      begin
         @(posedge clk1x);
         peek_addr <= a; peek_req <= 1;
         @(posedge clk1x);
         peek_req <= 0;
         guard = 0;
         while (!peek_valid && guard < 200) begin @(posedge clk1x); guard = guard + 1; end
         if (!peek_valid) begin $display("FAIL: peek of %08x never completed", a); $finish; end
         d = peek_data;
      end
   endtask

   // The peek port is checked after the boot test passes: hold the CPU in
   // reset, then read back the pattern stage 02 wrote to RAM at 0x00010000
   // and the first ROM word, which is the image the bench loaded.
   task check_peek;
      reg [31:0] d;
      begin
         reset <= 1;
         repeat (80) @(posedge clk1x);
         do_peek(25'h0010000, d);
         if (d !== 32'h12345678) begin $display("FAIL: peek RAM 0x00010000 = %08x, expected 12345678", d); $finish; end
         do_peek(25'h0010004, d);
         if (d !== 32'h12346789) begin $display("FAIL: peek RAM 0x00010004 = %08x, expected 12346789", d); $finish; end
         do_peek(25'h0800000, d);
         if (d !== image[0]) begin $display("FAIL: peek ROM word 0 = %08x, expected %08x", d, image[0]); $finish; end
         do_peek(25'h0800008, d);
         if (d !== image[2]) begin $display("FAIL: peek ROM word 2 = %08x, expected %08x", d, image[2]); $finish; end
         $display("peek: RAM 0x00010000/4 and ROM words 0/2 read back correctly");
      end
   endtask


   initial begin
      if (!$value$plusargs("rom=%s", romfile)) romfile = "boot_test.hex";
      if (!$value$plusargs("words=%d", words)) words = 4096;     // +words=1048576 for a BIOS
      if (!$value$plusargs("ms=%d", run_ms)) run_ms = 80;        // timeout in ms of IOP time
      $readmemh(romfile, image);
      // load the ROM through its write port while in reset
      @(posedge clk1x);
      for (i = 0; i < words; i = i + 1) begin
         rom_wr <= 1; rom_addr <= i; rom_data <= image[i];
         @(posedge clk1x);
      end
      rom_wr <= 0;
      repeat (8) @(posedge clk1x);
      reset <= 0;
      $display("[%0t] reset released", $time);
   end

   // a free-running vblank/hblank so timers that count them have something to count
   always begin
      #(P1*100) hblank = 1; #(P1*10) hblank = 0;
   end
   always begin
      #(P1*30000) vblank = 1; #(P1*2000) vblank = 0;
   end

   always @(posedge clk1x) begin
      if (post_wr) begin
         $display("[%0t] POST %02x", $time, post_code);
         if (post_code == 8'hAA) begin
            // stage 08 wrote 1111 2222 3333 4444 at byte 0x2000 of core 0's work RAM: row 0x200, lanes 0-3
            spu_row = dut.ispu2.gcores[0].iram.sim_row200;
            if (spu_row !== 128'h0000_0000_0000_0000_4444_3333_2222_1111) begin
               $display("FAIL: SPU core 0 RAM row 0x200 = %032x, expected ...4444333322221111", spu_row);
               $finish;
            end
            $display("SPU core 0 RAM row 0x200 = %032x (ok)", spu_row);
            check_peek;
            $display("PASS"); $finish;
         end
         if (post_code == 8'hEE) begin $display("FAIL: test reported failure"); $finish; end
      end
      if (cpu_error && !reset) begin $display("FAIL: cpu error flag"); $finish; end
   end

   initial begin
      #(P1 * 36875 * run_ms);   // run_ms ms of IOP time at 36.875 MHz
      $display("FAIL: timeout, last POST %02x", post_code);
      $display("last %0d distinct instruction fetches (oldest first):", nfetch < 64 ? nfetch : 64);
      for (i = (nfetch < 64 ? 0 : nfetch - 64); i < nfetch; i = i + 1) $display("   IF  %08x", fetch_ring[i % 64]);
      $display("last %0d data accesses (oldest first):", ndata < 32 ? ndata : 32);
      for (i = (ndata < 32 ? 0 : ndata - 32); i < ndata; i = i + 1) $display("   pc=%08x %s %08x %08x", data_ring_pc[i % 32], data_ring_w[i % 32] ? "ST" : "LD", data_ring[i % 32], data_ring_d[i % 32]);
      $finish;
   end
endmodule
