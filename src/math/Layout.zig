//! Visual projection over an unchanged logical grid. Visual space is quantized
//! to terminal columns and whole rows; baselines retain pixel precision.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Point = struct { x: u16, y: u16 };
pub const Position = struct {
    x: u16,
    y: i32,
    rows: u16,
    baseline_shift: i16 = 0,
    formula: bool = false,
};
pub const Row = struct { used: u16, wrap: bool };
pub const Region = struct {
    first: usize,
    last: usize,
    image_id: u64,
    width: u32,
    height: u32,
    baseline: f32,
    display: bool,
    source_y: u32 = 0,
    clipped_bottom: bool = false,
};
pub const Placement = struct {
    image_id: u64,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    first: usize,
    last: usize,
    source_y: u32 = 0,
};
pub const Input = struct {
    columns: u16,
    rows: []const Row,
    /// Per-cell widths: spacer=0, ordinary=1, wide=2.
    widths: []const u2,
    regions: []const Region,
    cell_width: u32,
    cell_height: u32,
    cell_baseline: u32,
    /// Exclusive end of the reflowable body. Everything below stays fixed.
    body_end: u16,
    /// null follows the bottom. An explicit offset is clamped to the body.
    scroll: ?u32 = null,
};

pub const Projection = struct {
    logical: std.ArrayList(?Position) = .empty,
    inverse: std.ArrayList(Point) = .empty,
    placements: std.ArrayList(Placement) = .empty,
    columns: u16 = 0,
    rows: u16 = 0,
    body_end: u16 = 0,
    excess: u32 = 0,
    scroll: u32 = 0,
    active: bool = false,

    pub fn deinit(self: *Projection, alloc: Allocator) void {
        self.logical.deinit(alloc);
        self.inverse.deinit(alloc);
        self.placements.deinit(alloc);
    }

    pub fn hit(self: *const Projection, x: u16, y: u16) Point {
        if (!self.active or x >= self.columns or y >= self.rows) return .{ .x = x, .y = y };
        return self.inverse.items[@as(usize, y) * self.columns + x];
    }

    pub fn build(self: *Projection, alloc: Allocator, input: Input) !void {
        self.active = false;
        self.columns = input.columns;
        self.rows = @intCast(input.rows.len);
        self.body_end = input.body_end;
        self.placements.clearRetainingCapacity();
        if (input.columns == 0 or input.cell_width == 0 or input.cell_height == 0 or
            input.cell_baseline > input.cell_height or input.body_end > input.rows.len or
            input.widths.len != input.rows.len * input.columns)
            return error.InvalidGrid;
        const count = input.rows.len * input.columns;
        try self.logical.resize(alloc, count);
        try self.inverse.resize(alloc, count);
        @memset(self.logical.items, null);
        for (self.inverse.items, 0..) |*p, index| p.* = point(index, input.columns);
        if (input.regions.len == 0 or input.body_end == 0) return;
        var last_end: ?usize = null;
        for (input.regions) |region| {
            if (region.first > region.last or region.last >= @as(usize, input.body_end) * input.columns or
                region.width == 0 or region.height == 0 or region.height > 4096 or
                region.width > @as(u32, input.columns) * input.cell_width or
                !std.math.isFinite(region.baseline) or region.baseline < 0 or
                region.baseline > @as(f32, @floatFromInt(region.height)) or
                (last_end != null and region.first <= last_end.?)) return error.InvalidRegion;
            last_end = region.last;
        }
        var builder: Builder = .{ .projection = self, .input = input, .alloc = alloc };
        defer builder.tokens.deinit(alloc);
        var index: usize = 0;
        var region_index: usize = 0;
        var suppress_break = false;
        var content_end: usize = input.body_end;
        while (content_end > 0 and input.rows[content_end - 1].used == 0) : (content_end -= 1) {}
        const body_count = content_end * input.columns;
        while (index < body_count) {
            const y = index / input.columns;
            const x = index % input.columns;
            if (x >= input.rows[y].used) {
                if (!input.rows[y].wrap) {
                    if (!suppress_break or builder.tokens.items.len > 0) try builder.flush(true);
                    suppress_break = false;
                }
                index = (y + 1) * input.columns;
                continue;
            }
            if (region_index < input.regions.len and input.regions[region_index].first == index) {
                const region = input.regions[region_index];
                if (region.display and builder.tokens.items.len > 0) try builder.flush(false);
                const width: u16 = @intCast(std.math.divCeil(u32, region.width, input.cell_width) catch unreachable);
                try builder.append(.{ .first = index, .last = region.last, .width = width, .region = region });
                if (region.display) {
                    try builder.flush(false);
                    suppress_break = true;
                }
                index = region.last + 1;
                region_index += 1;
                continue;
            }
            const width = input.widths[index];
            if (width == 0) {
                index += 1;
                continue;
            }
            if (width > input.columns or x + width > input.columns) return error.InvalidGrid;
            try builder.append(.{ .first = index, .last = index + width - 1, .width = width });
            suppress_break = false;
            index += width;
        }
        try builder.flush(false);
        self.excess = builder.y -| input.body_end;
        self.scroll = @min(input.scroll orelse self.excess, self.excess);
        // Move only the body. Footer rows retain their application coordinates.
        for (self.logical.items[0..body_count]) |*entry| if (entry.*) |*p| {
            p.y -= @intCast(self.scroll);
        };
        for (self.placements.items) |*placement| placement.y -= @intCast(self.scroll * input.cell_height);
        for (@as(usize, input.body_end) * input.columns..count) |i| {
            const p = point(i, input.columns);
            self.logical.items[i] = .{ .x = p.x, .y = p.y, .rows = 1 };
        }
        // Inverse hit rectangles include the extra height, while source still
        // has only the original logical cells. This also covers wide text.
        for (self.logical.items[0..body_count], 0..) |entry, i| {
            const p = entry orelse continue;
            if (p.formula) continue;
            const logical = point(i, input.columns);
            for (0..p.rows) |dy| {
                const vy = p.y + @as(i32, @intCast(dy));
                if (vy < 0 or vy >= input.body_end) continue;
                self.inverse.items[@as(usize, @intCast(vy)) * input.columns + p.x] = logical;
            }
        }
        for (self.placements.items) |placement| {
            const top = @divFloor(placement.y, @as(i32, @intCast(input.cell_height)));
            const bottom = @divFloor(placement.y + @as(i32, @intCast(placement.height)) - 1, @as(i32, @intCast(input.cell_height)));
            const left = @divFloor(placement.x, @as(i32, @intCast(input.cell_width)));
            const right = @divFloor(placement.x + @as(i32, @intCast(placement.width)) - 1, @as(i32, @intCast(input.cell_width)));
            var vy = @max(0, top);
            while (vy <= bottom and vy < input.body_end) : (vy += 1) {
                var vx = @max(0, left);
                while (vx <= right and vx < input.columns) : (vx += 1) {
                    const end_half = (vy - top) * 2 > bottom - top or (vx - left) * 2 > right - left;
                    self.inverse.items[@as(usize, @intCast(vy)) * input.columns + @as(usize, @intCast(vx))] =
                        point(if (end_half) placement.last else placement.first, input.columns);
                }
            }
        }
        self.active = true;
    }
};

