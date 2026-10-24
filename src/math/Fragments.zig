//! Bounded provenance for previously complete display formulas. A clipped
//! redraw may reuse a formula only after all visible rows match exactly.
const Cache = @This();
const std = @import("std");
const scanner = @import("../terminal/markdown_math.zig");
const Allocator = std.mem.Allocator;

pub const Row = struct { text: []const u8, output: bool = true, code: bool = false };
pub const Match = struct { id: u64, top: i32, first: u16, end: u16, continued: bool = false };
pub const Complete = struct { top: i32, rows: u32, delimiter: scanner.Delimiter };
pub const Block = struct {
    id: u64,
    columns: u16,
    lines: [][]const u8,
    body: []u8,
    delimiter: scanner.Delimiter,
    bytes: usize,

    fn deinit(self: Block, alloc: Allocator) void {
        for (self.lines) |line| alloc.free(line);
        alloc.free(self.lines);
        alloc.free(self.body);
    }
};
const max_blocks = 32;
const max_bytes = 512 * 1024;
blocks: std.ArrayList(Block) = .empty,
row_count: usize = 0,
tracked: std.ArrayList(Match) = .empty,
proposals: std.ArrayList(Match) = .empty,
bytes: usize = 0,
next_id: u64 = 1,
columns: u16 = 0,

pub fn clear(self: *Cache, alloc: Allocator) void {
    for (self.blocks.items) |block| block.deinit(alloc);
    self.blocks.clearRetainingCapacity();
    self.row_count = 0;
    self.tracked.clearRetainingCapacity();
    self.proposals.clearRetainingCapacity();
    self.bytes = 0;
}
pub fn deinit(self: *Cache, alloc: Allocator) void {
    self.clear(alloc);
    self.blocks.deinit(alloc);
    self.tracked.deinit(alloc);
    self.proposals.deinit(alloc);
}
pub fn get(self: *const Cache, id: u64) ?*const Block {
    for (self.blocks.items) |*block| if (block.id == id) return block;
    return null;
}
pub fn remember(self: *Cache, alloc: Allocator, columns: u16, rows: []const Row, body: []const u8, delimiter: scanner.Delimiter) !void {
    if (rows.len < 3 or rows.len > 512) return;
    var bytes = body.len + rows.len * @sizeOf([]const u8);
    for (rows) |row| bytes += row.text.len;
    if (bytes > max_bytes) return;
    for (self.blocks.items, 0..) |block, i| {
        if (block.columns != columns or block.delimiter != delimiter or block.lines.len != rows.len or !std.mem.eql(u8, block.body, body)) continue;
        var same = true;
        for (block.lines, rows) |a, b| if (!std.mem.eql(u8, a, b.text)) {
            same = false;
            break;
        };
        if (same) {
            const existing = self.blocks.orderedRemove(i);
            self.blocks.appendAssumeCapacity(existing);
            return;
        }
    }
    const lines = try alloc.alloc([]const u8, rows.len);
    var initialized: usize = 0;
    errdefer {
        for (lines[0..initialized]) |line| alloc.free(line);
        alloc.free(lines);
    }
    for (rows, 0..) |row, i| {
        lines[i] = try alloc.dupe(u8, row.text);
        initialized += 1;
    }
    const owned_body = try alloc.dupe(u8, body);
    errdefer alloc.free(owned_body);
    while (self.blocks.items.len >= max_blocks or self.bytes + bytes > max_bytes) {
        const old = self.blocks.orderedRemove(0);
        self.bytes -= old.bytes;
        old.deinit(alloc);
    }
    try self.blocks.append(alloc, .{ .id = self.next_id, .columns = columns, .lines = lines, .body = owned_body, .delimiter = delimiter, .bytes = bytes });
    self.next_id +%= 1;
    self.bytes += bytes;
}

