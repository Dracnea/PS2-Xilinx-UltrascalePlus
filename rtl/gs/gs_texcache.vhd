-- gs_texcache.vhd -- a texel cache, so the texture unit stops being a fourth
-- customer on a read port that already has three.
--
-- `gs_lmem` has one read port. The rasteriser reads through it for the
-- read-modify-write that FBMSK, blending and the depth test need; PCRTC reads
-- through it to put a picture out; the CLUT loader reads through it to fill a
-- palette. `gs_texsample` made it four, and it is not a fourth like the others:
-- it wants a texel for *every pixel drawn*, and bilinear wants four.
--
-- The real GS does not solve this by sharing harder. It gives texture its own
-- 512-bit path with its own page buffer, which is why a textured pixel there
-- costs roughly twice an untextured one rather than four times. A second port
-- on 4 MB of UltraRAM is the faithful answer and it is the one this project
-- cannot afford: URAM is the scarce resource here, 224 of the C1100's 640 are
-- spent before the GS's local memory exists at all, and 70 % of an FK33's 320
-- (docs/cards.md). So this takes the other half of what the real GS does -- the
-- page buffer, not the port -- and puts it in LUTs, where there is room.
--
-- ## Why so few lines are enough
--
-- The argument is the swizzle. A 256-bit word of local memory is not eight
-- unrelated pixels; the GS's page/block/column layout puts a 2D neighbourhood
-- in it -- 8 texels of PSMCT32, 32 of PSMT8, 64 of PSMT4. A rasteriser walks a
-- primitive in raster order and its UV walk is affine, so consecutive samples
-- land in the same word and then in its neighbour. The locality is not a hope
-- about typical content; it is a property of the address function, which
-- `gs_texaddr` already implements and `tools/gs/xcheck_swizzle.py` has checked
-- exhaustively.
--
-- That is also why the line is exactly one 256-bit memory word and not larger.
-- A longer line would fetch a second word that the swizzle says is a *different*
-- block, which is a different part of the texture -- prefetching it is a guess,
-- and a miss costs the one thing being economised.
--
-- ## The shape was measured, not chosen
--
-- The first version of this block was direct-mapped with the low address bits
-- as the index, which is the obvious thing to write. On a 64 x 48 raster walk of
-- a PSMCT32 texture it hit 75 % -- and it hit exactly 75 % at 16 lines, at 32,
-- at 64 and at 128. A number that does not move with capacity is not a capacity
-- problem, and the reuse histogram said what it was: two distances, 1 and **61**.
--
-- 61 is the tell. The GS's column order for PSMCT32 interleaves two pixel rows
-- inside one column, so a 256-bit word holds a 4 x 2 patch -- four texels of row
-- v and four of row v+1. A raster walk therefore touches every word twice, once
-- per row, about a row apart, and the second visit is the one that has to hit.
-- It was missing because the words in between mapped onto it: `tools/gs`'s
-- address functions put those words at multiples of a block, so the low bits of
-- their addresses -- the index -- are far from uniform even though the addresses
-- themselves are spread out.
--
-- Two changes fix it, and both were chosen by simulating the real address
-- streams (all four addressing formats x four TBWs x four bases x seven walk
-- shapes, 336 configurations) against the compulsory-miss floor:
--
--   * **Fold the index.** `index = addr[S-1:0] xor addr[2S-1:S]`. The dropped
--     bits are still in the tag, so a (tag, index) pair identifies a line
--     exactly as before -- `addr[S-1:0]` is recoverable from the two. It costs S
--     XOR gates and takes the mean excess over the floor from 5.4 % of accesses
--     to 2.8 %.
--   * **Two ways.** With the fold, that reaches 0.5 % mean and 7.5 % worst.
--     Doubling again to 256 lines buys 0.07 %, so this is the knee.
--
-- Replacement is **round-robin, not LRU**, because across those 336
-- configurations the two are not merely close, they are *identical* -- for two
-- ways they differ only in whether a hit reorders the pair, and these streams
-- never make that matter. A victim pointer is one bit per set; LRU would be the
-- same bit plus an update on every hit, for nothing measurable.
--
-- ## The invariant, which is the whole specification
--
-- **A cache must be invisible.** With a quiescent memory, every colour this
-- design produces has to be the colour it would have produced with
-- `gs_texsample` wired straight to `gs_lmem`. That is testable directly, and
-- twice over: `sim/gs/run_texcache_diff.sh` runs the texel-fetch vectors through
-- the cache and diffs against the *same* ref.txt the uncached block is checked
-- against, and then walks a textured quad through two copies of gs_texsample --
-- one cached, one not -- and compares them pixel for pixel.
--
-- A correctness test alone would be satisfied by a cache that never hits, so the
-- block counts hits, misses and invalidations and the test asserts that a raster
-- walk hits more often than it misses. A cache that is correct and useless is a
-- failure with a green light.
--
-- ## Coherence, which is where a texture cache actually goes wrong
--
-- Local memory is one address space. A framebuffer the rasteriser is writing
-- and a texture this reads are the same 4 MB, and rendering to a texture is an
-- ordinary PlayStation 2 idiom -- it is how reflections, shadow maps and most
-- full-screen effects are done. A cache that does not watch the write port will
-- serve the texture as it was before the render, and the failure looks like a
-- one-frame-late reflection rather than like a cache bug.
--
-- So every write to local memory is snooped. A write address selects one set,
-- and only that set's tags have to be compared. Three cases, separate on purpose:
--
--   * a write to a line that is held -- invalidate it;
--   * a write to the line a miss is currently fetching -- do not store the
--     answer. `gs_lmem` reads the value the array held *before* the write, so
--     the data coming back is already stale, and caching it would keep a stale
--     line. It is still handed to the client, because the uncached path would
--     have returned exactly the same word;
--   * a write in the same cycle as a lookup of that line -- forced miss. The
--     tag comparison and the invalidation happen on the same clock edge, so a
--     hit decided combinationally from the old valid bit would hand back a word
--     the write has just replaced. This one is invisible in any test whose
--     writes and reads do not collide, which is why the testbench aims them at
--     each other on purpose.
--
-- The conservative choice in the third case means the cached path can return a
-- *newer* word than the uncached path would have -- `gs_lmem` would have given
-- the pre-write value. That direction is safe and the other is not: the
-- rasteriser and the texture unit have no defined order between them, so no
-- client can depend on seeing the older word, while every client depends on not
-- seeing a stale one.
--
-- `flush` clears every valid bit in one cycle, which is what the GS's TEXFLUSH
-- register means and what a CLUT reload or a TEX0 change to a new base wants.
-- It is a port rather than something inferred here: this block cannot see a
-- register write, and guessing when a texture has changed is how a cache becomes
-- subtly wrong.
--
-- ## One request at a time, checked rather than assumed
--
-- `gs_texsample` pulses `rd_en` once and then waits for `rd_valid`, so it never
-- has two fetches outstanding. This block relies on that -- there is one miss
-- register, not a queue. Rather than write the assumption in a comment and hope,
-- `c_ready` says when a request would be accepted and `dbg_dropped` counts the
-- requests that arrived when it was low. A test that leaves that counter at zero
-- has shown the assumption held for the traffic it ran.
--
-- ## Cost
--
-- The default is 64 sets x 2 ways of 256 bits: four kilobytes, as distributed
-- RAM, so no block RAM and no UltraRAM -- the resource this block exists to
-- protect is the one it must not spend. Tags, valid bits and victim pointers are
-- flip-flops, because the snoop compares a set while the client reads another
-- and `flush` clears all of the valid bits at once; none of that is something a
-- RAM does well.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity gs_texcache is
   generic
   (
      ADDR_BITS  : integer := 17;   -- 2^17 words of 256 bits = the GS's 4 MB
      DATA_WIDTH : integer := 256;
      SETS_LOG2  : integer := 6;    -- 64 sets
      WAYS_LOG2  : integer := 1     -- 2 ways: 128 lines, 4 KB
   );
   port
   (
      clk        : in  std_logic;
      reset      : in  std_logic;

      -- ---- client side: exactly the shape gs_lmem presents, so gs_texsample
      -- does not know whether it is talking to a cache or to the memory.
      c_rd_en    : in  std_logic;
      c_rd_addr  : in  std_logic_vector(ADDR_BITS-1 downto 0);
      c_rd_data  : out std_logic_vector(DATA_WIDTH-1 downto 0) := (others => '0');
      c_rd_valid : out std_logic := '0';
      c_ready    : out std_logic;   -- low while a miss is being served

      -- ---- memory side, through whatever arbiter is in front of gs_lmem
      m_rd_en    : out std_logic;
      m_rd_addr  : out std_logic_vector(ADDR_BITS-1 downto 0);
      m_rd_data  : in  std_logic_vector(DATA_WIDTH-1 downto 0);
      m_rd_valid : in  std_logic;
      m_ready    : in  std_logic := '1';   -- the arbiter's grant for this cycle

      -- ---- coherence
      snoop_en   : in  std_logic := '0';
      snoop_addr : in  std_logic_vector(ADDR_BITS-1 downto 0) := (others => '0');
      flush      : in  std_logic := '0';

      -- ---- observation. A cache that is never measured is a cache that is
      -- assumed to work.
      dbg_hits    : out unsigned(31 downto 0) := (others => '0');
      dbg_misses  : out unsigned(31 downto 0) := (others => '0');
      dbg_inval   : out unsigned(31 downto 0) := (others => '0');
      dbg_dropped : out unsigned(31 downto 0) := (others => '0')
   );