const Token = struct { first: usize, last: usize, width: u16, region: ?Region = null };
const Builder = struct {
    projection: *Projection,
    input: Input,
    alloc: Allocator,
    tokens: std.ArrayList(Token) = .empty,
    x: u16 = 0,
    y: u32 = 0,

    fn append(self: *Builder, token: Token) !void {
        if (@as(u32, self.x) + token.width > self.input.columns) try self.flush(false);
        try self.tokens.append(self.alloc, token);
        self.x += token.width;
    }

    fn flush(self: *Builder, empty: bool) !void {
        if (self.tokens.items.len == 0) {
            if (empty) self.y += 1;
            return;
        }
        const ch = self.input.cell_height;
        const text_ascent = ch - self.input.cell_baseline;
        var ascent: f32 = @floatFromInt(text_ascent);
        var descent: f32 = @floatFromInt(self.input.cell_baseline);
        for (self.tokens.items) |token| if (token.region) |region| {
            const padding: f32 = if (region.display) @as(f32, @floatFromInt(ch)) / 2 else 0;
            ascent = @max(ascent, region.baseline + if (region.source_y > 0) @as(f32, 0) else padding);
            descent = @max(descent, @as(f32, @floatFromInt(region.height)) - region.baseline + if (region.clipped_bottom) @as(f32, 0) else padding);
        };
        const rows: u16 = @intFromFloat(@ceil((ascent + descent) / @as(f32, @floatFromInt(ch))));
        var x: u16 = 0;
        for (self.tokens.items) |token| {
            if (token.region) |region| {
                try self.projection.placements.append(self.alloc, .{
                    .image_id = region.image_id,
                    .x = @intCast(@as(u32, x) * self.input.cell_width),
                    .y = @as(i32, @intCast(self.y * ch)) + @as(i32, @intFromFloat(@round(ascent - region.baseline))),
                    .width = region.width,
                    .height = region.height,
                    .first = region.first,
                    .last = region.last,
                    .source_y = region.source_y,
                });
                for (token.first..token.last + 1) |i| self.projection.logical.items[i] = .{
                    .x = x,
                    .y = @intCast(self.y),
                    .rows = rows,
                    .formula = true,
                };
            } else {
                for (token.first..token.last + 1, 0..) |i, dx| self.projection.logical.items[i] = .{
                    .x = x + @as(u16, @intCast(dx)),
                    .y = @intCast(self.y),
                    .rows = rows,
                    .baseline_shift = @intFromFloat(@round(ascent - @as(f32, @floatFromInt(text_ascent)))),
                };
            }
            x += token.width;
        }
        self.y += rows;
        self.x = 0;
        self.tokens.clearRetainingCapacity();
    }
};

