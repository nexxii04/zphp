// Native implementation of pmmp/ext-chunkutils2.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c2_alloc = std.heap.c_allocator;

const Value = @import("../runtime/value.zig").Value;
const PhpArray = @import("../runtime/value.zig").PhpArray;
const PhpObject = @import("../runtime/value.zig").PhpObject;
const vm_mod = @import("../runtime/vm.zig");
const VM = vm_mod.VM;
const NativeContext = vm_mod.NativeContext;
const ClassDef = vm_mod.ClassDef;
const NativeResult = @import("../runtime/native_result.zig").NativeResult;

const RuntimeError = error{ RuntimeError, OutOfMemory };

const COORD_BIT_SIZE: u3 = 4;
const COORD_MASK: u8 = 0x0f;
const ARRAY_DIM: u16 = 1 << COORD_BIT_SIZE; // 16
const ARRAY_CAPACITY: u16 = ARRAY_DIM * ARRAY_DIM * ARRAY_DIM; // 4096

const VALID_BPB = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 8, 16 };

const Block = u32;

fn bpbIsValid(bpb: u8) bool {
    for (VALID_BPB) |v| {
        if (v == bpb) return true;
    }
    return false;
}

fn optimalBpb(capacity: u32) ?u8 {
    for (VALID_BPB) |bpb| {
        if (capacity <= maxPaletteSize(bpb)) return bpb;
    }
    return null;
}

// MAX_PALETTE_SIZE = min(1 << bpb, ARRAY_CAPACITY) for bpb > 0; 1 for bpb == 0.
fn maxPaletteSize(bpb: u8) u32 {
    if (bpb == 0) return 1;
    const offset_space: u32 = @as(u32, 1) << @as(u5, @intCast(bpb));
    return if (offset_space < ARRAY_CAPACITY) offset_space else ARRAY_CAPACITY;
}

fn blocksPerWord(bpb: u8) u32 {
    std.debug.assert(bpb > 0);
    return 32 / @as(u32, @intCast(bpb));
}

fn wordCount(bpb: u8) u32 {
    std.debug.assert(bpb > 0);
    return ARRAY_CAPACITY / blocksPerWord(bpb) + (if (ARRAY_CAPACITY % blocksPerWord(bpb) != 0) @as(u32, 1) else @as(u32, 0));
}

fn payloadSize(bpb: u8) u32 {
    if (bpb == 0) return 0;
    return wordCount(bpb) * @sizeOf(u32);
}

const Palette = struct {
    entries: []Block,
    capacity: u32,
    block_to_offset: std.AutoHashMapUnmanaged(Block, u32) = .{},
    lowest_unscanned: u32 = 0,

    fn init(allocator: Allocator, block: Block, capacity: u32) !Palette {
        const entries = try allocator.alloc(Block, capacity);
        entries[0] = block;
        return .{ .entries = entries[0..1], .capacity = capacity };
    }

    fn deinit(self: *Palette, allocator: Allocator) void {
        allocator.free(self.entries.ptr[0..self.capacity]);
    }

    fn get(self: *const Palette, offset: u32) Block {
        return self.entries[offset];
    }

    fn set(self: *Palette, offset: u32, val: Block) void {
        self.entries[offset] = val;
    }

    fn size(self: *const Palette) u32 {
        return @intCast(self.entries.len);
    }

    // Returns the offset of val in the palette, or null if the palette is full.
    fn addOrLookup(self: *Palette, allocator: Allocator, max_size: u32, val: Block) !?u32 {
        if (self.block_to_offset.get(val)) |offset| return offset;

        while (self.lowest_unscanned < self.entries.len) {
            const offset = self.lowest_unscanned;
            self.lowest_unscanned += 1;
            try self.block_to_offset.put(allocator, self.entries[offset], offset);
            if (self.entries[offset] == val) return offset;
        }

        if (self.entries.len >= max_size) return null;

        const offset: u32 = @intCast(self.entries.len);
        std.debug.assert(self.entries.len < self.capacity);
        self.entries = self.entries.ptr[0 .. self.entries.len + 1];
        self.entries[offset] = val;
        try self.block_to_offset.put(allocator, val, offset);
        return offset;
    }
};