fn valid(block: *const Block, m: Match, rows: []const Row) bool {
    if (m.first >= m.end or m.end > rows.len) return false;
    const first = @as(i32, m.first) - m.top;
    if (first < 0 or first + (m.end - m.first) > block.lines.len) return false;
    for (rows[m.first..m.end], block.lines[@intCast(first)..][0 .. m.end - m.first]) |row, expected| {
        if (!row.output or row.code or !std.mem.eql(u8, row.text, expected)) return false;
    }
    return true;
}
fn propose(self: *Cache, alloc: Allocator, block: *const Block, m: Match, rows: []const Row) !void {
    // A stationary fragment whose previously verified source changed is an
    // edit, not clipping. Do not salvage a shorter suffix from that edit.
    for (self.tracked.items) |old| if (old.id == m.id and old.top == m.top and
        !valid(block, old, rows)) return;
    var minimum = @min(@as(usize, 3), block.lines.len - 1);
    var proposal = m;
    proposal.continued = false;
    // Once a fragment has been verified, shrinking it to the last one or two
    // rows must not bring its delimiters back as raw text. Only a subset of
    // that exact previous source range gets this allowance.
    for (self.tracked.items) |old| if (old.id == m.id and
        (@as(i32, old.first) - old.top > 0 or @as(i32, old.end) - old.top < block.lines.len) and
        ((m.first == old.first and m.top <= old.top) or
            (m.end == old.end and m.top >= old.top)) and
        @as(i32, m.first) - m.top >= @as(i32, old.first) - old.top and
        @as(i32, m.end) - m.top <= @as(i32, old.end) - old.top)
    {
        minimum = 1;
        proposal.continued = true;
        break;
    };
    if (m.end -| m.first < minimum or !valid(block, m, rows)) return;
    for (self.proposals.items) |*old| if (old.id == m.id and old.top == m.top) {
        if (m.end - m.first > old.end - old.first) old.* = proposal;
        return;
    };
    try self.proposals.append(alloc, proposal);
}

fn dominated(m: Match, proposals: []const Match) bool {
    for (proposals) |other| if (other.first <= m.first and other.end >= m.end and
        (other.first < m.first or other.end > m.end or (!m.continued and other.continued))) return true;
    return false;
}

/// Returned matches belong to this cache until the next capture. They never
/// authorize changing, moving, or hiding any unmatched source cells.
pub fn recover(self: *Cache, alloc: Allocator, columns: u16, rows: []const Row) ![]const Match {
    return self.recoverComplete(alloc, columns, rows, &.{});
}

/// Complete current syntax takes priority over a partial match to old source.
/// Symmetric $$ delimiters need an exception when a verified cached suffix
/// proves that an apparent opening delimiter is actually a clipped closing.
pub fn recoverComplete(self: *Cache, alloc: Allocator, columns: u16, rows: []const Row, complete: []const Complete) ![]const Match {
    self.proposals.clearRetainingCapacity();
    if (self.columns == columns and self.row_count == rows.len) {
        for (self.tracked.items) |m| if (self.get(m.id)) |block| try self.propose(alloc, block, m, rows);
    }
    for (self.blocks.items) |*block| {
        if (block.columns != columns) continue;
        // A redraw may clip several blocks inside the physical screen. Find
        // maximal contiguous source ranges independently, without assuming a
        // particular scroll region, footer, or application layout.
        const length: i32 = @intCast(block.lines.len);
        var top: i32 = 1 - length;
        while (top < rows.len) : (top += 1) {
            var y: usize = @intCast(@max(0, top));
            const limit: usize = @intCast(@min(@as(i32, @intCast(rows.len)), top + length));
            while (y < limit) {
                const first = y;
                while (y < limit and rows[y].output and !rows[y].code and
                    std.mem.eql(u8, rows[y].text, block.lines[@intCast(@as(i32, @intCast(y)) - top)])) : (y += 1)
                {}
                if (y > first) try self.propose(alloc, block, .{ .id = block.id, .top = top, .first = @intCast(first), .end = @intCast(y) }, rows);
                y += @intFromBool(y < limit);
            }
        }
    }
    var authoritative: std.ArrayList(Complete) = .empty;
    defer authoritative.deinit(alloc);
    for (complete) |full| {
        if (full.rows == 0) continue;
        var orphan = false;
        if (full.delimiter == .double_dollar) for (self.proposals.items) |m| {
            const block = self.get(m.id) orelse continue;
            if (block.delimiter != .double_dollar) continue;
            const bottom = full.top + @as(i32, @intCast(full.rows));
            if ((m.first < full.top and @as(i32, m.end) - 1 == full.top and
                @as(i32, m.end) - m.top == block.lines.len) or
                (m.first == bottom - 1 and m.end > bottom and
                    @as(i32, m.first) - m.top == 0))
            {
                orphan = true;
                break;
            }
        };
        if (!orphan) try authoritative.append(alloc, full);
    }
    var proposal: usize = 0;
    while (proposal < self.proposals.items.len) {
        const m = self.proposals.items[proposal];
        const block = self.get(m.id).?;
        var conflict = false;
        for (authoritative.items) |full| {
            const first = @max(0, full.top);
            const end = @min(@as(i32, @intCast(rows.len)), full.top + @as(i32, @intCast(full.rows)));
            if (m.first < end and first < m.end and
                (m.top != full.top or block.lines.len != full.rows or m.first != first or m.end != end))
            {
                conflict = true;
                break;
            }
        }
        if (conflict) {
            _ = self.proposals.orderedRemove(proposal);
        } else proposal += 1;
    }
    // Repeated rows can yield incidental short matches inside a longer
    // verified range. Remove those first so ambiguity checks stay quadratic
    // and compare only the ranges with maximal exact context.
    var index: usize = 0;
    while (index < self.proposals.items.len) {
        if (dominated(self.proposals.items[index], self.proposals.items)) {
            _ = self.proposals.orderedRemove(index);
        } else index += 1;
    }
    self.tracked.clearRetainingCapacity();
    for (self.proposals.items, 0..) |m, i| {
        var ambiguous = false;
        for (self.proposals.items, 0..) |other, j| {
            if (i != j and m.first < other.end and other.first < m.end) {
                ambiguous = true;
                break;
            }
        }
        if (!ambiguous) try self.tracked.append(alloc, m);
    }
    for (self.tracked.items) |m| {
        for (self.blocks.items, 0..) |block, i| if (block.id == m.id) {
            const used = self.blocks.orderedRemove(i);
            self.blocks.appendAssumeCapacity(used);
            break;
        };
    }
    self.row_count = rows.len;
    self.columns = columns;
    return self.tracked.items;
}

