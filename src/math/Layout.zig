//! Immutable VT cells with optional program-independent visual flow. The
//! conservative image-fit path remains available for clipped/unknown contexts.
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Flow = @import("Flow.zig");

pub const Region = struct {
    first: usize,
    last: usize,
    image_id: u64,
    width: u32,
    height: u32,
    left: u16,
    right: u16,
    top: i32,
    source_rows: u32,
    display: bool = true,
    flow_allowed: bool = true,
    clip_first: u16 = 0,
    clip_end: ?u16 = null,
};
pub const Placement = struct {
    image_id: u64,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    source_width: u32,
    source_height: u32,
    clip_top: i32,
    clip_bottom: i32,
    first: usize,
    last: usize,
};
pub const Input = struct {
    columns: u16,
    rows: u16,
    regions: []const Region,
    cell_width: u32,
    cell_height: u32,
    flow: ?Flow.Input = null,
};
pub const Projection = struct {
    formula_cells: std.ArrayList(bool) = .empty,
    placements: std.ArrayList(Placement) = .empty,
    columns: u16 = 0,
    rows: u16 = 0,
    active: bool = false,
    flow_active: bool = false,
    flow: Flow.Result = .{},
    flow_formulas: std.ArrayList(Flow.Formula) = .empty,
    flow_regions: std.ArrayList(usize) = .empty,
    flow_first: u16 = 0,
    flow_end: u16 = 0,
    cell_width: u32 = 0,
    cell_height: u32 = 0,

    pub fn deinit(self: *Projection, alloc: Allocator) void {
        self.formula_cells.deinit(alloc);
        self.placements.deinit(alloc);
        self.flow.deinit(alloc);
        self.flow_formulas.deinit(alloc);
        self.flow_regions.deinit(alloc);
    }

    pub fn build(self: *Projection, alloc: Allocator, input: Input) !void {
        self.active = false;
        self.flow_active = false;
        self.columns = input.columns;
        self.rows = input.rows;
        self.cell_width = input.cell_width;
        self.cell_height = input.cell_height;
        self.placements.clearRetainingCapacity();
        if (input.columns == 0 or input.rows == 0 or input.cell_width == 0 or input.cell_height == 0 or
            input.cell_width > 4096 or input.cell_height > 4096) return error.InvalidGrid;
        const count = @as(usize, input.rows) * input.columns;
        try self.formula_cells.resize(alloc, count);
        @memset(self.formula_cells.items, false);
        var last: ?usize = null;
        for (input.regions) |region| {
            if (region.first > region.last or region.last >= count or
                (last != null and region.first <= last.?) or
                region.left >= region.right or region.right > input.columns or
                region.source_rows == 0 or region.source_rows > 65535 or @abs(@as(i64, region.top)) > 65535 or
                region.clip_first > (region.clip_end orelse input.rows) or (region.clip_end orelse input.rows) > input.rows or
                region.width == 0 or region.height == 0 or region.width > 4096 or region.height > 4096)
                return error.InvalidRegion;
            last = region.last;
            const box_width = @as(u32, region.right - region.left) * input.cell_width;
            const box_height = region.source_rows * input.cell_height;
            const scale = @min(@as(f64, 1), @min(
                @as(f64, @floatFromInt(box_width)) / @as(f64, @floatFromInt(region.width)),
                @as(f64, @floatFromInt(box_height)) / @as(f64, @floatFromInt(region.height)),
            ));
            const width: u32 = @max(1, @as(u32, @intFromFloat(@floor(@as(f64, @floatFromInt(region.width)) * scale))));
            const height: u32 = @max(1, @as(u32, @intFromFloat(@floor(@as(f64, @floatFromInt(region.height)) * scale))));
            try self.placements.append(alloc, .{
                .image_id = region.image_id,
                .x = @intCast(@as(u32, region.left) * input.cell_width + if (region.display) (box_width - width) / 2 else 0),
                .y = region.top * @as(i32, @intCast(input.cell_height)) + @as(i32, @intCast(if (region.display) (box_height - height) / 2 else box_height - height)),
                .width = width,
                .height = height,
                .source_width = region.width,
                .source_height = region.height,
                .clip_top = @intCast(@as(u32, region.clip_first) * input.cell_height),
                .clip_bottom = @intCast(@as(u32, region.clip_end orelse input.rows) * input.cell_height),
                .first = region.first,
                .last = region.last,
            });
            @memset(self.formula_cells.items[region.first .. region.last + 1], true);
        }
        self.active = self.placements.items.len > 0;
        if (input.flow) |native| {
            self.flow_formulas.clearRetainingCapacity();
            self.flow_regions.clearRetainingCapacity();
            for (input.regions, 0..) |region, i| {
                if (region.display or !region.flow_allowed or region.first / input.columns < native.first_row or region.last / input.columns >= native.end_row) continue;
                try self.flow_formulas.append(alloc, .{ .first = region.first, .last = region.last, .width = region.width, .height = region.height });
                try self.flow_regions.append(alloc, i);
            }
            if (self.flow_formulas.items.len == 0) return;
            var options = native;
            options.formulas = self.flow_formulas.items;
            try self.flow.build(alloc, options);
            for (self.placements.items, input.regions) |*placement, region| {
                const row: usize = @intCast(std.math.clamp(region.top, 0, @as(i32, input.rows) - 1));
                const offset = self.flow.offsets.items[row] * @as(i32, @intCast(input.cell_height));
                placement.y += offset;
                placement.clip_top += offset;
                placement.clip_bottom += offset;
                // A same-line display delimiter with adjacent prose is not a
                // centered full-row block. Carry its rectangle with that prose
                // when another inline formula reflows the shared paragraph.
                if (region.display and (region.left != 0 or region.right != input.columns)) {
                    const position = self.flow.positions.items[region.first];
                    if (position.valid) {
                        placement.x = @as(i32, position.x) * @as(i32, @intCast(input.cell_width));
                        placement.y = (position.y + position.rows) * @as(i32, @intCast(input.cell_height)) - @as(i32, @intCast(placement.height));
                    }
                }
                if (row >= native.first_row and row < native.end_row) {
                    placement.clip_top = @max(placement.clip_top, @as(i32, native.first_row) * @as(i32, @intCast(input.cell_height)));
                    placement.clip_bottom = @min(placement.clip_bottom, @as(i32, native.end_row) * @as(i32, @intCast(input.cell_height)));
                }
            }
            for (self.flow.images.items) |image| {
                const placement = &self.placements.items[self.flow_regions.items[image.index]];
                placement.x = image.x;
                placement.y = image.y;
                placement.width = image.width;
                placement.height = image.height;
                placement.clip_top = @as(i32, native.first_row) * @as(i32, @intCast(input.cell_height));
                placement.clip_bottom = @as(i32, native.end_row) * @as(i32, @intCast(input.cell_height));
            }
            self.flow_active = true;
            self.flow_first = native.first_row;
            self.flow_end = native.end_row;
        }
    }
};