const PalettedBlockArray = struct {
    bits_per_block: u8,
    // Precomputed from bits_per_block to avoid a runtime division (32 / bpb)
    // on every get/set. Assigned only in init and clone; the resize path in
    // collectGarbage goes through init, so these stay in sync with
    // bits_per_block for the struct's entire lifetime.
    blocks_per_word: u32,
    block_mask: u32,
    max_palette_size: u32,
    // Division-free word indexing: for power-of-2 blocks_per_word (bpb ∈
    // {1,2,4,8,16}), find() uses idx >> word_shift / idx & word_mask instead of
    // idx / blocks_per_word (a 20-40 cycle divu). word_shift=0 is the sentinel
    // for non-power-of-2 blocks_per_word (bpb ∈ {3,5,6}) — find() falls back to
    // the divu path. These 5 power-of-2 cases are the most common in
    // PocketMine (bpb=4 and bpb=8 cover most chunks), so the branch is highly
    // predictable.
    word_shift: u4 = 0,
    word_mask: u32 = 0,
    words: []u32,
    palette: Palette,
    may_need_gc: bool = false,

    fn init(allocator: Allocator, bpb: u8, fill: Block) !*PalettedBlockArray {
        const self = try allocator.create(PalettedBlockArray);
        const words: []u32 = if (bpb == 0)
            try allocator.alloc(u32, 0)
        else
            try allocator.alloc(u32, wordCount(bpb));
        @memset(words, 0);
        const max_ps = maxPaletteSize(bpb);
        const pal_entries = try allocator.alloc(Block, max_ps);
        pal_entries[0] = fill;
        const bpw: u32 = if (bpb == 0) 0 else blocksPerWord(bpb);

        // precompute power-of-2 word indexing fields. @ctz gives the exact
        // log2 for powers of 2 (e.g. @ctz(8)=3, @ctz(16)=4). word_shift=0 is
        // also the fallback sentinel for non-power-of-2 blocks_per_word
        // (bpb ∈ {3,5,6}), but blocks_per_word==1 (bpb=32, impossible since
        // max bpb=16) would also give 0 — so we guard with is_pow2.
        const is_pow2 = bpb != 0 and bpw > 0 and (bpw & (bpw - 1)) == 0;
        const word_shift: u4 = if (is_pow2) @intCast(@ctz(bpw)) else 0;
        const word_mask: u32 = if (is_pow2) bpw - 1 else 0;

        self.* = .{
            .bits_per_block = bpb,
            .blocks_per_word = bpw,
            .block_mask = if (bpb == 0) 0 else (@as(u32, 1) << @as(u5, @intCast(bpb))) - 1,
            .max_palette_size = max_ps,
            .word_shift = word_shift,
            .word_mask = word_mask,
            .words = words,
            .palette = .{ .entries = pal_entries[0..1], .capacity = max_ps },
        };
        return self;
    }

    fn deinit(self: *PalettedBlockArray, allocator: Allocator) void {
        allocator.free(self.words);
        allocator.free(self.palette.entries.ptr[0..self.palette.capacity]);
        self.palette.block_to_offset.deinit(allocator);
        allocator.destroy(self);
    }

    fn clone(self: *const PalettedBlockArray, allocator: Allocator) !*PalettedBlockArray {
        const new = try allocator.create(PalettedBlockArray);
        const words: []u32 = if (self.bits_per_block == 0)
            try allocator.alloc(u32, 0)
        else
            try allocator.alloc(u32, self.words.len);
        @memcpy(words, self.words);
        const pal_entries = try allocator.alloc(Block, self.palette.capacity);
        @memcpy(pal_entries[0..self.palette.entries.len], self.palette.entries);
        new.* = .{
            .bits_per_block = self.bits_per_block,
            .blocks_per_word = self.blocks_per_word,
            .block_mask = self.block_mask,
            .max_palette_size = self.max_palette_size,
            .word_shift = self.word_shift,
            .word_mask = self.word_mask,
            .words = words,
            .palette = .{
                .entries = pal_entries[0..self.palette.entries.len],
                .capacity = self.palette.capacity,
            },
            .may_need_gc = self.may_need_gc,
        };
        return new;
    }

    inline fn getArrayOffset(x: u8, y: u8, z: u8) u16 {
        return (@as(u16, x & COORD_MASK) << 8) |
            (@as(u16, z & COORD_MASK) << 4) |
            @as(u16, y & COORD_MASK);
    }

    const WordLoc = struct { word_idx: u16, shift: u8 };

    inline fn find(self: *const PalettedBlockArray, x: u8, y: u8, z: u8) WordLoc {
        std.debug.assert(self.bits_per_block > 0); // callers guard bpb == 0
        const idx = getArrayOffset(x, y, z);
        // Division-free fast path for power-of-2 blocks_per_word (bpb ∈
        // {1,2,4,8,16}). Replaces a 20-40 cycle divu with a shift + mask.
        // word_shift is 0 only for non-power-of-2 blocks_per_word (bpb ∈
        // {3,5,6}), which falls back to the divu path.
        if (self.word_shift != 0) {
            return .{
                .word_idx = idx >> self.word_shift,
                .shift = @intCast((idx & self.word_mask) * @as(u32, self.bits_per_block)),
            };
        } else {
            return .{
                .word_idx = @intCast(idx / self.blocks_per_word),
                .shift = @intCast((idx % self.blocks_per_word) * @as(u32, self.bits_per_block)),
            };
        }
    }

    fn getPaletteOffset(self: *const PalettedBlockArray, x: u8, y: u8, z: u8) u32 {
        const loc = self.find(x, y, z);
        return (self.words[loc.word_idx] >> @as(u5, @intCast(loc.shift))) & self.block_mask;
    }

    fn setPaletteOffset(self: *PalettedBlockArray, x: u8, y: u8, z: u8, offset: u32) void {
        const loc = self.find(x, y, z);
        const mask = self.block_mask;
        self.words[loc.word_idx] = (self.words[loc.word_idx] & ~(mask << @as(u5, @intCast(loc.shift)))) |
            (offset << @as(u5, @intCast(loc.shift)));
    }

    fn get(self: *const PalettedBlockArray, x: u8, y: u8, z: u8) Block {
        if (self.bits_per_block == 0) return self.palette.get(0);
        const offset = self.getPaletteOffset(x, y, z);
        return self.palette.get(offset);
    }

    // Returns true on success, false if the palette is full.
    fn set(self: *PalettedBlockArray, allocator: Allocator, x: u8, y: u8, z: u8, val: Block) !bool {
        if (self.bits_per_block == 0) {
            return val == self.palette.get(0);
        }

        const offset = (self.palette.addOrLookup(allocator, self.max_palette_size, val) catch return false) orelse {
            if (self.max_palette_size < ARRAY_CAPACITY or self.may_need_gc) {
                return false;
            }
            // palette is at max capacity (ARRAY_CAPACITY) and GC already ran:
            // overwrite the existing palette entry at this coordinate. this
            // handles the edge case where the fill value wastes a slot that
            // a new unique block needs.
            const existing = self.getPaletteOffset(x, y, z);
            self.palette.set(existing, val);
            self.setPaletteOffset(x, y, z, existing);
            return true;
        };

        self.setPaletteOffset(x, y, z, offset);
        self.may_need_gc = true;
        return true;
    }

    fn replaceAll(self: *PalettedBlockArray, from: Block, to: Block) void {
        for (self.palette.entries) |*entry| {
            if (entry.* == from) entry.* = to;
        }
        self.may_need_gc = true;
    }

    fn countUniqueBlocks(self: *const PalettedBlockArray) u32 {
        if (self.bits_per_block == 0) return 1;

        // Track which palette offsets are actually referenced by the word
        // array. Offsets are bounded by max_palette_size <= ARRAY_CAPACITY.
        // This is O(n) with zero comparisons, replacing the old O(n²) linear
        // scan over a found-values buffer.
        var seen: [ARRAY_CAPACITY]bool = .{false} ** ARRAY_CAPACITY;
        var unique: u32 = 0;

        const mask = self.block_mask;
        const bpb: u32 = self.bits_per_block;
        const total_bits: u32 = bpb * self.blocks_per_word;

        for (self.words) |word| {
            var bit: u32 = 0;
            while (bit < total_bits) : (bit += bpb) {
                const offset = (word >> @as(u5, @intCast(bit))) & mask;
                std.debug.assert(offset < ARRAY_CAPACITY);
                if (!seen[offset]) {
                    seen[offset] = true;
                    unique += 1;
                }
            }
        }
        return unique;
    }

    fn collectGarbage(self: *PalettedBlockArray, allocator: Allocator, force: bool, reserved: u32) !void {
        if (!force and !self.may_need_gc) return;

        const unique = self.countUniqueBlocks();
        const need_resize = unique != self.palette.size() or
            optimalBpb(unique + reserved) != self.bits_per_block;

        if (need_resize) {
            const init_block = self.get(0, 0, 0);
            // if no valid bpb can hold unique+reserved blocks (e.g. all 4096
            // cells are unique and reserved > 0), skip the resize but still
            // clear may_need_gc so the caller's retry takes the overwrite path
            const new_bpb = optimalBpb(unique + reserved) orelse {
                self.may_need_gc = false;
                return;
            };
            const new_array = try PalettedBlockArray.init(allocator, new_bpb, init_block);
            var x: u8 = 0;
            while (x < ARRAY_DIM) : (x += 1) {
                var z: u8 = 0;
                while (z < ARRAY_DIM) : (z += 1) {
                    var y: u8 = 0;
                    while (y < ARRAY_DIM) : (y += 1) {
                        const ok = try new_array.set(allocator, x, y, z, self.get(x, y, z));
                        std.debug.assert(ok);
                    }
                }
            }
            // free the old words + palette WITHOUT destroying self (deinit would
            // destroy the struct, leaving self a dangling pointer). then move
            // the new array's fields into self and destroy only the new struct
            // shell (its contents now live in self).
            allocator.free(self.words);
            allocator.free(self.palette.entries.ptr[0..self.palette.capacity]);
            self.palette.block_to_offset.deinit(allocator);
            self.* = new_array.*;
            allocator.destroy(new_array);
        }
        self.may_need_gc = false;
    }
};

fn palettedFromData(
    allocator: Allocator,
    bpb: u8,
    word_array: []const u8,
    palette_entries: []const Block,
) !*PalettedBlockArray {
    if (!bpbIsValid(bpb)) return error.InvalidBitsPerBlock;
    if (palette_entries.len == 0) return error.EmptyPalette;

    if (bpb == 0) {
        if (word_array.len != 0) return error.WrongWordArraySize;
        if (palette_entries.len != 1) return error.WrongPaletteSize;
        const self = try PalettedBlockArray.init(allocator, 0, palette_entries[0]);
        return self;
    }

    const expected = payloadSize(bpb);
    if (word_array.len != expected) return error.WrongWordArraySize;

    const self = try PalettedBlockArray.init(allocator, bpb, palette_entries[0]);
    allocator.free(self.palette.entries.ptr[0..self.palette.capacity]);
    self.palette.block_to_offset.deinit(allocator);

    const max_ps = maxPaletteSize(bpb);
    const pal_buf = try allocator.alloc(Block, max_ps);
    @memcpy(pal_buf[0..palette_entries.len], palette_entries);
    self.palette = .{ .entries = pal_buf[0..palette_entries.len], .capacity = max_ps };

    @memcpy(std.mem.sliceAsBytes(self.words), word_array[0..expected]);

    validateOffsets(self) catch |err| {
        self.deinit(allocator);
        return err;
    };

    self.may_need_gc = true;
    return self;
}

