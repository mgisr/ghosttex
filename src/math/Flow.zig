//! Program-independent visual flow over immutable VT cells. Only paragraphs
//! containing inline images are re-typeset. Other rows retain their native
//! height; explicit VT scrolling margins delimit the transform's domain.
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Row = struct { used: u16, wrap: bool, elastic: bool = false };
pub const Position = struct { x: u16, y: i32, rows: u16 = 1, shift: i32 = 0, formula: bool = false, valid: bool = true };
pub const Formula = struct { first: usize, last: usize, width: u32, height: u32 };
pub const Image = struct { index: usize, x: i32, y: i32, width: u32, height: u32 };
pub const Input = struct {
    columns: u16,
    rows: []const Row,
    widths: []const u2,
    formulas: []const Formula = &.{},
    cell_width: u32,
    cell_height: u32,
    first_row: u16 = 0,
    end_row: u16,
    scroll: ?u32 = null,
};
pub const Result = struct {
    positions: std.ArrayList(Position) = .empty,
    images: std.ArrayList(Image) = .empty,
    offsets: std.ArrayList(i32) = .empty,
    excess: u32 = 0,
    scroll: u32 = 0,
    pub fn deinit(self: *Result, alloc: Allocator) void {
        self.positions.deinit(alloc);
        self.images.deinit(alloc);
        self.offsets.deinit(alloc);
    }
    pub fn build(self: *Result, alloc: Allocator, input: Input) !void {
        if (input.columns == 0 or input.rows.len > 65535 or input.cell_width == 0 or input.cell_height == 0 or
            input.first_row >= input.end_row or input.end_row > input.rows.len or input.widths.len != input.rows.len * input.columns)
            return error.InvalidGrid;
        const count = input.widths.len;
        try self.positions.resize(alloc, count);
        try self.offsets.resize(alloc, input.rows.len);
        @memset(self.offsets.items, 0);
        self.images.clearRetainingCapacity();
        self.excess = 0;
        self.scroll = 0;
        for (self.positions.items, 0..) |*p, i| p.* = .{ .x = @intCast(i % input.columns), .y = @intCast(i / input.columns) };
        var previous: ?usize = null;
        for (input.formulas) |formula| {
            if (formula.first > formula.last or formula.last >= count or formula.width == 0 or formula.height == 0 or
                formula.width > 4096 or formula.height > 4096 or (previous != null and formula.first <= previous.?))
                return error.InvalidFormula;
            previous = formula.last;
        }
        var builder: Builder = .{ .result = self, .input = input, .alloc = alloc, .y = input.first_row };
        defer builder.tokens.deinit(alloc);
        var row: usize = input.first_row;
        var formula_index: usize = 0;
        while (row < input.end_row) {
            var end = row + 1;
            while (end < input.end_row and input.rows[end - 1].wrap) : (end += 1) {}
            // An explicit inline delimiter pair also proves that its source
            // continues across these physical rows, even without DECAWM wrap.
            var changed = true;
            while (changed) {
                changed = false;
                for (input.formulas) |formula| {
                    const first = formula.first / input.columns;
                    const last = formula.last / input.columns;
                    if (first < row or first >= end or last >= input.end_row) continue;
                    if (last + 1 > end) {
                        end = last + 1;
                        while (end < input.end_row and input.rows[end - 1].wrap) : (end += 1) {}
                        changed = true;
                    }
                }
            }
            while (formula_index < input.formulas.len and input.formulas[formula_index].first / input.columns < row) : (formula_index += 1) {}
            const has_formula = formula_index < input.formulas.len and input.formulas[formula_index].last / input.columns < end;
            const start_y = builder.y;
            if (has_formula) {
                for (self.positions.items[row * input.columns .. end * input.columns]) |*p| p.valid = false;
                var index = row * input.columns;
                while (index < end * input.columns) {
                    const source_y = index / input.columns;
                    const x = index % input.columns;
                    if (x >= input.rows[source_y].used) {
                        index = (source_y + 1) * input.columns;
                        continue;
                    }
                    if (formula_index < input.formulas.len and input.formulas[formula_index].first == index) {
                        const formula = input.formulas[formula_index];
                        const scale = @min(@as(f64, 1), @as(f64, @floatFromInt(@as(u32, input.columns) * input.cell_width)) / @as(f64, @floatFromInt(formula.width)));
                        const width: u32 = @max(1, @as(u32, @intFromFloat(@floor(@as(f64, @floatFromInt(formula.width)) * scale))));
                        const height: u32 = @max(1, @as(u32, @intFromFloat(@floor(@as(f64, @floatFromInt(formula.height)) * scale))));
                        try builder.append(.{ .first = index, .last = formula.last, .columns = @intCast((width + input.cell_width - 1) / input.cell_width), .image = .{ .index = formula_index, .x = 0, .y = 0, .width = width, .height = height } });
                        index = formula.last + 1;
                        formula_index += 1;
                        continue;
                    }
                    const width = input.widths[index];
                    if (width > 0) try builder.append(.{ .first = index, .last = index + width - 1, .columns = width });
                    index += @max(1, width);
                }
                try builder.flush();
                // Compaction must not pull unrelated hard rows into a former
                // paragraph. Leave any saved height as blank paragraph space.
                builder.y = @max(builder.y, start_y + @as(i32, @intCast(end - row)));
            } else {
                for (row..end) |source_row| {
                    const cells = self.positions.items[source_row * input.columns ..][0..input.columns];
                    // Spend genuinely empty, unstyled rows before creating
                    // visual overflow. Styled padding and cursor cells are not
                    // free space. No application/widget identity is inferred.
                    if (input.rows[source_row].elastic and input.rows[source_row].used == 0 and builder.y > source_row) {
                        for (cells) |*p| p.valid = false;
                    } else {
                        for (cells) |*p| p.y = builder.y;
                        builder.y += 1;
                    }
                    self.offsets.items[source_row] = builder.y - 1 - @as(i32, @intCast(source_row));
                }
            }
            if (has_formula) for (row..end) |i| {
                self.offsets.items[i] = start_y - @as(i32, @intCast(row));
            };
            row = end;
        }
        self.excess = @intCast(builder.y - input.end_row);
        self.scroll = @min(input.scroll orelse self.excess, self.excess);
        const scroll: i32 = @intCast(self.scroll);
        for (self.positions.items[@as(usize, input.first_row) * input.columns .. @as(usize, input.end_row) * input.columns]) |*p| p.y -= scroll;
        for (self.images.items) |*image| image.y -= scroll * @as(i32, @intCast(input.cell_height));
        for (self.offsets.items[input.first_row..input.end_row]) |*offset| offset.* -= scroll;
    }
};
const Token = struct { first: usize, last: usize, columns: u16, image: ?Image = null };
const Builder = struct {
    result: *Result,
    input: Input,
    alloc: Allocator,
    tokens: std.ArrayList(Token) = .empty,
    x: u32 = 0,
    y: i32,
    fn append(self: *Builder, token: Token) !void {
        if (self.x + token.columns > self.input.columns) try self.flush();
        try self.tokens.append(self.alloc, token);
        self.x += token.columns;
    }
    fn flush(self: *Builder) !void {
        if (self.tokens.items.len == 0) return;
        const ch = self.input.cell_height;
        var height: u32 = ch;
        for (self.tokens.items) |token| if (token.image) |image| {
            height = @max(height, image.height);
        };
        const rows: u16 = @intCast((height + ch - 1) / ch);
        const shift: i32 = @intCast((@as(u32, rows) - 1) * ch);
        var x: u16 = 0;
        for (self.tokens.items) |token| {
            if (token.image) |image| {
                var placement = image;
                placement.x = @intCast(@as(u32, x) * self.input.cell_width);
                placement.y = (self.y + rows) * @as(i32, @intCast(ch)) - @as(i32, @intCast(image.height));
                try self.result.images.append(self.alloc, placement);
                for (token.first..token.last + 1) |i| self.result.positions.items[i] = .{ .x = x, .y = self.y, .rows = rows, .formula = true };
            } else {
                for (token.first..token.last + 1, 0..) |i, dx| self.result.positions.items[i] = .{ .x = x + @as(u16, @intCast(dx)), .y = self.y, .rows = rows, .shift = shift };
            }
            x += token.columns;
        }
        self.y += rows;
        self.x = 0;
        self.tokens.clearRetainingCapacity();
    }
};