test "ghosttex grid layout fits formula without masking neighboring cells" {
    const alloc = std.testing.allocator;
    var p: Projection = .{};
    defer p.deinit(alloc);
    try p.build(alloc, .{ .columns = 20, .rows = 6, .cell_width = 8, .cell_height = 16, .regions = &.{.{
        .first = 23,
        .last = 32,
        .left = 3,
        .right = 13,
        .top = 1,
        .source_rows = 1,
        .image_id = 1,
        .width = 200,
        .height = 40,
    }} });
    try std.testing.expect(p.active);
    const image = p.placements.items[0];
    try std.testing.expectEqual(@as(u32, 80), image.width);
    try std.testing.expectEqual(@as(u32, 16), image.height);
    try std.testing.expectEqual(@as(i32, 24), image.x);
    try std.testing.expectEqual(@as(i32, 16), image.y);
    for (p.formula_cells.items, 0..) |hidden, index| try std.testing.expectEqual(index >= 23 and index <= 32, hidden);
}

test "ghosttex inline math stays at source left and cell bottom with taller line spacing" {
    const alloc = std.testing.allocator;
    var p: Projection = .{};
    defer p.deinit(alloc);
    for ([_]u32{ 20, 32, 40 }) |cell_height| {
        try p.build(alloc, .{ .columns = 40, .rows = 6, .cell_width = 8, .cell_height = cell_height, .regions = &.{.{
            .first = 43,
            .last = 64,
            .left = 3,
            .right = 25,
            .top = 1,
            .source_rows = 1,
            .display = false,
            .image_id = 1,
            .width = 64,
            .height = 24,
        }} });
        const image = p.placements.items[0];
        try std.testing.expectEqual(@as(i32, 24), image.x);
        try std.testing.expectEqual(@as(i32, @intCast(2 * cell_height)), image.y + @as(i32, @intCast(image.height)));
        try std.testing.expect(image.height <= cell_height);
        for (p.formula_cells.items, 0..) |hidden, index| try std.testing.expectEqual(index >= 43 and index <= 64, hidden);
    }
}

test "ghosttex grid block placement follows source rows across viewport clipping" {
    const alloc = std.testing.allocator;
    var p: Projection = .{};
    defer p.deinit(alloc);
    var region: Region = .{ .first = 0, .last = 59, .left = 0, .right = 20, .top = -1, .source_rows = 4, .image_id = 1, .width = 40, .height = 40 };
    var input: Input = .{ .columns = 20, .rows = 6, .cell_width = 8, .cell_height = 16, .regions = &.{region} };
    try p.build(alloc, input);
    const old = p.placements.items[0];
    try std.testing.expectEqual(@as(i32, 60), old.x);
    region.top -= 1;
    region.last -= 20;
    input.regions = &.{region};
    try p.build(alloc, input);
    try std.testing.expectEqual(old.y - 16, p.placements.items[0].y);
    try std.testing.expectEqual(old.height, p.placements.items[0].height);
    input.regions = &.{};
    try p.build(alloc, input);
    try std.testing.expect(!p.active);
    for (p.formula_cells.items) |hidden| try std.testing.expect(!hidden);
}

test "ghosttex adjacent display delimiters follow dynamically reflowed prose" {
    const a = std.testing.allocator;
    var p: Projection = .{};
    defer p.deinit(a);
    try p.build(a, .{ .columns = 32, .rows = 4, .cell_width = 8, .cell_height = 16, .regions = &.{
        .{ .first = 2, .last = 11, .image_id = 1, .width = 17, .height = 35, .left = 2, .right = 12, .top = 0, .source_rows = 1, .display = false },
        .{ .first = 15, .last = 22, .image_id = 2, .width = 32, .height = 12, .left = 15, .right = 23, .top = 0, .source_rows = 1, .display = true },
    }, .flow = .{ .columns = 32, .rows = &.{ .{ .used = 26, .wrap = false }, .{ .used = 0, .wrap = false }, .{ .used = 0, .wrap = false }, .{ .used = 0, .wrap = false } }, .widths = &@as([128]u2, @splat(1)), .cell_width = 8, .cell_height = 16, .end_row = 4, .scroll = 0 } });
    try std.testing.expectEqual(@as(i32, 64), p.placements.items[1].x);
    try std.testing.expectEqual(@as(i32, 48), p.placements.items[1].y + @as(i32, @intCast(p.placements.items[1].height)));
    try std.testing.expectEqual(@as(i32, 48), p.placements.items[0].y + @as(i32, @intCast(p.placements.items[0].height)));
}