fn validateOffsets(self: *const PalettedBlockArray) !void {
    const max_offset = self.palette.size();
    const full = self.max_palette_size == maxOffsetSpace(self.bits_per_block);
    if (full and self.palette.size() >= self.max_palette_size) return;

    const mask = self.block_mask;
    const bpb: u32 = self.bits_per_block;
    const total_bits: u32 = bpb * self.blocks_per_word;
    for (self.words) |word| {
        var bit: u32 = 0;
        while (bit < total_bits) : (bit += bpb) {
            const offset = (word >> @as(u5, @intCast(bit))) & mask;
            if (offset >= max_offset) return error.InvalidOffset;
        }
    }
}

fn maxOffsetSpace(bpb: u8) u32 {
    if (bpb == 0) return 1;
    return @as(u32, 1) << @as(u5, @intCast(bpb));
}

const BlockArrayContainer = struct {
    array: *PalettedBlockArray,

    fn init(allocator: Allocator, fill: Block, capacity: u32) !BlockArrayContainer {
        const bpb = optimalBpb(capacity) orelse return error.InvalidCapacity;
        const arr = try PalettedBlockArray.init(allocator, bpb, fill);
        return .{ .array = arr };
    }

    fn initFromData(
        allocator: Allocator,
        bpb: u8,
        word_array: []const u8,
        palette_entries: []const Block,
    ) !BlockArrayContainer {
        const arr = try palettedFromData(allocator, bpb, word_array, palette_entries);
        return .{ .array = arr };
    }

    fn deinit(self: *BlockArrayContainer, allocator: Allocator) void {
        self.array.deinit(allocator);
    }

    fn clone(self: *const BlockArrayContainer, allocator: Allocator) !BlockArrayContainer {
        return .{ .array = try self.array.clone(allocator) };
    }

    fn getWordArray(self: *const BlockArrayContainer) []const u8 {
        if (self.array.bits_per_block == 0) return &[_]u8{};
        return std.mem.sliceAsBytes(self.array.words);
    }

    fn getPalette(self: *const BlockArrayContainer) []const Block {
        return self.array.palette.entries;
    }

    fn setPalette(
        self: *BlockArrayContainer,
        allocator: Allocator,
        new_palette: []const Block,
    ) !void {
        _ = allocator;
        if (new_palette.len != self.array.palette.size()) return error.WrongPaletteSize;

        @memcpy(self.array.palette.entries.ptr[0..new_palette.len], new_palette);

        self.array.palette.block_to_offset.clearRetainingCapacity();
        self.array.palette.lowest_unscanned = 0;
    }

    fn getMaxPaletteSize(self: *const BlockArrayContainer) u32 {
        return self.array.max_palette_size;
    }

    fn getBitsPerBlock(self: *const BlockArrayContainer) u8 {
        return self.array.bits_per_block;
    }

    fn get(self: *const BlockArrayContainer, x: u8, y: u8, z: u8) Block {
        return self.array.get(x, y, z);
    }

    fn set(self: *BlockArrayContainer, allocator: Allocator, x: u8, y: u8, z: u8, val: Block) !void {
        const ok = try self.array.set(allocator, x, y, z, val);
        if (!ok) {
            const count = self.array.palette.size();
            if (count < ARRAY_CAPACITY) {
                const new_container = try BlockArrayContainer.init(allocator, val, count + 1);
                const old = self.array;
                new_container.array.palette.block_to_offset.deinit(allocator);
                allocator.free(new_container.array.palette.entries.ptr[0..new_container.array.palette.capacity]);
                const pal_buf = try allocator.alloc(Block, new_container.array.max_palette_size);
                @memcpy(pal_buf[0..old.palette.entries.len], old.palette.entries);
                new_container.array.palette = .{ .entries = pal_buf[0..old.palette.entries.len], .capacity = new_container.array.max_palette_size };

                if (new_container.array.bits_per_block != 0 and old.bits_per_block != 0) {
                    var x2: u8 = 0;
                    while (x2 < ARRAY_DIM) : (x2 += 1) {
                        var z2: u8 = 0;
                        while (z2 < ARRAY_DIM) : (z2 += 1) {
                            var y2: u8 = 0;
                            while (y2 < ARRAY_DIM) : (y2 += 1) {
                                new_container.array.setPaletteOffset(x2, y2, z2, old.getPaletteOffset(x2, y2, z2));
                            }
                        }
                    }
                }
                new_container.array.may_need_gc = old.may_need_gc;
                self.deinit(allocator);
                self.* = new_container;
                _ = try self.array.set(allocator, x, y, z, val);
            } else {
                try self.array.collectGarbage(allocator, false, 1);
                const result = try self.array.set(allocator, x, y, z, val);
                std.debug.assert(result);
            }
        }
    }

    fn replaceAll(self: *BlockArrayContainer, from: Block, to: Block) void {
        self.array.replaceAll(from, to);
    }

    fn collectGarbage(self: *BlockArrayContainer, allocator: Allocator, force: bool) !void {
        try self.array.collectGarbage(allocator, force, 0);
    }

    fn getExpectedPayloadSize(bpb: u8) !u32 {
        if (!bpbIsValid(bpb)) return error.InvalidBitsPerBlock;
        return payloadSize(bpb);
    }
};

const LightArray = struct {
    data: [2048]u8,

    const DATA_SIZE = 2048;
    const MAX_LEVEL: u8 = 15;

    fn init() LightArray {
        return .{ .data = [_]u8{0} ** DATA_SIZE };
    }

    fn fromPayload(payload: []const u8) !LightArray {
        if (payload.len != DATA_SIZE) return error.WrongPayloadSize;
        var la: LightArray = .{ .data = undefined };
        @memcpy(&la.data, payload);
        return la;
    }

    fn fill(level: u8) LightArray {
        const byte = (level << 4) | level;
        return .{ .data = [_]u8{byte} ** DATA_SIZE };
    }

    fn clone(self: *const LightArray) LightArray {
        return .{ .data = self.data };
    }

    inline fn index(x: u8, y: u8, z: u8) struct { offset: usize, shift: u3 } {
        return .{
            .offset = ((x & 0xf) << 7) | ((z & 0xf) << 3) | ((y & 0xf) >> 1),
            .shift = @as(u3, @intCast((y & 1) << 2)),
        };
    }

    fn get(self: *const LightArray, x: u8, y: u8, z: u8) u8 {
        const idx = index(x, y, z);
        return (self.data[idx.offset] >> idx.shift) & 0xf;
    }
    fn set(self: *LightArray, x: u8, y: u8, z: u8, level: u8) void {
        const idx = index(x, y, z);
        const shift_amount: u3 = idx.shift;
        const nibble: u8 = 0xf;
        const mask: u8 = ~(nibble << shift_amount);
        self.data[idx.offset] = (self.data[idx.offset] & mask) | (level << shift_amount);
    }

    fn getRawData(self: *const LightArray) []const u8 {
        return &self.data;
    }

    fn isUniform(self: *const LightArray, level: u8) bool {
        const byte = (level << 4) | level;
        for (self.data) |b| {
            if (b != byte) return false;
        }
        return true;
    }
};

// Expected input sizes for legacy subchunk and chunk-column conversion.
const SUBCHUNK_IDS_SIZE: usize = 4096;
const SUBCHUNK_METAS_SIZE: usize = 2048;
const COLUMN_IDS_SIZE: usize = 32768;
const COLUMN_METAS_SIZE: usize = 16384;

fn flattenData(id: u8, meta: u8) Block {
    return (@as(Block, id) << 4) | @as(Block, meta);
}

// XZY subchunk index: id1=(x<<8)|(z<<4)|(y<<1), id2=id1|1, meta=id1>>1
fn getIndexSubChunkXZY(x: u8, y: u8, z: u8, id1_idx: *u16, id2_idx: *u16, meta_idx: *u16) void {
    id1_idx.* = (@as(u16, x) << 8) | (@as(u16, z) << 4) | (@as(u16, y) << 1);
    id2_idx.* = id1_idx.* | 1;
    meta_idx.* = id1_idx.* >> 1;
}