end entity;

architecture rtl of gs_texcache is

   constant NSETS : integer := 2**SETS_LOG2;
   constant NWAYS : integer := 2**WAYS_LOG2;
   constant TAG_W : integer := ADDR_BITS - SETS_LOG2;

   subtype t_set  is unsigned(SETS_LOG2-1 downto 0);
   subtype t_way  is unsigned(WAYS_LOG2-1 downto 0);
   subtype t_tag  is std_logic_vector(TAG_W-1 downto 0);

   -- One flat array of NSETS*NWAYS lines, addressed by set & way. It has to be
   -- flat: gs_lmem's header records that Vivado will not infer a memory from an
   -- array of arrays and builds flip-flops instead.
   type t_data_arr is array (0 to NSETS*NWAYS-1)
      of std_logic_vector(DATA_WIDTH-1 downto 0);
   signal data_arr : t_data_arr := (others => (others => '0'));
   attribute ram_style : string;
   attribute ram_style of data_arr : signal is "distributed";

   type t_tag_arr is array (0 to NSETS*NWAYS-1) of t_tag;
   signal tag_arr : t_tag_arr := (others => (others => '0'));
   signal valid   : std_logic_vector(NSETS*NWAYS-1 downto 0) := (others => '0');

   -- The next way to evict in each set. Round-robin, and the header says why it
   -- is not LRU.
   type t_victim_arr is array (0 to NSETS-1) of t_way;
   signal victim : t_victim_arr := (others => (others => '0'));

   -- **The folded index.** The bits it drops are still in the tag, so a
   -- (tag, set) pair names a line exactly: addr[S-1:0] = set xor tag[S-1:0].
   -- Fold with the bits immediately above rather than with the top of the
   -- address, because those are the ones that vary inside a texture.
   function set_of (a : std_logic_vector) return t_set is
      variable lo, mid : unsigned(SETS_LOG2-1 downto 0);
   begin
      lo  := unsigned(a(SETS_LOG2-1 downto 0));
      mid := resize(unsigned(a(ADDR_BITS-1 downto SETS_LOG2)), SETS_LOG2);
      return lo xor mid;
   end function;

   function tag_of (a : std_logic_vector) return t_tag is
   begin
      return a(ADDR_BITS-1 downto SETS_LOG2);
   end function;

   function slot_of (s : t_set; w : t_way) return integer is
   begin
      return to_integer(s) * NWAYS + to_integer(w);
   end function;

   -- lookup, combinational on the incoming request
   signal l_set     : t_set;
   signal l_tag     : t_tag;
   signal l_way     : t_way;
   signal l_hit     : std_logic;
   signal l_collide : std_logic;

   -- snoop, combinational on the write address
   signal s_set  : t_set;
   signal s_tag  : t_tag;
   signal s_way  : t_way;
   signal s_hit  : std_logic;

   -- the one outstanding miss
   signal miss_busy   : std_logic := '0';
   signal miss_issued : std_logic := '0';   -- the memory has taken the request
   signal miss_addr   : std_logic_vector(ADDR_BITS-1 downto 0) := (others => '0');
   signal miss_way    : t_way := (others => '0');
   signal miss_stale  : std_logic := '0';   -- written under us; do not store it