test "ghosttex fragment cache verifies complete visible suffix and retains unchanged fragments" {
    const alloc = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(alloc);
    const block = [_]Row{ .{ .text = "\\[" }, .{ .text = "a=1" }, .{ .text = "b=2" }, .{ .text = "c=3" }, .{ .text = "\\]" } };
    try cache.remember(alloc, 60, &block, "a=1 b=2 c=3", .bracket);
    const full = [_]Row{ .{ .text = "header" }, block[0], block[1], block[2], block[3], block[4], .{ .text = "input" } };
    try std.testing.expectEqual(@as(usize, 1), (try cache.recover(alloc, 60, &full)).len);
    var tail = [_]Row{ full[0], block[2], block[3], block[4], .{ .text = "" }, .{ .text = "" }, full[6] };
    const matches = try cache.recover(alloc, 60, &tail);
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqual(@as(i32, -1), matches[0].top);
    try std.testing.expectEqual(@as(u16, 1), matches[0].first);
    try std.testing.expectEqual(@as(u16, 4), matches[0].end);
    try std.testing.expectEqual(@as(usize, 1), (try cache.recover(alloc, 60, &tail)).len);
    tail[6].text = "input changed";
    try std.testing.expectEqual(@as(usize, 1), (try cache.recover(alloc, 60, &tail)).len);
    var shrinking = tail;
    shrinking[1] = block[3];
    shrinking[2] = block[4];
    shrinking[3].text = "";
    try std.testing.expectEqual(@as(usize, 1), (try cache.recover(alloc, 60, &shrinking)).len);
    shrinking[1] = block[4];
    shrinking[2].text = "";
    try std.testing.expectEqual(@as(usize, 1), (try cache.recover(alloc, 60, &shrinking)).len);
    _ = try cache.recover(alloc, 60, &tail);
    tail[1].text = "b=changed";
    try std.testing.expectEqual(@as(usize, 0), (try cache.recover(alloc, 60, &tail)).len);
    tail[1] = block[2];
    tail[1].code = true;
    try std.testing.expectEqual(@as(usize, 0), (try cache.recover(alloc, 60, &tail)).len);
    tail[1].code = false;
    tail[1].output = false;
    try std.testing.expectEqual(@as(usize, 0), (try cache.recover(alloc, 60, &tail)).len);
}