// Legacy column XZY index: id1=(x<<11)|(z<<7)|(yOff<<4)|(y<<1)
fn getIndexLegacyColumnXZY(x: u8, y: u8, z: u8, y_offset: u8, id1_idx: *u16, id2_idx: *u16, meta_idx: *u16) void {
    id1_idx.* = (@as(u16, x) << 11) | (@as(u16, z) << 7) | (@as(u16, y_offset) << 4) | (@as(u16, y) << 1);
    id2_idx.* = id1_idx.* | 1;
    meta_idx.* = id1_idx.* >> 1;
}

fn convertSubChunk(
    allocator: Allocator,
    ids: []const u8,
    metas: []const u8,
    expected_ids: usize,
    expected_metas: usize,
    y_offset: ?u8,
    swap_yzx: bool,
) !BlockArrayContainer {
    if (ids.len != expected_ids or metas.len != expected_metas) return error.InvalidDataSizes;

    // Single pass: discover unique blocks AND build the word array
    // simultaneously, avoiding two loops and 2048 container.set() calls.
    var seen: [4096]bool = .{false} ** 4096;
    var unique_blocks: [4096]Block = undefined;
    var unique_count: u32 = 0;
    var id1_idx: u16 = undefined;
    var id2_idx: u16 = undefined;
    var meta_idx: u16 = undefined;

    if (y_offset) |yo| {
        getIndexLegacyColumnXZY(0, 0, 0, yo, &id1_idx, &id2_idx, &meta_idx);
    } else {
        getIndexSubChunkXZY(0, 0, 0, &id1_idx, &id2_idx, &meta_idx);
    }
    const init_meta = metas[meta_idx] & 0xf;
    _ = flattenData(ids[id1_idx], init_meta);

    // Build palette offset map and collect unique blocks.
    var block_to_offset: [4096]u16 = undefined;
    @memset(&block_to_offset, 0);

    // First sub-pass: count unique blocks and assign palette offsets.
    var x: u8 = 0;
    while (x < 16) : (x += 1) {
        var z: u8 = 0;
        while (z < 16) : (z += 1) {
            var y: u8 = 0;
            while (y < 8) : (y += 1) {
                if (y_offset) |yo| {
                    getIndexLegacyColumnXZY(x, y, z, yo, &id1_idx, &id2_idx, &meta_idx);
                } else {
                    getIndexSubChunkXZY(x, y, z, &id1_idx, &id2_idx, &meta_idx);
                }
                const meta_byte = metas[meta_idx];
                const id1: u16 = (@as(u16, ids[id1_idx]) << 4) | (meta_byte & 0xf);
                const id2: u16 = (@as(u16, ids[id2_idx]) << 4) | ((meta_byte >> 4) & 0xf);

                if (!seen[id1]) {
                    seen[id1] = true;
                    block_to_offset[id1] = @intCast(unique_count);
                    unique_blocks[unique_count] = @intCast(id1);
                    unique_count += 1;
                }
                if (!seen[id2]) {
                    seen[id2] = true;
                    block_to_offset[id2] = @intCast(unique_count);
                    unique_blocks[unique_count] = @intCast(id2);
                    unique_count += 1;
                }
            }
        }
    }

    // Determine optimal bpb and build the word array.
    const bpb = optimalBpb(unique_count) orelse return error.InvalidCapacity;
    const palette = unique_blocks[0..unique_count];

    const nwords = if (bpb == 0) @as(u32, 0) else wordCount(bpb);
    var words = try allocator.alloc(u32, nwords);
    @memset(words, 0);

    if (bpb > 0) {
        const bpw = blocksPerWord(bpb);
        const is_pow2 = (bpw & (bpw - 1)) == 0;
        const word_shift: u4 = if (is_pow2) @intCast(@ctz(bpw)) else 0;
        const word_mask: u32 = if (is_pow2) bpw - 1 else 0;

        x = 0;
        while (x < 16) : (x += 1) {
            var z: u8 = 0;
            while (z < 16) : (z += 1) {
                var y: u8 = 0;
                while (y < 8) : (y += 1) {
                    if (y_offset) |yo| {
                        getIndexLegacyColumnXZY(x, y, z, yo, &id1_idx, &id2_idx, &meta_idx);
                    } else {
                        getIndexSubChunkXZY(x, y, z, &id1_idx, &id2_idx, &meta_idx);
                    }
                    const meta_byte = metas[meta_idx];
                    const id1: u16 = (@as(u16, ids[id1_idx]) << 4) | (meta_byte & 0xf);
                    const id2: u16 = (@as(u16, ids[id2_idx]) << 4) | ((meta_byte >> 4) & 0xf);

                    const y_even: u8 = y << 1;
                    const y_odd: u8 = (y << 1) | 1;

                    inline for (0..2) |slot| {
                        const b: u16 = if (slot == 0) id1 else id2;
                        const yy: u8 = if (slot == 0) y_even else y_odd;
                        const idx = if (swap_yzx)
                            (@as(u16, yy) << 8) | (@as(u16, x) << 4) | @as(u16, z)
                        else
                            (@as(u16, x) << 8) | (@as(u16, z) << 4) | @as(u16, yy);

                        const off = block_to_offset[b];
                        if (is_pow2) {
                            words[idx >> word_shift] |= @as(u32, off) << @as(u5, @intCast((idx & word_mask) * bpb));
                        } else {
                            const word_idx = idx / bpw;
                            const shift: u5 = @intCast((idx % bpw) * bpb);
                            words[word_idx] |= @as(u32, off) << shift;
                        }
                    }
                }
            }
        }
    }

    return BlockArrayContainer.initFromData(allocator, bpb, std.mem.sliceAsBytes(words), palette);
}

fn getThis(ctx: *NativeContext) ?*PhpObject {
    if (ctx.vm.frame_count == 0) return null;
    const v = ctx.vm.currentFrame().vars.get("$this") orelse return null;
    if (v != .object) return null;
    return v.object;
}

// c_allocator (malloc/free) so native_cleanup can free without the VM's
// allocator. Unlike page_allocator (mmap/munmap per alloc — a syscall each
// way), glibc's malloc uses sbrk + a free list for small allocations (<128KB),
// so after warmup alloc/free are pointer-bumps with zero syscalls. A PBA's
// total (words + palette + hashmap ≈ 832 bytes) is well under the mmap
// threshold, and freed memory returns to the free list for reuse by the next
// chunk load — critical for PocketMine's daemon model where chunks load/
// unload continuously. An ArenaAllocator would leak here: it never frees
// individual allocations, so memory grows to the historical total of all
// PBAs ever allocated, not the current live set.
fn setPBA(obj: *PhpObject, p: *BlockArrayContainer) void {
    obj.native = .{ .kind = .pba, .ptr = @intFromPtr(p) };
}

fn getPBA(obj: *const PhpObject) ?*BlockArrayContainer {
    return obj.native.get(BlockArrayContainer, .pba);
}

fn setLight(obj: *PhpObject, la: *LightArray) void {
    obj.native = .{ .kind = .light, .ptr = @intFromPtr(la) };
}

fn getLight(obj: *const PhpObject) ?*LightArray {
    return obj.native.get(LightArray, .light);
}

fn clonePBA(_: *VM, src: *PhpObject, copy: *PhpObject) bool {
    const container = getPBA(src) orelse return false;
    const new_container = c2_alloc.create(BlockArrayContainer) catch return false;
    new_container.* = container.clone(c2_alloc) catch {
        c2_alloc.destroy(new_container);
        return false;
    };
    setPBA(copy, new_container);
    return true;
}

fn cloneLight(_: *VM, src: *PhpObject, copy: *PhpObject) bool {
    const la = getLight(src) orelse return false;
    const new_la = c2_alloc.create(LightArray) catch return false;
    new_la.* = la.clone();
    setLight(copy, new_la);
    return true;
}

fn checkPaletteEntrySize(ctx: *NativeContext, v: i64) bool {
    if (v < 0 or v > std.math.maxInt(u32)) {
        const msg = std.fmt.allocPrint(
            ctx.allocator,
            "value {d} is too large to be used as a palette entry",
            .{v},
        ) catch return false;
        ctx.strings.append(ctx.allocator, msg) catch {};
        ctx.vm.setPendingException("InvalidArgumentException", msg) catch {};
        return false;
    }
    return true;
}