test "ghosttex dynamic inline height and horizontal compaction only affect formula paragraph" {
    const a = std.testing.allocator;
    var flow: Result = .{};
    defer flow.deinit(a);
    const rows = [_]Row{ .{ .used = 3, .wrap = false }, .{ .used = 14, .wrap = false }, .{ .used = 5, .wrap = false }, .{ .used = 4, .wrap = false }, .{ .used = 2, .wrap = false } };
    try flow.build(a, .{ .columns = 16, .rows = &rows, .widths = &@as([80]u2, @splat(1)), .formulas = &.{.{ .first = 18, .last = 27, .width = 17, .height = 35 }}, .cell_width = 8, .cell_height = 16, .first_row = 1, .end_row = 4, .scroll = 0 });
    try std.testing.expectEqual(@as(u32, 2), flow.excess);
    // Only the visual line containing the tall image grows to three rows.
    try std.testing.expectEqual(@as(u16, 3), flow.positions.items[16].rows);
    try std.testing.expectEqual(@as(i32, 32), flow.positions.items[16].shift);
    try std.testing.expectEqual(@as(u16, 5), flow.positions.items[28].x);
    try std.testing.expectEqual(@as(u16, 1), flow.positions.items[32].rows);
    try std.testing.expectEqual(@as(i32, 4), flow.positions.items[32].y);
    try std.testing.expectEqual(@as(i32, 0), flow.positions.items[0].y);
    try std.testing.expectEqual(@as(i32, 4), flow.positions.items[64].y);
    try std.testing.expectEqual(@as(u32, 35), flow.images.items[0].height);
    try std.testing.expectEqual(@as(i32, 64), flow.images.items[0].y + 35);
}