test "ghosttex fragment cache rejects ambiguous suffixes and unseen source" {
    const alloc = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(alloc);
    const block = [_]Row{ .{ .text = "\\[" }, .{ .text = "a=1" }, .{ .text = "b=2" }, .{ .text = "c=3" }, .{ .text = "\\]" } };
    const tail = [_]Row{ .{ .text = "header" }, block[2], block[3], block[4], .{ .text = "" }, .{ .text = "" }, .{ .text = "input" } };
    try std.testing.expectEqual(@as(usize, 0), (try cache.recover(alloc, 60, &tail)).len);
    try cache.remember(alloc, 60, &block, "a=1 b=2 c=3", .bracket);
    var other = block;
    other[1].text = "a=9";
    try cache.remember(alloc, 60, &other, "a=9 b=2 c=3", .bracket);
    const full = [_]Row{ tail[0], other[0], other[1], other[2], other[3], other[4], tail[6] };
    _ = try cache.recover(alloc, 60, &full);
    try std.testing.expectEqual(@as(usize, 0), (try cache.recover(alloc, 60, &tail)).len);
}

test "ghosttex fragment cache recovers lower edge and both clipped delimiters" {
    const alloc = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(alloc);
    const block = [_]Row{ .{ .text = "\\[" }, .{ .text = "a=1" }, .{ .text = "b=2" }, .{ .text = "c=3" }, .{ .text = "d=4" }, .{ .text = "e=5" }, .{ .text = "\\]" } };
    try cache.remember(alloc, 60, &block, "a=1 b=2 c=3 d=4 e=5", .bracket);
    const prefix = [_]Row{ .{ .text = "header" }, block[0], block[1], block[2], block[3] };
    var matches = try cache.recover(alloc, 60, &prefix);
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqual(@as(i32, 1), matches[0].top);
    const middle = [_]Row{ block[2], block[3], block[4], block[5] };
    matches = try cache.recover(alloc, 60, &middle);
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqual(@as(i32, -2), matches[0].top);
    cache.clear(alloc);
    try std.testing.expectEqual(@as(usize, 0), (try cache.recover(alloc, 60, &middle)).len);
}

test "ghosttex fragment cache bounds retained source and evicts old blocks" {
    const alloc = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(alloc);
    var buffer: [32]u8 = undefined;
    for (0..40) |i| {
        const body = try std.fmt.bufPrint(&buffer, "x={d}", .{i});
        try cache.remember(alloc, 60, &.{ .{ .text = "\\[" }, .{ .text = body }, .{ .text = "\\]" } }, body, .bracket);
    }
    try std.testing.expectEqual(@as(usize, max_blocks), cache.blocks.items.len);
    try std.testing.expect(cache.bytes <= max_bytes);
    try std.testing.expect(cache.get(1) == null);
    try std.testing.expect(cache.get(40) != null);
    cache.clear(alloc);
    try std.testing.expectEqual(@as(usize, 0), cache.bytes);
}

test "ghosttex changed stationary source cannot salvage its unchanged tail" {
    const alloc = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(alloc);
    const block = [_]Row{ .{ .text = "$$" }, .{ .text = "a=1" }, .{ .text = "b=2" }, .{ .text = "c=3" }, .{ .text = "d=4" }, .{ .text = "e=5" }, .{ .text = "$$" } };
    try cache.remember(alloc, 60, &block, "a=1 b=2 c=3 d=4 e=5", .double_dollar);
    var visible = block;
    try std.testing.expectEqual(@as(usize, 1), (try cache.recover(alloc, 60, &visible)).len);
    visible[1].text = "edited";
    try std.testing.expectEqual(@as(usize, 0), (try cache.recover(alloc, 60, &visible)).len);
}