fn throwInvalidArgument(ctx: *NativeContext, msg: []const u8) RuntimeError!NativeResult {
    ctx.strings.append(ctx.allocator, msg) catch {};
    try ctx.vm.setPendingException("InvalidArgumentException", msg);
    return error.RuntimeError;
}

fn throwValueError(ctx: *NativeContext, msg: []const u8) RuntimeError!NativeResult {
    ctx.strings.append(ctx.allocator, msg) catch {};
    try ctx.vm.setPendingException("ValueError", msg);
    return error.RuntimeError;
}

fn throwLengthException(ctx: *NativeContext, msg: []const u8) RuntimeError!NativeResult {
    ctx.strings.append(ctx.allocator, msg) catch {};
    try ctx.vm.setPendingException("LengthException", msg);
    return error.RuntimeError;
}

fn throwLoadException(ctx: *NativeContext, msg: []const u8) RuntimeError!NativeResult {
    ctx.strings.append(ctx.allocator, msg) catch {};
    try ctx.vm.setPendingException(
        "pocketmine\\world\\format\\PalettedBlockArrayLoadException",
        msg,
    );
    return error.RuntimeError;
}

fn blockSliceToPhpArray(ctx: *NativeContext, blocks: []const Block) !NativeResult {
    const arr = try ctx.createArray();
    for (blocks) |b| {
        try arr.append(ctx.allocator, .{ .int = @intCast(b) });
    }
    return NativeResult.borrowed(.{ .array = arr });
}

fn phpArrayToBlocks(ctx: *NativeContext, arr_val: Value) ![]Block {
    if (arr_val != .array) return error.NotArray;
    const php_arr = arr_val.array;
    const blocks = try ctx.allocator.alloc(Block, php_arr.entries.items.len);
    for (php_arr.entries.items, 0..) |entry, i| {
        const v = if (entry.ref) |ref| ref.* else entry.value;
        blocks[i] = @intCast(Value.toInt(v));
    }
    return blocks;
}

fn pbaConstruct(ctx: *NativeContext, args: []const Value) RuntimeError!NativeResult {
    const obj = getThis(ctx) orelse return NativeResult.scalar(.null);
    if (args.len < 1) return NativeResult.scalar(.null);
    const fill_entry = Value.toInt(args[0]);
    if (!checkPaletteEntrySize(ctx, fill_entry)) return error.RuntimeError;

    const container = BlockArrayContainer.init(c2_alloc, @intCast(fill_entry), 0) catch |err| {
        if (err == error.InvalidCapacity) return throwInvalidArgument(ctx, "invalid capacity specified: 0");
        return error.OutOfMemory;
    };
    const p = try c2_alloc.create(BlockArrayContainer);
    p.* = container;
    setPBA(obj, p);
    return NativeResult.scalar(.null);
}

fn pbaFromData(ctx: *NativeContext, args: []const Value) RuntimeError!NativeResult {
    if (args.len < 3) return NativeResult.scalar(.null);
    const bpb_signed = Value.toInt(args[0]);
    if (args[1] != .string) return NativeResult.scalar(.null);
    const word_array = args[1].string;
    if (args[2] != .array) return NativeResult.scalar(.null);

    // Convert the palette and validate entry sizes in a single pass.
    const php_arr = args[2].array;
    const blocks = ctx.allocator.alloc(Block, php_arr.entries.items.len) catch return error.OutOfMemory;
    defer ctx.allocator.free(blocks);
    for (php_arr.entries.items, 0..) |entry, i| {
        const v = if (entry.ref) |ref| ref.* else entry.value;
        const block_val = Value.toInt(v);
        if (!checkPaletteEntrySize(ctx, block_val)) return error.RuntimeError;
        blocks[i] = @intCast(block_val);
    }

    const bpb: u8 = @intCast(@as(u64, @bitCast(bpb_signed)) & 0xff);
    const container = BlockArrayContainer.initFromData(c2_alloc, bpb, word_array.bytes(), blocks) catch |err| {
        if (err == error.InvalidBitsPerBlock) {
            const msg = std.fmt.allocPrint(ctx.allocator, "invalid bits-per-block: {d}", .{bpb_signed}) catch return error.OutOfMemory;
            return throwLoadException(ctx, msg);
        } else if (err == error.WrongWordArraySize) {
            const expected = if (bpbIsValid(bpb)) payloadSize(bpb) else 0;
            const msg = std.fmt.allocPrint(ctx.allocator, "word array size should be exactly {d} bytes for a {d}bpb block array, got {d} bytes", .{ expected, bpb, word_array.len }) catch return error.OutOfMemory;
            return throwLoadException(ctx, msg);
        } else if (err == error.EmptyPalette) {
            return throwLoadException(ctx, "palette cannot have a zero size");
        } else if (err == error.WrongPaletteSize) {
            return throwLoadException(ctx, "expected exactly 1 palette entry for zero bits-per-block");
        } else if (err == error.InvalidOffset) {
            return throwLoadException(ctx, "offset table contains invalid offset");
        }
        return error.OutOfMemory;
    };

    const obj = ctx.createObject("pocketmine\\world\\format\\PalettedBlockArray") catch return error.OutOfMemory;
    const p = try c2_alloc.create(BlockArrayContainer);
    p.* = container;
    setPBA(obj, p);
    return NativeResult.borrowed(.{ .object = obj });
}

fn pbaGetWordArray(ctx: *NativeContext, _: []const Value) RuntimeError!NativeResult {
    const obj = getThis(ctx) orelse return NativeResult.scalar(.null);
    const container = getPBA(obj) orelse return NativeResult.scalar(.null);
    const wa = container.getWordArray();
    const owned = try Value.String.create(ctx.allocator, wa);
    return NativeResult.takeString(owned);
}

fn pbaGetPalette(ctx: *NativeContext, _: []const Value) RuntimeError!NativeResult {
    const obj = getThis(ctx) orelse return NativeResult.scalar(.null);
    const container = getPBA(obj) orelse return NativeResult.scalar(.null);
    return blockSliceToPhpArray(ctx, container.getPalette()) catch error.OutOfMemory;
}

fn pbaSetPalette(ctx: *NativeContext, args: []const Value) RuntimeError!NativeResult {
    const obj = getThis(ctx) orelse return NativeResult.scalar(.null);
    if (args.len < 1 or args[0] != .array) return NativeResult.scalar(.null);

    const blocks = phpArrayToBlocks(ctx, args[0]) catch return error.OutOfMemory;
    defer ctx.allocator.free(blocks);

    const container = getPBA(obj) orelse return NativeResult.scalar(.null);
    container.setPalette(c2_alloc, blocks) catch |err| {
        if (err == error.WrongPaletteSize) {
            const msg = std.fmt.allocPrint(ctx.allocator, "new palette must be the same size as the old one, expected {d} but received {d}", .{ container.array.palette.size(), blocks.len }) catch return error.OutOfMemory;
            return throwValueError(ctx, msg);
        }
        return error.OutOfMemory;
    };
    return NativeResult.scalar(.null);
}

fn pbaGetMaxPaletteSize(ctx: *NativeContext, _: []const Value) RuntimeError!NativeResult {
    const obj = getThis(ctx) orelse return NativeResult.scalar(.null);
    const container = getPBA(obj) orelse return NativeResult.scalar(.null);
    return NativeResult.scalar(.{ .int = @intCast(container.getMaxPaletteSize()) });
}

fn pbaGetBitsPerBlock(ctx: *NativeContext, _: []const Value) RuntimeError!NativeResult {
    const obj = getThis(ctx) orelse return NativeResult.scalar(.null);
    const container = getPBA(obj) orelse return NativeResult.scalar(.null);
    return NativeResult.scalar(.{ .int = @intCast(container.getBitsPerBlock()) });
}