fn point(index: usize, columns: u16) Point {
    return .{ .x = @intCast(index % columns), .y = @intCast(index / columns) };
}

test "ghosttex layout block expands body and fixes footer" {
    var projection: Projection = .{};
    defer projection.deinit(std.testing.allocator);
    const rows = [_]Row{ .{ .used = 4, .wrap = false }, .{ .used = 8, .wrap = false }, .{ .used = 4, .wrap = false }, .{ .used = 3, .wrap = false }, .{ .used = 3, .wrap = false }, .{ .used = 5, .wrap = false } };
    try projection.build(std.testing.allocator, .{ .columns = 10, .rows = &rows, .widths = &@as([60]u2, @splat(1)), .regions = &.{.{ .first = 10, .last = 17, .image_id = 1, .width = 35, .height = 38, .baseline = 28, .display = true }}, .cell_width = 8, .cell_height = 16, .cell_baseline = 4, .body_end = 5, .scroll = 0 });
    try std.testing.expect(projection.active);
    try std.testing.expectEqual(@as(u32, 3), projection.excess);
    try std.testing.expectEqual(@as(i32, 5), projection.logical.items[20].?.y);
    try std.testing.expectEqual(@as(i32, 5), projection.logical.items[50].?.y);
    try std.testing.expectEqual(Point{ .x = 0, .y = 1 }, projection.hit(0, 1));
    try std.testing.expectEqual(Point{ .x = 4, .y = 5 }, projection.hit(4, 5));
}

test "ghosttex layout inline compaction baseline and inverse" {
    var projection: Projection = .{};
    defer projection.deinit(std.testing.allocator);
    try projection.build(std.testing.allocator, .{ .columns = 16, .rows = &.{ .{ .used = 15, .wrap = false }, .{ .used = 0, .wrap = false }, .{ .used = 0, .wrap = false }, .{ .used = 0, .wrap = false } }, .widths = &@as([64]u2, @splat(1)), .regions = &.{.{ .first = 2, .last = 11, .image_id = 7, .width = 17, .height = 30, .baseline = 22, .display = false }}, .cell_width = 8, .cell_height = 16, .cell_baseline = 4, .body_end = 4, .scroll = 0 });
    try std.testing.expectEqual(@as(u16, 5), projection.logical.items[12].?.x);
    try std.testing.expectEqual(@as(i16, 10), projection.logical.items[0].?.baseline_shift);
    try std.testing.expectEqual(Point{ .x = 12, .y = 0 }, projection.hit(5, 1));
    try std.testing.expectEqual(Point{ .x = 2, .y = 0 }, projection.hit(2, 0));
    try std.testing.expectEqual(Point{ .x = 11, .y = 0 }, projection.hit(4, 1));
}

test "ghosttex layout rejects overlapping regions and restores raw view" {
    var projection: Projection = .{};
    defer projection.deinit(std.testing.allocator);
    var input: Input = .{ .columns = 8, .rows = &.{.{ .used = 8, .wrap = false }}, .widths = &@as([8]u2, @splat(1)), .regions = &.{ .{ .first = 0, .last = 5, .image_id = 1, .width = 8, .height = 16, .baseline = 12, .display = false }, .{ .first = 5, .last = 7, .image_id = 2, .width = 8, .height = 16, .baseline = 12, .display = false } }, .cell_width = 8, .cell_height = 16, .cell_baseline = 4, .body_end = 1 };
    try std.testing.expectError(error.InvalidRegion, projection.build(std.testing.allocator, input));
    try std.testing.expect(!projection.active);
    input.regions = &.{};
    try projection.build(std.testing.allocator, input);
    try std.testing.expectEqual(Point{ .x = 4, .y = 0 }, projection.hit(4, 0));
}