test "ghosttex dynamic bottom anchor and bidirectional visual scroll leave native margins fixed" {
    const a = std.testing.allocator;
    var flow: Result = .{};
    defer flow.deinit(a);
    var options: Input = .{ .columns = 12, .rows = &.{ .{ .used = 4, .wrap = false }, .{ .used = 12, .wrap = false }, .{ .used = 5, .wrap = false }, .{ .used = 2, .wrap = false } }, .widths = &@as([48]u2, @splat(1)), .formulas = &.{.{ .first = 13, .last = 21, .width = 30, .height = 45 }}, .cell_width = 8, .cell_height = 16, .first_row = 1, .end_row = 3 };
    try flow.build(a, options);
    try std.testing.expectEqual(@as(u32, 2), flow.excess);
    try std.testing.expectEqual(@as(u32, 2), flow.scroll);
    try std.testing.expectEqual(@as(i32, 2), flow.positions.items[24].y);
    try std.testing.expectEqual(@as(i32, 3), flow.positions.items[36].y);
    const image_y = flow.images.items[0].y;
    for ([_]u32{ 1, 0, 1, 2 }) |scroll| {
        options.scroll = scroll;
        try flow.build(a, options);
        try std.testing.expectEqual(image_y + @as(i32, @intCast(2 - scroll)) * 16, flow.images.items[0].y);
        try std.testing.expectEqual(@as(i32, 3), flow.positions.items[36].y);
    }
}

test "ghosttex dynamic mixed wide text and wrapped formula use natural dimensions" {
    const a = std.testing.allocator;
    var flow: Result = .{};
    defer flow.deinit(a);
    var widths: [48]u2 = @splat(1);
    widths[0] = 2;
    widths[1] = 0;
    try flow.build(a, .{ .columns = 12, .rows = &.{ .{ .used = 12, .wrap = true }, .{ .used = 8, .wrap = false }, .{ .used = 5, .wrap = false }, .{ .used = 0, .wrap = false } }, .widths = &widths, .formulas = &.{.{ .first = 4, .last = 15, .width = 24, .height = 23 }}, .cell_width = 8, .cell_height = 16, .end_row = 4 });
    try std.testing.expectEqual(@as(u16, 7), flow.positions.items[16].x);
    try std.testing.expectEqual(@as(i32, 0), flow.positions.items[16].y);
    try std.testing.expectEqual(@as(u32, 23), flow.images.items[0].height);
    try std.testing.expectEqual(@as(u32, 0), flow.excess);
    try std.testing.expectEqual(@as(i32, 2), flow.positions.items[24].y);
    try std.testing.expectEqual(@as(u16, 1), flow.positions.items[24].rows);
}

test "ghosttex dynamic expansion uses empty rows without moving ordinary text or native edges" {
    const a = std.testing.allocator;
    var flow: Result = .{};
    defer flow.deinit(a);
    try flow.build(a, .{ .columns = 16, .rows = &.{ .{ .used = 4, .wrap = false }, .{ .used = 14, .wrap = false }, .{ .used = 0, .wrap = false, .elastic = true }, .{ .used = 0, .wrap = false, .elastic = true }, .{ .used = 6, .wrap = false }, .{ .used = 3, .wrap = false } }, .widths = &@as([96]u2, @splat(1)), .formulas = &.{.{ .first = 18, .last = 27, .width = 17, .height = 35 }}, .cell_width = 8, .cell_height = 16, .end_row = 6 });
    try std.testing.expectEqual(@as(u32, 0), flow.excess);
    try std.testing.expectEqual(@as(i32, 0), flow.positions.items[0].y);
    try std.testing.expectEqual(@as(i32, 4), flow.positions.items[64].y);
    try std.testing.expectEqual(@as(i32, 5), flow.positions.items[80].y);
    try std.testing.expectEqual(@as(u16, 3), flow.positions.items[16].rows);
    try std.testing.expect(!flow.positions.items[32].valid);
    try std.testing.expect(!flow.positions.items[48].valid);
}