test "ghosttex continued fraction every scroll position reuses complete source" {
    const alloc = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(alloc);
    const block = [_]Row{
        .{ .text = "\\[" },           .{ .text = "\\varphi" },      .{ .text = "=" },
        .{ .text = "1+\\cfrac{1}{" }, .{ .text = "1+\\cfrac{1}{" }, .{ .text = "1+\\cfrac{1}{1+\\ddots}" },
        .{ .text = "}}" },            .{ .text = "=" },             .{ .text = "\\frac{1+\\sqrt5}{2}" },
        .{ .text = "\\]" },
    };
    try cache.remember(alloc, 60, &block, "continued fraction", .bracket);
    var rows: [24]Row = @splat(.{ .text = "" });
    rows[0].text = "header";
    rows[21].text = "status";
    rows[22].text = "footer";
    rows[23].text = "input";
    for (0..2) |direction| {
        for (0..29) |step| {
            const top = if (direction == 0) @as(i32, 19) - @as(i32, @intCast(step)) else @as(i32, @intCast(step)) - 9;
            for (rows[1..21], 1..) |*row, y| {
                const offset = @as(i32, @intCast(y)) - top;
                row.* = if (offset >= 0 and offset < block.len) block[@intCast(offset)] else .{ .text = "" };
            }
            const first = @max(1, top);
            const end = @min(21, top + @as(i32, @intCast(block.len)));
            const matches = try cache.recover(alloc, 60, &rows);
            if (end - first >= 3) {
                try std.testing.expectEqual(@as(usize, 1), matches.len);
                try std.testing.expectEqual(top, matches[0].top);
                try std.testing.expectEqual(first, matches[0].first);
                try std.testing.expectEqual(end, matches[0].end);
            }
        }
    }
}

test "ghosttex longer exact range disambiguates repeated source lines" {
    const alloc = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(alloc);
    const block = [_]Row{ .{ .text = "\\[" }, .{ .text = "x=" }, .{ .text = "a+" }, .{ .text = "a+" }, .{ .text = "a+" }, .{ .text = "a+" }, .{ .text = "b" }, .{ .text = "\\]" } };
    try cache.remember(alloc, 60, &block, "x=a+a+a+a+b", .bracket);
    const rows = [_]Row{ .{ .text = "header" }, block[0], block[1], block[2], block[3], block[4], block[5], .{ .text = "footer" } };
    const matches = try cache.recover(alloc, 60, &rows);
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqual(@as(i32, 1), matches[0].top);
    try std.testing.expectEqual(@as(u16, 7), matches[0].end);
}

test "ghosttex competing overlapping maximal ranges remain ambiguous" {
    const alloc = std.testing.allocator;
    var cache: Cache = .{};
    defer cache.deinit(alloc);
    const a = [_]Row{ .{ .text = "\\[" }, .{ .text = "a" }, .{ .text = "b" }, .{ .text = "c" }, .{ .text = "d" }, .{ .text = "\\]" } };
    const b = [_]Row{ .{ .text = "\\[" }, .{ .text = "b" }, .{ .text = "c" }, .{ .text = "d" }, .{ .text = "e" }, .{ .text = "\\]" } };
    try cache.remember(alloc, 60, &a, "a b c d", .bracket);
    try cache.remember(alloc, 60, &b, "b c d e", .bracket);
    const rows = [_]Row{ .{ .text = "header" }, a[1], a[2], a[3], a[4], b[4], .{ .text = "footer" } };
    try std.testing.expectEqual(@as(usize, 0), (try cache.recover(alloc, 60, &rows)).len);
}

test "ghosttex complete syntax defeats a partial cached prefix for both block delimiters" {
    const alloc = std.testing.allocator;
    for ([_]scanner.Delimiter{ .bracket, .double_dollar }) |delimiter| {
        var cache: Cache = .{};
        defer cache.deinit(alloc);
        const opening: []const u8 = if (delimiter == .bracket) "\\[" else "$$";
        const closing: []const u8 = if (delimiter == .bracket) "\\]" else "$$";
        const old = [_]Row{ .{ .text = opening }, .{ .text = "\\begin{pmatrix}" }, .{ .text = "a&b\\\\" }, .{ .text = "c&d" }, .{ .text = "\\end{pmatrix}" }, .{ .text = closing } };
        try cache.remember(alloc, 60, &old, "old matrix", delimiter);
        const rows = [_]Row{ .{ .text = "header" }, old[0], old[1], old[2], old[3], .{ .text = "\\end{pmatrix}^{-1}" }, .{ .text = "= new expression" }, old[5], .{ .text = "input" } };
        const matches = try cache.recoverComplete(alloc, 60, &rows, &.{.{ .top = 1, .rows = 7, .delimiter = delimiter }});
        try std.testing.expectEqual(@as(usize, 0), matches.len);
    }
}
