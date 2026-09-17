// tb_texcache.sv -- the texel cache, checked for being invisible and then for
// being a cache.
//
//   xsim tb -R -testplusarg "dir=CASEDIR"
//
// Two phases, because they answer two different questions and a single phase
// would let one of them hide.
//
// **Phase A -- invariance.** The whole gs_texsample vector set runs again, this
// time with the sampler's read port going through gs_texcache, and the colours
// are diffed against the *same* ref.txt the uncached block is checked against.
// If a cache changes any answer it is not a cache. The memory is quiescent here
// on purpose: with no writes, "as if there were no cache" is exact.
//
// Phase A also asserts two things a pure colour diff cannot see:
//
//   * `dbg_hits > 0`. A cache that misses on every access is correct and
//     useless, and it passes a correctness test with a green light.
//   * `dbg_dropped == 0`. The block keeps one miss, not a queue, because
//     gs_texsample never has two fetches outstanding. This counts the times
//     that assumption did not hold.
//
// The arbiter's grant is also withheld at random, so the request has to be
// *held* until the memory takes it. A cache tested with m_ready tied high never
// exercises the one thing that will be true in gs_top.
//
// **Phase C -- the hit rate that matters, and a second opinion on it.** The
// vectors above are random UV over the whole coordinate range with a random
// texture base each time, which is the worst input a cache can be given: there
// is no locality in them to exploit, so their hit rate is a floor and not a
// measurement. A rasteriser does not do that. It walks a primitive in raster
// order with an affine UV, which is the pattern the swizzle argument in
// gs_texcache.vhd is about. Phase C walks one and reports what the cache
// actually gets.
//
// The walk is also run through a **second gs_texsample wired straight to the
// memory**, with no cache in its path, and the two colour streams are compared
// pixel for pixel. That is a stronger statement than phase A makes: the same
// block, the same inputs, one with the cache and one without, and the answers
// have to be the same. The two run one after the other rather than side by side
// because there is one gs_clut and it has one lookup port.
//
// **Phase B -- coherence, directed and self-checking.** Local memory is one
// address space: the framebuffer the rasteriser writes and the texture this
// reads are the same 4 MB, and rendering to a texture is an ordinary PS2 idiom.
// These cases aim writes at the cache on purpose, including at the exact line
// being fetched and in the exact cycle of a lookup, because a coherence bug
// that needs a collision to appear will never appear by accident.
//
// Two of them are there for the plausible *wrong* implementations rather than
// for the right one:
//
//   * a snoop of a different tag at the same index must NOT invalidate. A cache
//     that invalidates on the index alone is coherent, passes every staleness
//     test, and throws away lines it still holds.
//   * a write to the line a miss is fetching must leave that line invalid. The
//     fill would otherwise store a word the memory read before the write, and
//     the stale line survives the write that should have killed it.
`timescale 1ns/1ps

module tb_texcache;
   localparam MEM_LINES = 131072;         // the GS's real 4 MB
   // A parameter rather than a constant so run_texcache_diff.sh --lines can
   // sweep it: the right size is a measurement, not a preference.
   parameter  SETS_LOG2 = 6;
   parameter  WAYS_LOG2 = 1;

   logic clk = 0, reset = 1;
   always #5 clk = ~clk;

   logic [255:0] mem [0:MEM_LINES-1];

   int errors = 0;

   // ---- the CLUT's own read port, as in tb_texsample -------------------------
   logic         c_rd_en;
   logic [16:0]  c_rd_addr;
   logic [255:0] c_rd_data;
   logic         c_rd_valid;
   logic [255:0] c_d1, c_d2;
   logic         c_v1, c_v2;
   always @(posedge clk) begin
      c_d1 <= mem[c_rd_addr]; c_v1 <= c_rd_en && !reset;
      c_d2 <= c_d1;           c_v2 <= c_v1;
   end
   assign c_rd_data = c_d2;
   assign c_rd_valid = c_v2;

   // ---- local memory behind the cache ---------------------------------------
   // Shaped exactly like gs_lmem: 256 bits, two clocks of read latency, and a
   // write port whose effect a read in the same cycle does not see -- gs_lmem
   // reads the array as a signal, so the old value is what comes back.
   logic         m_rd_en;
   logic [16:0]  m_rd_addr;
   logic [255:0] m_rd_data;
   logic         m_rd_valid;
   logic [255:0] m_d1, m_d2;
   logic         m_v1, m_v2;

   logic         w_en = 0;
   logic [16:0]  w_addr = 0;
   logic [255:0] w_data = 0;

   assign m_rd_data  = m_d2;
   assign m_rd_valid = m_v2;

   // The arbiter, standing in for gs_top's. Grant is withheld at random so the
   // cache has to hold its request rather than assume the memory is always free.
   logic m_ready = 1;
   int   grant_seed = 32'h5eed;
   logic stress_grant = 0;
   always @(posedge clk)
      m_ready <= stress_grant ? ($random(grant_seed) % 4 != 0) : 1'b1;

   // The read is taken only on a cycle the arbiter grants. Modelling gs_lmem
   // as answering every m_rd_en regardless is what a testbench does by default,
   // and it makes a cache that ignores m_ready indistinguishable from one that
   // honours it -- in gs_top the ungranted read simply never happens.
   always @(posedge clk) begin
      m_d1 <= mem[m_rd_addr]; m_v1 <= m_rd_en && m_ready && !reset;
      m_d2 <= m_d1;           m_v2 <= m_v1;
      if (w_en) mem[w_addr] <= w_data;
   end

   // ---- the cache -----------------------------------------------------------
   logic         k_c_rd_en;
   logic [16:0]  k_c_rd_addr;
   logic [255:0] k_c_rd_data;
   logic         k_c_rd_valid;
   logic         k_c_ready;
   logic         snoop_en = 0;
   logic [16:0]  snoop_addr = 0;
   logic         flush = 0;
   logic [31:0]  dbg_hits, dbg_misses, dbg_inval, dbg_dropped;

   gs_texcache #(.ADDR_BITS(17), .DATA_WIDTH(256),
                 .SETS_LOG2(SETS_LOG2), .WAYS_LOG2(WAYS_LOG2)) cache
     (.clk(clk), .reset(reset),
      .c_rd_en(k_c_rd_en), .c_rd_addr(k_c_rd_addr),
      .c_rd_data(k_c_rd_data), .c_rd_valid(k_c_rd_valid), .c_ready(k_c_ready),
      .m_rd_en(m_rd_en), .m_rd_addr(m_rd_addr),
      .m_rd_data(m_rd_data), .m_rd_valid(m_rd_valid), .m_ready(m_ready),
      .snoop_en(snoop_en), .snoop_addr(snoop_addr), .flush(flush),
      .dbg_hits(dbg_hits), .dbg_misses(dbg_misses),
      .dbg_inval(dbg_inval), .dbg_dropped(dbg_dropped));

   // ---- the palette ---------------------------------------------------------
   logic        clut_we = 0;
   logic [63:0] clut_tex0 = 0, clut_texclut = 0;
   logic [7:0]  clut_idx;
   logic [31:0] clut_data;
   logic        clut_busy;
   logic [15:0] clut_loads;
   logic        clut_unsup;

   // One palette, two samplers. They never run at the same time, so the lookup
   // port is muxed rather than duplicated -- a second gs_clut would be a second
   // copy of the thing under test in phase A.
   logic [7:0] dut_clut_idx, bare_clut_idx;
   logic       use_bare = 0;
   assign clut_idx = use_bare ? bare_clut_idx : dut_clut_idx;

   gs_clut palette
     (.clk(clk), .reset(reset),
      .we(clut_we), .tex0(clut_tex0), .texclut(clut_texclut),
      .rd_en(c_rd_en), .rd_addr(c_rd_addr), .rd_data(c_rd_data),
      .rd_valid(c_rd_valid),
      .idx(clut_idx), .entry(clut_data),
      .busy(clut_busy), .loads(clut_loads), .unsupported(clut_unsup));

   // ---- the sampler, reading through the cache ------------------------------
   logic               req = 0;
   logic signed [16:0] u_fixed = 0, v_fixed = 0;
   logic [31:0]        frag = 0;
   logic [63:0]        s_tex0 = 0, s_clamp = 0;
   logic               done, s_busy;
   logic [31:0]        colour;

   logic         s_rd_en;
   logic [16:0]  s_rd_addr;

   gs_texsample dut
     (.clk(clk), .reset(reset),
      .req(req), .u_fixed(u_fixed), .v_fixed(v_fixed), .frag(frag),
      .tex0(s_tex0), .clamp(s_clamp),
      .rd_en(s_rd_en), .rd_addr(s_rd_addr),
      .rd_data(k_c_rd_data), .rd_valid(k_c_rd_valid),
      .clut_idx(dut_clut_idx), .clut_data(clut_data),
      .done(done), .colour(colour), .busy(s_busy));

   // ---- the same sampler, no cache in its path ------------------------------
   logic         b_req = 0;
   logic         b_done, b_busy;
   logic [31:0]  b_colour;
   logic         b_rd_en;
   logic [16:0]  b_rd_addr;
   logic [255:0] b_rd_data;
   logic         b_rd_valid;
   logic [255:0] b_d1, b_d2;
   logic         b_v1, b_v2;
   always @(posedge clk) begin
      b_d1 <= mem[b_rd_addr]; b_v1 <= b_rd_en && !reset;
      b_d2 <= b_d1;           b_v2 <= b_v1;
   end
   assign b_rd_data  = b_d2;
   assign b_rd_valid = b_v2;

   gs_texsample bare
     (.clk(clk), .reset(reset),
      .req(b_req), .u_fixed(u_fixed), .v_fixed(v_fixed), .frag(frag),
      .tex0(s_tex0), .clamp(s_clamp),
      .rd_en(b_rd_en), .rd_addr(b_rd_addr),
      .rd_data(b_rd_data), .rd_valid(b_rd_valid),
      .clut_idx(bare_clut_idx), .clut_data(clut_data),
      .done(b_done), .colour(b_colour), .busy(b_busy));

   // In phase B the testbench takes the cache's client port for itself, so the
   // coherence cases can be aimed precisely. `tb_drive` is the switch.
   logic         tb_drive = 0;
   logic         tb_rd_en = 0;
   logic [16:0]  tb_rd_addr = 0;
   assign k_c_rd_en   = tb_drive ? tb_rd_en   : s_rd_en;
   assign k_c_rd_addr = tb_drive ? tb_rd_addr : s_rd_addr;

   // ---- helpers for phase B --------------------------------------------------
   int h0, m0;

   task automatic cache_read(input [16:0] a, output [255:0] d);
      begin
         while (!k_c_ready) @(posedge clk);
         tb_rd_addr <= a;
         tb_rd_en   <= 1;
         @(posedge clk);
         tb_rd_en   <= 0;
         while (!k_c_rd_valid) @(posedge clk);
         d = k_c_rd_data;
         @(posedge clk);
      end
   endtask

   task automatic mem_write(input [16:0] a, input [255:0] d);
      begin
         w_addr     <= a;
         w_data     <= d;
         w_en       <= 1;
         snoop_addr <= a;
         snoop_en   <= 1;
         @(posedge clk);
         w_en     <= 0;
         snoop_en <= 0;
         @(posedge clk);
      end
   endtask

   task automatic expect_eq(input [255:0] got, input [255:0] want, input string what);
      begin
         if (got !== want) begin
            $display("FAIL  %s: got %064x want %064x", what, got, want);
            errors++;
         end
      end
   endtask

   task automatic expect_int(input int got, input int want, input string what);
      begin
         if (got !== want) begin
            $display("FAIL  %s: got %0d want %0d", what, got, want);
            errors++;
         end
      end
   endtask

   localparam WALK_W = 64, WALK_H = 48;
   logic [31:0] walk [0:WALK_W*WALK_H-1];
   int wx, wy, wi, wh, wm;

   string dir;
   int    fh, code, n;
   longint c_u, c_v;
   logic [31:0] c_frag;
   logic [63:0] c_tex0, c_clamp;
   logic [255:0] d, e;
   logic [16:0]  A, B, C, D;

   function automatic [SETS_LOG2-1:0] fold_set(input [16:0] a);
      fold_set = a[SETS_LOG2-1:0] ^ a[16:SETS_LOG2];
   endfunction

   initial begin
      if (!$value$plusargs("dir=%s", dir)) begin
         $display("FAIL  no dir given"); $finish;
      end
      $readmemh({dir, "/mem.hex"}, mem);

      repeat (4) @(posedge clk);
      reset <= 0;
      repeat (2) @(posedge clk);

      fh = $fopen({dir, "/clut.txt"}, "r");
      code = $fscanf(fh, "%h %h\n", clut_tex0, clut_texclut);
      $fclose(fh);
      @(posedge clk);
      clut_we <= 1;
      @(posedge clk);
      clut_we <= 0;
      @(posedge clk);
      while (clut_busy) @(posedge clk);
      if (clut_unsup) begin
         $display("FAIL  the palette load was refused"); $finish;
      end

      // ================= phase A: the cache must be invisible =================
      stress_grant <= 1;
      fh = $fopen({dir, "/cases.txt"}, "r");
      if (fh == 0) begin
         $display("FAIL  cannot open %s/cases.txt", dir); $finish;
      end

      n = 0;
      forever begin
         code = $fscanf(fh, "%d %d %h %h %h\n",
                        c_u, c_v, c_frag, c_tex0, c_clamp);
         if (code != 5) break;

         @(posedge clk);
         u_fixed <= c_u[16:0];
         v_fixed <= c_v[16:0];
         frag    <= c_frag;
         s_tex0  <= c_tex0;
         s_clamp <= c_clamp;
         req     <= 1;
         @(posedge clk);
         req <= 0;

         while (!done) @(posedge clk);
         $display("%0d %08x", n, colour);
         n++;
      end
      $fclose(fh);
      stress_grant <= 0;
      @(posedge clk);

      $display("CACHE hits=%0d misses=%0d inval=%0d dropped=%0d",
               dbg_hits, dbg_misses, dbg_inval, dbg_dropped);
      if (dbg_hits == 0) begin
         $display("FAIL  the cache never hit -- correct and useless");
         errors++;
      end
      if (dbg_dropped != 0) begin
         $display("FAIL  %0d requests arrived while a miss was outstanding",
                  dbg_dropped);
         errors++;
      end

      // ============ phase C: a raster walk, cached and uncached ===============
      // 64 x 48 of an affine UV, which is what a textured sprite looks like to
      // the sampler. Two formats: PSMCT32 puts 8 texels in a memory word and
      // PSMT8 puts 32, so the second should hit harder -- and if it does not,
      // the swizzle argument this block rests on is wrong.
      for (int fmt = 0; fmt < 2; fmt++) begin
         s_tex0  <= fmt == 0 ? {{27{1'b0}}, 2'd0, 1'b1, 4'd6, 4'd6, 6'h00, 6'd2, 14'd0}
                             : {{27{1'b0}}, 2'd0, 1'b1, 4'd6, 4'd6, 6'h13, 6'd2, 14'd0};
         s_clamp <= 0;
         frag    <= 32'h50C06040;
         @(posedge clk);

         flush <= 1; @(posedge clk); flush <= 0; @(posedge clk);
         wh = dbg_hits; wm = dbg_misses;

         use_bare <= 0;
         for (wy = 0; wy < WALK_H; wy++)
           for (wx = 0; wx < WALK_W; wx++) begin
              @(posedge clk);
              u_fixed <= wx << 4;
              v_fixed <= wy << 4;
              req     <= 1;
              @(posedge clk);
              req <= 0;
              while (!done) @(posedge clk);
              walk[wy*WALK_W + wx] = colour;
           end

         $display("WALK fmt=%0d hits=%0d misses=%0d rate=%0d%%",
                  fmt, dbg_hits - wh, dbg_misses - wm,
                  (100 * (dbg_hits - wh)) / ((dbg_hits - wh) + (dbg_misses - wm)));
         // The floor is not a preference, it is arithmetic: this walk touches
         // 384 distinct memory words in PSMCT32 and 96 in PSMT8, so those are
         // the compulsory misses and no cache can do better. Checking the
         // *number* rather than a rate is what makes an index regression a
         // failure instead of a quieter printout -- the plain low-bit index
         // this block started with gives 768 here and still hits more often
         // than it misses.
         if (dbg_misses - wm != (fmt == 0 ? 384 : 96)) begin
            $display("FAIL  fmt=%0d took %0d misses, the compulsory floor is %0d",
                     fmt, dbg_misses - wm, fmt == 0 ? 384 : 96);
            errors++;
         end

         use_bare <= 1;
         @(posedge clk);
         for (wy = 0; wy < WALK_H; wy++)
           for (wx = 0; wx < WALK_W; wx++) begin
              @(posedge clk);
              u_fixed <= wx << 4;
              v_fixed <= wy << 4;
              b_req   <= 1;
              @(posedge clk);
              b_req <= 0;
              while (!b_done) @(posedge clk);
              if (b_colour !== walk[wy*WALK_W + wx]) begin
                 if (errors < 8)
                   $display("FAIL  fmt=%0d (%0d,%0d): cached %08x uncached %08x",
                            fmt, wx, wy, walk[wy*WALK_W + wx], b_colour);
                 errors++;
              end
           end
         use_bare <= 0;
         @(posedge clk);
      end

      // ================= phase B: coherence ===================================
      tb_drive <= 1;
      @(posedge clk);

      // Two addresses that land in the same set as A under the folded index,
      // so that between them they evict it: with two ways, one conflict does
      // not. Folding means a conflicting address is not simply A with a high
      // bit flipped, so they are searched for rather than constructed -- and
      // the search failing is itself a failure, because the eviction case would
      // then silently not be tested.
      A = 17'h0_1234;
      B = 0; C = 0;
      for (int k = 1; k < 131072 && (B == 0 || C == 0); k++) begin
         logic [16:0] cand;
         cand = k;
         if (fold_set(cand) == fold_set(A) && cand != A) begin
            if (B == 0) B = cand; else if (C == 0) C = cand;
         end
      end
      if (B == 0 || C == 0) begin
         $display("FAIL  could not find two addresses conflicting with A"); errors++;
      end

      // 1. cold read fills; 2. the same read hits and agrees
      h0 = dbg_hits; m0 = dbg_misses;
      cache_read(A, d);
      expect_eq(d, mem[A], "cold read");
      expect_int(dbg_misses - m0, 1, "cold read should miss");
      expect_int(dbg_hits - h0,   0, "cold read should not hit");

      h0 = dbg_hits; m0 = dbg_misses;
      cache_read(A, d);
      expect_eq(d, mem[A], "warm read");
      expect_int(dbg_hits - h0,   1, "warm read should hit");
      expect_int(dbg_misses - m0, 0, "warm read should not miss");

      // 3. a write to a held line must be seen by the next read
      e = 256'h0;
      e[31:0] = 32'hdead_beef;
      mem_write(A, e);
      h0 = dbg_hits;
      cache_read(A, d);
      expect_eq(d, e, "read after write to a held line");
      expect_int(dbg_hits - h0, 0, "a written line must not hit");

      // 4. a snoop of a DIFFERENT tag at the same index must not invalidate.
      //    A cache that invalidates on the index alone is coherent and wasteful.
      cache_read(A, d);                       // make sure A is held
      h0 = dbg_hits;
      snoop_addr <= B; snoop_en <= 1;
      @(posedge clk);
      snoop_en <= 0;
      @(posedge clk);
      cache_read(A, d);
      expect_eq(d, mem[A], "after a foreign-tag snoop");
      expect_int(dbg_hits - h0, 1, "a foreign-tag snoop must not invalidate");

      // 5. conflict. One conflicting line must NOT evict A -- that is what the
      //    second way is for, and a test that only checks eviction would pass
      //    on a direct-mapped cache. Two of them must.
      cache_read(A, d);
      cache_read(B, d);
      expect_eq(d, mem[B], "first conflicting line");
      h0 = dbg_hits;
      cache_read(A, d);
      expect_eq(d, mem[A], "A after one conflict");
      expect_int(dbg_hits - h0, 1, "one conflict must not evict A from a 2-way set");

      cache_read(C, d);
      expect_eq(d, mem[C], "second conflicting line");
      h0 = dbg_hits;
      cache_read(A, d);
      expect_eq(d, mem[A], "the evicted line, refetched");
      expect_int(dbg_hits - h0, 0, "two conflicts must evict A");

      // 6. flush clears everything
      cache_read(A, d);
      flush <= 1;
      @(posedge clk);
      flush <= 0;
      @(posedge clk);
      h0 = dbg_hits;
      cache_read(A, d);
      expect_eq(d, mem[A], "after flush");
      expect_int(dbg_hits - h0, 0, "flush must invalidate");

      // 7. a write in the same cycle as the lookup of that line. The valid bit
      //    is cleared on this edge, so a hit taken from it hands back the word
      //    the write has just replaced.
      cache_read(A, d);                       // A held, holding the old word
      e[31:0] = 32'hfeed_face;
      fork
         begin
            tb_rd_addr <= A; tb_rd_en <= 1;
            @(posedge clk);
            tb_rd_en <= 0;
         end
         begin
            w_addr <= A; w_data <= e; w_en <= 1;
            snoop_addr <= A; snoop_en <= 1;
            @(posedge clk);
            w_en <= 0; snoop_en <= 0;
         end
      join
      while (!k_c_rd_valid) @(posedge clk);
      expect_eq(k_c_rd_data, e, "lookup colliding with a write");
      @(posedge clk);

      // 8. a write to the line a miss is fetching. The word in flight was read
      //    before the write, so it may be the old one -- but it must not be
      //    kept, or the stale line outlives the write.
      flush <= 1; @(posedge clk); flush <= 0; @(posedge clk);
      e[31:0] = 32'h0bad_c0de;
      tb_rd_addr <= A; tb_rd_en <= 1;
      @(posedge clk);
      tb_rd_en <= 0;                          // the miss is now outstanding
      @(posedge clk);
      w_addr <= A; w_data <= e; w_en <= 1;
      snoop_addr <= A; snoop_en <= 1;
      @(posedge clk);
      w_en <= 0; snoop_en <= 0;
      while (!k_c_rd_valid) @(posedge clk);
      @(posedge clk);
      h0 = dbg_hits;
      cache_read(A, d);
      expect_eq(d, e, "the poisoned fill must not be kept");
      expect_int(dbg_hits - h0, 0, "a poisoned fill must leave the line invalid");

      // 9. two addresses that differ only in the top bit of the tag. Every
      //    other case in this file lives in the bottom of local memory, where
      //    that bit is zero, so a tag comparison that dropped it would alias
      //    them and no test above would notice.
      flush <= 1; @(posedge clk); flush <= 0; @(posedge clk);
      D = A | 17'h1_0000;
      if (mem[D] === mem[A]) begin
         $display("FAIL  the aliasing pair holds identical data"); errors++;
      end
      cache_read(A, d);
      expect_eq(d, mem[A], "low half of the tag space");
      h0 = dbg_hits;
      cache_read(D, d);
      expect_eq(d, mem[D], "high half of the tag space");
      expect_int(dbg_hits - h0, 0, "the two tag halves must not alias");

      // 10. a request while a miss is outstanding. gs_texsample never does it,
      //     which is exactly why it has to be pinned: the block keeps one miss
      //     and not a queue, and a hit served from under an outstanding miss
      //     would put two answers on a port that carries one.
      flush <= 1; @(posedge clk); flush <= 0; @(posedge clk);
      cache_read(A, d);                       // A is held, so it would hit
      h0 = dbg_dropped;
      wi = 0;
      tb_rd_addr <= B; tb_rd_en <= 1;         // B is not held: this misses
      @(posedge clk);
      tb_rd_addr <= A; tb_rd_en <= 1;         // and this arrives under it
      @(posedge clk);
      tb_rd_en <= 0;
      if (k_c_ready !== 0) begin
         $display("FAIL  c_ready was high during a miss"); errors++;
      end
      while (!k_c_rd_valid) begin @(posedge clk); wi++; end
      expect_eq(k_c_rd_data, mem[B], "the answer under a miss must be the miss's");
      expect_int(dbg_dropped - h0, 1, "the request under a miss must be counted");
      @(posedge clk);
      // and nothing else may come back
      for (int t = 0; t < 8; t++) begin
         if (k_c_rd_valid) begin
            $display("FAIL  a second answer arrived for one accepted request");
            errors++;
         end
         @(posedge clk);
      end

      if (errors == 0) $display("COHERENT");
      $display("DONE %0d cases", n);
      $finish;
   end

   initial begin
      #400_000_000;
      $display("FAIL  STALLED -- a fetch never completed");
      $finish;
   end

endmodule