fn pbaGet(ctx: *NativeContext, args: []const Value) RuntimeError!NativeResult {
    const obj = getThis(ctx) orelse return NativeResult.scalar(.null);
    if (args.len < 3) return NativeResult.scalar(.null);
    const x: u8 = @intCast(@as(u64, @bitCast(Value.toInt(args[0]))) & 0xff);
    const y: u8 = @intCast(@as(u64, @bitCast(Value.toInt(args[1]))) & 0xff);
    const z: u8 = @intCast(@as(u64, @bitCast(Value.toInt(args[2]))) & 0xff);
    const container = getPBA(obj) orelse return NativeResult.scalar(.null);
    return NativeResult.scalar(.{ .int = @intCast(container.get(x, y, z)) });
}

fn pbaSet(ctx: *NativeContext, args: []const Value) RuntimeError!NativeResult {
    const obj = getThis(ctx) orelse return NativeResult.scalar(.null);
    if (args.len < 4) return NativeResult.scalar(.null);
    const x: u8 = @intCast(@as(u64, @bitCast(Value.toInt(args[0]))) & 0xff);
    const y: u8 = @intCast(@as(u64, @bitCast(Value.toInt(args[1]))) & 0xff);
    const z: u8 = @intCast(@as(u64, @bitCast(Value.toInt(args[2]))) & 0xff);
    const val: Block = @intCast(@as(u64, @bitCast(Value.toInt(args[3]))) & 0xffffffff);
    const container = getPBA(obj) orelse return NativeResult.scalar(.null);
    container.set(c2_alloc, x, y, z, val) catch return error.OutOfMemory;
    return NativeResult.scalar(.null);
}

fn pbaReplaceAll(ctx: *NativeContext, args: []const Value) RuntimeError!NativeResult {
    const obj = getThis(ctx) orelse return NativeResult.scalar(.null);
    if (args.len < 2) return NativeResult.scalar(.null);
    const old_val: Block = @intCast(@as(u64, @bitCast(Value.toInt(args[0]))) & 0xffffffff);
    const new_val: Block = @intCast(@as(u64, @bitCast(Value.toInt(args[1]))) & 0xffffffff);
    const container = getPBA(obj) orelse return NativeResult.scalar(.null);
    container.replaceAll(old_val, new_val);
    return NativeResult.scalar(.null);
}

fn pbaCollectGarbage(ctx: *NativeContext, args: []const Value) RuntimeError!NativeResult {
    const obj = getThis(ctx) orelse return NativeResult.scalar(.null);
    const force = if (args.len >= 1) args[0].isTruthy() else false;
    const container = getPBA(obj) orelse return NativeResult.scalar(.null);
    container.collectGarbage(c2_alloc, force) catch return error.OutOfMemory;
    return NativeResult.scalar(.null);
}

fn pbaGetExpectedWordArraySize(ctx: *NativeContext, args: []const Value) RuntimeError!NativeResult {
    if (args.len < 1) return NativeResult.scalar(.null);
    const bpb_signed = Value.toInt(args[0]);
    const casted: u8 = @intCast(@as(u64, @bitCast(bpb_signed)) & 0xff);
    const casted_back: i64 = @intCast(casted);
    if (bpb_signed != casted_back) {
        const msg = std.fmt.allocPrint(ctx.allocator, "invalid bits-per-block: {d}", .{bpb_signed}) catch return error.OutOfMemory;
        return throwInvalidArgument(ctx, msg);
    }
    const size = BlockArrayContainer.getExpectedPayloadSize(casted) catch |err| {
        if (err == error.InvalidBitsPerBlock) {
            const msg = std.fmt.allocPrint(ctx.allocator, "invalid bits-per-block: {d}", .{bpb_signed}) catch return error.OutOfMemory;
            return throwInvalidArgument(ctx, msg);
        }
        return error.OutOfMemory;
    };
    return NativeResult.scalar(.{ .int = @intCast(size) });
}

fn laConstruct(ctx: *NativeContext, args: []const Value) RuntimeError!NativeResult {
    const obj = getThis(ctx) orelse return NativeResult.scalar(.null);
    if (args.len < 1 or args[0] != .string) return NativeResult.scalar(.null);
    if (args[0].string.len != LightArray.DATA_SIZE) {
        const msg = std.fmt.allocPrint(ctx.allocator, "Payload size must be {d} bytes, but got {d} bytes", .{ LightArray.DATA_SIZE, args[0].string.len }) catch return error.OutOfMemory;
        return throwInvalidArgument(ctx, msg);
    }
    const la = try c2_alloc.create(LightArray);
    la.* = LightArray.fromPayload(args[0].string.bytes()) catch return NativeResult.scalar(.null);
    setLight(obj, la);
    return NativeResult.scalar(.null);
}

fn laFill(ctx: *NativeContext, args: []const Value) RuntimeError!NativeResult {
    if (args.len < 1) return NativeResult.scalar(.null);
    const level_signed = Value.toInt(args[0]);
    if (level_signed > LightArray.MAX_LEVEL) {
        const msg = std.fmt.allocPrint(ctx.allocator, "Light level must be max {d}", .{LightArray.MAX_LEVEL}) catch return error.OutOfMemory;
        return throwInvalidArgument(ctx, msg);
    }
    const level: u8 = @intCast(@as(u64, @bitCast(level_signed)) & 0xff);
    const la = try c2_alloc.create(LightArray);
    la.* = LightArray.fill(level);
    const obj = ctx.createObject("pocketmine\\world\\format\\LightArray") catch return error.OutOfMemory;
    setLight(obj, la);
    return NativeResult.borrowed(.{ .object = obj });
}

fn laGet(ctx: *NativeContext, args: []const Value) RuntimeError!NativeResult {
    const obj = getThis(ctx) orelse return NativeResult.scalar(.null);
    if (args.len < 3) return NativeResult.scalar(.null);
    const x: u8 = @intCast(@as(u64, @bitCast(Value.toInt(args[0]))) & 0xf);
    const y: u8 = @intCast(@as(u64, @bitCast(Value.toInt(args[1]))) & 0xf);
    const z: u8 = @intCast(@as(u64, @bitCast(Value.toInt(args[2]))) & 0xf);
    const la = getLight(obj) orelse return NativeResult.scalar(.null);
    return NativeResult.scalar(.{ .int = @intCast(la.get(x, y, z)) });
}

fn laSet(ctx: *NativeContext, args: []const Value) RuntimeError!NativeResult {
    const obj = getThis(ctx) orelse return NativeResult.scalar(.null);
    if (args.len < 4) return NativeResult.scalar(.null);
    const x: u8 = @intCast(@as(u64, @bitCast(Value.toInt(args[0]))) & 0xf);
    const y: u8 = @intCast(@as(u64, @bitCast(Value.toInt(args[1]))) & 0xf);
    const z: u8 = @intCast(@as(u64, @bitCast(Value.toInt(args[2]))) & 0xf);
    const level: u8 = @intCast(@as(u64, @bitCast(Value.toInt(args[3]))) & 0xff);
    const la = getLight(obj) orelse return NativeResult.scalar(.null);
    la.set(x, y, z, level);
    return NativeResult.scalar(.null);
}

fn laGetData(ctx: *NativeContext, _: []const Value) RuntimeError!NativeResult {
    const obj = getThis(ctx) orelse return NativeResult.scalar(.null);
    const la = getLight(obj) orelse return NativeResult.scalar(.null);
    const owned = try Value.String.create(ctx.allocator, la.getRawData());
    return NativeResult.takeString(owned);
}

fn laCollectGarbage(ctx: *NativeContext, _: []const Value) RuntimeError!NativeResult {
    _ = ctx;
    return NativeResult.scalar(.null);
}

fn laIsUniform(ctx: *NativeContext, args: []const Value) RuntimeError!NativeResult {
    const obj = getThis(ctx) orelse return NativeResult.scalar(.null);
    if (args.len < 1) return NativeResult.scalar(.null);
    const level_signed = Value.toInt(args[0]);
    if (level_signed > LightArray.MAX_LEVEL) {
        const msg = std.fmt.allocPrint(ctx.allocator, "Light level must be max {d}", .{LightArray.MAX_LEVEL}) catch return error.OutOfMemory;
        return throwInvalidArgument(ctx, msg);
    }
    const level: u8 = @intCast(@as(u64, @bitCast(level_signed)) & 0xff);
    const la = getLight(obj) orelse return NativeResult.scalar(.null);
    return NativeResult.scalar(.{ .bool = la.isUniform(level) });
}