begin

   -- ---- lookup -------------------------------------------------------------
   l_set <= set_of(c_rd_addr);
   l_tag <= tag_of(c_rd_addr);

   look : process (all)
      variable hit : std_logic;
      variable wy  : t_way;
   begin
      hit := '0';
      wy  := (others => '0');
      for w in 0 to NWAYS-1 loop
         if valid(slot_of(l_set, to_unsigned(w, WAYS_LOG2))) = '1'
            and tag_arr(slot_of(l_set, to_unsigned(w, WAYS_LOG2))) = l_tag then
            hit := '1';
            wy  := to_unsigned(w, WAYS_LOG2);
         end if;
      end loop;
      l_way <= wy;
      l_hit <= hit and c_rd_en and (not miss_busy) and (not l_collide);
   end process;

   -- ---- snoop --------------------------------------------------------------
   s_set <= set_of(snoop_addr);
   s_tag <= tag_of(snoop_addr);

   snp : process (all)
      variable hit : std_logic;
      variable wy  : t_way;
   begin
      hit := '0';
      wy  := (others => '0');
      for w in 0 to NWAYS-1 loop
         if valid(slot_of(s_set, to_unsigned(w, WAYS_LOG2))) = '1'
            and tag_arr(slot_of(s_set, to_unsigned(w, WAYS_LOG2))) = s_tag then
            hit := '1';
            wy  := to_unsigned(w, WAYS_LOG2);
         end if;
      end loop;
      s_way <= wy;
      s_hit <= hit and snoop_en;
   end process;

   -- A write landing on the very word being looked up, in the very cycle it is
   -- looked up. The valid bit still reads '1' -- it is cleared on this edge --
   -- so the hit has to be suppressed here or the client gets the pre-write word
   -- from a line that is about to be thrown away.
   l_collide <= '1' when snoop_en = '1' and s_set = l_set and s_tag = l_tag
                else '0';

   c_ready <= not miss_busy;

   -- ---- memory side --------------------------------------------------------
   -- The request is held until the arbiter grants it, and dropped the cycle it
   -- is taken: gs_lmem has no ready of its own, so "taken" is m_ready being high
   -- on a cycle m_rd_en is.
   m_rd_en   <= miss_busy and not miss_issued;
   m_rd_addr <= miss_addr;

   process (clk)
      variable v_set : t_set;
   begin
      if rising_edge(clk) then
         c_rd_valid <= '0';

         if reset = '1' then
            valid       <= (others => '0');
            victim      <= (others => (others => '0'));
            miss_busy   <= '0';
            miss_issued <= '0';
            miss_stale  <= '0';
            dbg_hits    <= (others => '0');
            dbg_misses  <= (others => '0');
            dbg_inval   <= (others => '0');
            dbg_dropped <= (others => '0');
         else

            -- ---- coherence, before anything that depends on a valid bit -----
            if flush = '1' then
               valid <= (others => '0');
            elsif s_hit = '1' then
               valid(slot_of(s_set, s_way)) <= '0';
               dbg_inval <= dbg_inval + 1;
            end if;

            -- A write to the line a miss is fetching poisons that fill. The
            -- word already in flight was read before the write reached the
            -- array, so it is what the uncached path would have returned and it
            -- is still given to the client -- it just must not be kept.
            if miss_busy = '1' and snoop_en = '1' and snoop_addr = miss_addr then
               miss_stale <= '1';
            end if;

            -- ---- the client's request --------------------------------------
            if c_rd_en = '1' then
               if miss_busy = '1' then
                  -- gs_texsample cannot do this. Counted rather than assumed.
                  dbg_dropped <= dbg_dropped + 1;
               elsif l_hit = '1' then
                  c_rd_data  <= data_arr(slot_of(l_set, l_way));
                  c_rd_valid <= '1';
                  dbg_hits   <= dbg_hits + 1;
               else
                  miss_busy   <= '1';
                  miss_issued <= '0';
                  miss_addr   <= c_rd_addr;
                  -- The victim is picked now rather than on the fill, so the
                  -- pointer advances once per miss whatever else happens to the
                  -- set in between.
                  miss_way    <= victim(to_integer(l_set));
                  victim(to_integer(l_set)) <= victim(to_integer(l_set)) + 1;
                  -- A line being fetched because a write just invalidated it is
                  -- not stale; the fetch happens after the write.
                  miss_stale  <= '0';
                  dbg_misses  <= dbg_misses + 1;
               end if;
            end if;

            -- ---- the fill ---------------------------------------------------
            if miss_busy = '1' and miss_issued = '0' and m_ready = '1' then
               miss_issued <= '1';
            end if;

            if miss_busy = '1' and miss_issued = '1' and m_rd_valid = '1' then
               c_rd_data   <= m_rd_data;
               c_rd_valid  <= '1';
               miss_busy   <= '0';
               miss_issued <= '0';

               v_set := set_of(miss_addr);
               if miss_stale = '0'
                  and not (snoop_en = '1' and snoop_addr = miss_addr)
                  and not (flush = '1') then
                  data_arr(slot_of(v_set, miss_way)) <= m_rd_data;
                  tag_arr (slot_of(v_set, miss_way)) <= tag_of(miss_addr);
                  -- The snoop above may have cleared this very bit in this very
                  -- cycle for a *different* tag that mapped here. Setting it
                  -- after that is correct: the line now holds what was fetched.
                  valid   (slot_of(v_set, miss_way)) <= '1';
               end if;
            end if;

         end if;
      end if;
   end process;

end architecture;