fn sccConvertSubChunkXZY(ctx: *NativeContext, args: []const Value) RuntimeError!NativeResult {
    if (args.len < 2 or args[0] != .string or args[1] != .string) return NativeResult.scalar(.null);
    const container = convertSubChunk(
        c2_alloc,
        args[0].string.bytes(),
        args[1].string.bytes(),
        SUBCHUNK_IDS_SIZE,
        SUBCHUNK_METAS_SIZE,
        null,
        false,
    ) catch |err| {
        if (err == error.InvalidDataSizes) {
            const msg = std.fmt.allocPrint(ctx.allocator, "Invalid data sizes (got {d} and {d})", .{ args[0].string.len, args[1].string.len }) catch return error.OutOfMemory;
            return throwLengthException(ctx, msg);
        }
        return error.OutOfMemory;
    };
    const obj = ctx.createObject("pocketmine\\world\\format\\PalettedBlockArray") catch return error.OutOfMemory;
    const p = try c2_alloc.create(BlockArrayContainer);
    p.* = container;
    setPBA(obj, p);
    return NativeResult.borrowed(.{ .object = obj });
}

fn sccConvertSubChunkYZX(ctx: *NativeContext, args: []const Value) RuntimeError!NativeResult {
    if (args.len < 2 or args[0] != .string or args[1] != .string) return NativeResult.scalar(.null);
    const container = convertSubChunk(
        c2_alloc,
        args[0].string.bytes(),
        args[1].string.bytes(),
        SUBCHUNK_IDS_SIZE,
        SUBCHUNK_METAS_SIZE,
        null,
        true,
    ) catch |err| {
        if (err == error.InvalidDataSizes) {
            const msg = std.fmt.allocPrint(ctx.allocator, "Invalid data sizes (got {d} and {d})", .{ args[0].string.len, args[1].string.len }) catch return error.OutOfMemory;
            return throwLengthException(ctx, msg);
        }
        return error.OutOfMemory;
    };
    const obj = ctx.createObject("pocketmine\\world\\format\\PalettedBlockArray") catch return error.OutOfMemory;
    const p = try c2_alloc.create(BlockArrayContainer);
    p.* = container;
    setPBA(obj, p);
    return NativeResult.borrowed(.{ .object = obj });
}

fn sccConvertSubChunkFromLegacyColumn(ctx: *NativeContext, args: []const Value) RuntimeError!NativeResult {
    if (args.len < 3 or args[0] != .string or args[1] != .string) return NativeResult.scalar(.null);
    const y_offset_signed = Value.toInt(args[2]);
    if (y_offset_signed < 0 or y_offset_signed > 7) {
        ctx.vm.setPendingException("InvalidArgumentException", "Y offset must be in range 0-7") catch {};
        return error.RuntimeError;
    }
    const y_offset: u8 = @intCast(y_offset_signed);
    const container = convertSubChunk(
        c2_alloc,
        args[0].string.bytes(),
        args[1].string.bytes(),
        COLUMN_IDS_SIZE,
        COLUMN_METAS_SIZE,
        y_offset,
        false,
    ) catch |err| {
        if (err == error.InvalidDataSizes) {
            const msg = std.fmt.allocPrint(ctx.allocator, "Invalid data sizes (got {d} and {d})", .{ args[0].string.len, args[1].string.len }) catch return error.OutOfMemory;
            return throwLengthException(ctx, msg);
        }
        return error.OutOfMemory;
    };
    const obj = ctx.createObject("pocketmine\\world\\format\\PalettedBlockArray") catch return error.OutOfMemory;
    const p = try c2_alloc.create(BlockArrayContainer);
    p.* = container;
    setPBA(obj, p);
    return NativeResult.borrowed(.{ .object = obj });
}

fn sccConstruct(_: *NativeContext, _: []const Value) RuntimeError!NativeResult {
    return NativeResult.scalar(.null);
}

fn pbaCleanup(obj: *PhpObject) bool {
    if (getPBA(obj)) |container| {
        container.deinit(c2_alloc);
        c2_alloc.destroy(container);
        obj.native = .{};
    }
    return true;
}

fn laCleanup(obj: *PhpObject) bool {
    if (getLight(obj)) |la| {
        c2_alloc.destroy(la);
        obj.native = .{};
    }
    return true;
}

// Called by the VM during freeHeapItems to clean up pooled objects.
pub fn cleanupResources(objects: std.ArrayListUnmanaged(*PhpObject)) void {
    for (objects.items) |obj| {
        if (obj.pooled) continue;
        switch (obj.native.kind) {
            .pba => _ = pbaCleanup(obj),
            .light => _ = laCleanup(obj),
            else => continue,
        }
    }
}

pub fn register(vm: *VM, a: Allocator) !void {
    const load_exc_def = ClassDef{
        .name = "pocketmine\\world\\format\\PalettedBlockArrayLoadException",
        .parent = "RuntimeException",
    };
    try vm.classes.put(a, "pocketmine\\world\\format\\PalettedBlockArrayLoadException", load_exc_def);

    var pba_def = ClassDef{
        .name = "pocketmine\\world\\format\\PalettedBlockArray",
        .is_final = true,
        .native_clone = clonePBA,
    };

    try pba_def.methods.put(a, "__construct", .{ .name = "__construct", .arity = 1 });
    try pba_def.methods.put(a, "fromData", .{ .name = "fromData", .arity = 3, .is_static = true });
    try pba_def.methods.put(a, "getWordArray", .{ .name = "getWordArray", .arity = 0 });
    try pba_def.methods.put(a, "getPalette", .{ .name = "getPalette", .arity = 0 });
    try pba_def.methods.put(a, "setPalette", .{ .name = "setPalette", .arity = 1 });
    try pba_def.methods.put(a, "getMaxPaletteSize", .{ .name = "getMaxPaletteSize", .arity = 0 });
    try pba_def.methods.put(a, "getBitsPerBlock", .{ .name = "getBitsPerBlock", .arity = 0 });
    try pba_def.methods.put(a, "get", .{ .name = "get", .arity = 3 });
    try pba_def.methods.put(a, "set", .{ .name = "set", .arity = 4 });
    try pba_def.methods.put(a, "replaceAll", .{ .name = "replaceAll", .arity = 2 });
    try pba_def.methods.put(a, "collectGarbage", .{ .name = "collectGarbage", .arity = 1 });
    try pba_def.methods.put(a, "getExpectedWordArraySize", .{ .name = "getExpectedWordArraySize", .arity = 1, .is_static = true });
    try vm.classes.put(a, "pocketmine\\world\\format\\PalettedBlockArray", pba_def);

    try vm.native_fns.put(a, "pocketmine\\world\\format\\PalettedBlockArray::__construct", pbaConstruct);
    try vm.native_fns.put(a, "pocketmine\\world\\format\\PalettedBlockArray::fromData", pbaFromData);
    try vm.native_fns.put(a, "pocketmine\\world\\format\\PalettedBlockArray::getWordArray", pbaGetWordArray);
    try vm.native_fns.put(a, "pocketmine\\world\\format\\PalettedBlockArray::getPalette", pbaGetPalette);
    try vm.native_fns.put(a, "pocketmine\\world\\format\\PalettedBlockArray::setPalette", pbaSetPalette);
    try vm.native_fns.put(a, "pocketmine\\world\\format\\PalettedBlockArray::getMaxPaletteSize", pbaGetMaxPaletteSize);
    try vm.native_fns.put(a, "pocketmine\\world\\format\\PalettedBlockArray::getBitsPerBlock", pbaGetBitsPerBlock);
    try vm.native_fns.put(a, "pocketmine\\world\\format\\PalettedBlockArray::get", pbaGet);
    try vm.native_fns.put(a, "pocketmine\\world\\format\\PalettedBlockArray::set", pbaSet);
    try vm.native_fns.put(a, "pocketmine\\world\\format\\PalettedBlockArray::replaceAll", pbaReplaceAll);
    try vm.native_fns.put(a, "pocketmine\\world\\format\\PalettedBlockArray::collectGarbage", pbaCollectGarbage);
    try vm.native_fns.put(a, "pocketmine\\world\\format\\PalettedBlockArray::getExpectedWordArraySize", pbaGetExpectedWordArraySize);

    var la_def = ClassDef{
        .name = "pocketmine\\world\\format\\LightArray",
        .is_final = true,
        .native_clone = cloneLight,
    };

    try la_def.methods.put(a, "__construct", .{ .name = "__construct", .arity = 1 });
    try la_def.methods.put(a, "fill", .{ .name = "fill", .arity = 1, .is_static = true });
    try la_def.methods.put(a, "get", .{ .name = "get", .arity = 3 });
    try la_def.methods.put(a, "set", .{ .name = "set", .arity = 4 });
    try la_def.methods.put(a, "getData", .{ .name = "getData", .arity = 0 });
    try la_def.methods.put(a, "collectGarbage", .{ .name = "collectGarbage", .arity = 0 });
    try la_def.methods.put(a, "isUniform", .{ .name = "isUniform", .arity = 1 });
    try vm.classes.put(a, "pocketmine\\world\\format\\LightArray", la_def);

    try vm.native_fns.put(a, "pocketmine\\world\\format\\LightArray::__construct", laConstruct);
    try vm.native_fns.put(a, "pocketmine\\world\\format\\LightArray::fill", laFill);
    try vm.native_fns.put(a, "pocketmine\\world\\format\\LightArray::get", laGet);
    try vm.native_fns.put(a, "pocketmine\\world\\format\\LightArray::set", laSet);
    try vm.native_fns.put(a, "pocketmine\\world\\format\\LightArray::getData", laGetData);
    try vm.native_fns.put(a, "pocketmine\\world\\format\\LightArray::collectGarbage", laCollectGarbage);
    try vm.native_fns.put(a, "pocketmine\\world\\format\\LightArray::isUniform", laIsUniform);

    var scc_def = ClassDef{
        .name = "pocketmine\\world\\format\\io\\SubChunkConverter",
        .is_final = true,
    };
    try scc_def.methods.put(a, "convertSubChunkXZY", .{ .name = "convertSubChunkXZY", .arity = 2, .is_static = true });
    try scc_def.methods.put(a, "convertSubChunkYZX", .{ .name = "convertSubChunkYZX", .arity = 2, .is_static = true });
    try scc_def.methods.put(a, "convertSubChunkFromLegacyColumn", .{ .name = "convertSubChunkFromLegacyColumn", .arity = 3, .is_static = true });
    try scc_def.methods.put(a, "__construct", .{ .name = "__construct", .arity = 0, .visibility = .private });
    try vm.classes.put(a, "pocketmine\\world\\format\\io\\SubChunkConverter", scc_def);

    try vm.native_fns.put(a, "pocketmine\\world\\format\\io\\SubChunkConverter::convertSubChunkXZY", sccConvertSubChunkXZY);
    try vm.native_fns.put(a, "pocketmine\\world\\format\\io\\SubChunkConverter::convertSubChunkYZX", sccConvertSubChunkYZX);
    try vm.native_fns.put(a, "pocketmine\\world\\format\\io\\SubChunkConverter::convertSubChunkFromLegacyColumn", sccConvertSubChunkFromLegacyColumn);
    try vm.native_fns.put(a, "pocketmine\\world\\format\\io\\SubChunkConverter::__construct", sccConstruct);
}

test "PalettedBlockArray basic get/set" {
    const alloc = std.testing.allocator;
    var container = try BlockArrayContainer.init(alloc, 1, 0);
    defer container.deinit(alloc);

    try std.testing.expectEqual(@as(Block, 1), container.get(0, 0, 0));
    try container.set(alloc, 0, 0, 0, 2);
    try std.testing.expectEqual(@as(Block, 2), container.get(0, 0, 0));
    try std.testing.expectEqual(@as(Block, 1), container.get(0, 0, 1));
}

test "PalettedBlockArray coordinate truncation" {
    const alloc = std.testing.allocator;
    var container = try BlockArrayContainer.init(alloc, 1, 0);
    defer container.deinit(alloc);

    try container.set(alloc, 0, 0, 0, 2);
    try std.testing.expectEqual(@as(Block, 2), container.get(16, 16, 16));
}

test "PalettedBlockArray fill initializer" {
    const alloc = std.testing.allocator;
    var container = try BlockArrayContainer.init(alloc, 6, 0);
    defer container.deinit(alloc);

    var x: u8 = 0;
    while (x < 16) : (x += 1) {
        var z: u8 = 0;
        while (z < 16) : (z += 1) {
            var y: u8 = 0;
            while (y < 16) : (y += 1) {
                try std.testing.expectEqual(@as(Block, 6), container.get(x, y, z));
            }
        }
    }
}

test "PalettedBlockArray resize" {
    const alloc = std.testing.allocator;
    var container = try BlockArrayContainer.init(alloc, 1, 0);
    defer container.deinit(alloc);

    var i: u32 = 0;
    while (i < 4096) : (i += 1) {
        const x: u8 = @intCast(i & 0xf);
        const y: u8 = @intCast((i >> 4) & 0xf);
        const z: u8 = @intCast((i >> 8) & 0xf);
        try container.set(alloc, x, y, z, @intCast(i));
    }

    i = 0;
    while (i < 4096) : (i += 1) {
        const x: u8 = @intCast(i & 0xf);
        const y: u8 = @intCast((i >> 4) & 0xf);
        const z: u8 = @intCast((i >> 8) & 0xf);
        try std.testing.expectEqual(@as(Block, @intCast(i)), container.get(x, y, z));
    }
}

test "PalettedBlockArray getExpectedWordArraySize" {
    try std.testing.expectEqual(@as(u32, 0), try BlockArrayContainer.getExpectedPayloadSize(0));
    try std.testing.expectEqual(@as(u32, 512), try BlockArrayContainer.getExpectedPayloadSize(1));
    try std.testing.expectEqual(@as(u32, 1024), try BlockArrayContainer.getExpectedPayloadSize(2));
    try std.testing.expectEqual(@as(u32, 1640), try BlockArrayContainer.getExpectedPayloadSize(3));
    try std.testing.expectEqual(@as(u32, 2048), try BlockArrayContainer.getExpectedPayloadSize(4));
    try std.testing.expectEqual(@as(u32, 2732), try BlockArrayContainer.getExpectedPayloadSize(5));
    try std.testing.expectEqual(@as(u32, 3280), try BlockArrayContainer.getExpectedPayloadSize(6));
    try std.testing.expectEqual(@as(u32, 4096), try BlockArrayContainer.getExpectedPayloadSize(8));
    try std.testing.expectEqual(@as(u32, 8192), try BlockArrayContainer.getExpectedPayloadSize(16));
}

test "LightArray basic" {
    var la = LightArray.fill(5);
    var x: u8 = 0;
    while (x < 16) : (x += 1) {
        var z: u8 = 0;
        while (z < 16) : (z += 1) {
            var y: u8 = 0;
            while (y < 16) : (y += 1) {
                try std.testing.expectEqual(@as(u8, 5), la.get(x, y, z));
            }
        }
    }
    try std.testing.expect(la.isUniform(5));
    try std.testing.expect(!la.isUniform(0));

    la.set(0, 0, 0, 3);
    try std.testing.expectEqual(@as(u8, 3), la.get(0, 0, 0));
    try std.testing.expect(!la.isUniform(5));
}

test "LightArray coordinate truncation" {
    var la = LightArray.fill(0);
    la.set(0, 0, 0, 15);
    try std.testing.expectEqual(@as(u8, 15), la.get(16, 16, 16));
}

test "LightArray serialize round-trip" {
    const la = LightArray.fill(7);
    const data = la.getRawData();
    const la2 = try LightArray.fromPayload(data);
    try std.testing.expectEqualSlices(u8, &la.data, &la2.data);
}
