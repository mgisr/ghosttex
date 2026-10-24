//! Compose cached formula images and source-shaped glyphs through one visual
//! projection. Logical VT cells remain intact for copy, search, and fallback.
const std = @import("std");
const cell = @import("cell.zig");
const Layout = @import("../math/Layout.zig");

pub fn compose(alloc: std.mem.Allocator, source: *const cell.Contents, target: *cell.Contents, projection: *const Layout.Projection) !void {
    if (source.size.rows != target.size.rows or source.size.columns != target.size.columns)
        try target.resize(alloc, source.size)
    else
        target.reset();
    if (projection.flow_active) return composeFlow(alloc, source, target, projection);
    @memcpy(target.bg_cells, source.bg_cells);
    for (source.fg_rows, 0..) |row, ri| for (row.items) |glyph| {
        const index = @as(usize, glyph.grid_pos[1]) * source.size.columns + glyph.grid_pos[0];
        const cursor = ri == 0 or ri == source.fg_rows.len - 1;
        if (!cursor and index < projection.formula_cells.items.len and projection.formula_cells.items[index]) continue;
        try target.fg_rows[ri].append(alloc, glyph);
    };
}

fn composeFlow(alloc: std.mem.Allocator, source: *const cell.Contents, target: *cell.Contents, projection: *const Layout.Projection) !void {
    const columns = source.size.columns;
    const ch: i32 = @intCast(projection.cell_height);
    // Empty styled padding is a background, not text to wrap. Establish each
    // flowed line's canvas first, then overlay its individual cell colors.
    for (source.bg_cells, projection.flow.positions.items, 0..) |color, p, index| {
        if (!p.valid or p.x != 0) continue;
        const inside = index / columns >= projection.flow_first and index / columns < projection.flow_end;
        const first: i32 = if (inside) projection.flow_first else 0;
        const end: i32 = if (inside) projection.flow_end else projection.rows;
        for (0..p.rows) |dy| {
            const y = p.y + @as(i32, @intCast(dy));
            if (y >= first and y < end) @memset(target.bg_cells[@as(usize, @intCast(y)) * columns ..][0..columns], color);
        }
    }
    for (source.bg_cells, projection.flow.positions.items, 0..) |color, p, index| {
        if (!p.valid or projection.formula_cells.items[index]) continue;
        const inside = index / columns >= projection.flow_first and index / columns < projection.flow_end;
        const first: i32 = if (inside) projection.flow_first else 0;
        const end: i32 = if (inside) projection.flow_end else projection.rows;
        for (0..p.rows) |dy| {
            const y = p.y + @as(i32, @intCast(dy));
            if (y >= first and y < end) target.bgCell(@intCast(y), p.x).* = color;
        }
    }
    // A selection/search highlight belongs to the source span; transfer it
    // to the replacement rectangle without changing the native selection.
    for (projection.placements.items) |placement| {
        var color: [4]u8 = .{ 0, 0, 0, 0 };
        for (source.bg_cells[placement.first .. placement.last + 1]) |candidate| if (candidate[3] > color[3]) {
            color = candidate;
        };
        if (color[3] == 0) continue;
        const top = @max(0, @divFloor(@max(placement.y, placement.clip_top), ch));
        const bottom = @min(projection.rows, @divFloor(@min(placement.y + @as(i32, @intCast(placement.height)), placement.clip_bottom) + ch - 1, ch));
        const left: usize = @intCast(@divFloor(placement.x, @as(i32, @intCast(projection.cell_width))));
        const right = @min(columns, left + (placement.width + projection.cell_width - 1) / projection.cell_width);
        var y = top;
        while (y < bottom) : (y += 1) for (left..right) |x| {
            target.bgCell(@intCast(y), x).* = color;
        };
    }
    for (source.fg_rows, 0..) |row, ri| for (row.items) |glyph| {
        const index = @as(usize, glyph.grid_pos[1]) * columns + glyph.grid_pos[0];
        const p = projection.flow.positions.items[index];
        const cursor = ri == 0 or ri == source.fg_rows.len - 1;
        if (!p.valid or (!cursor and projection.formula_cells.items[index])) continue;
        const inside = index / columns >= projection.flow_first and index / columns < projection.flow_end;
        const first: i32 = @as(i32, if (inside) projection.flow_first else 0) * ch;
        const end: i32 = @as(i32, if (inside) projection.flow_end else projection.rows) * ch;
        const top = (p.y + 1) * ch - glyph.bearings[1] + p.shift;
        const bottom = top + @as(i32, @intCast(glyph.glyph_size[1]));
        const clip_top = @max(first, top);
        const clip_bottom = @min(end, bottom);
        if (clip_bottom <= clip_top) continue;
        var visual = glyph;
        visual.grid_pos = .{ p.x, @intCast(std.math.clamp(p.y + p.rows - 1, 0, @as(i32, projection.rows) - 1)) };
        visual.glyph_pos[1] += @intCast(clip_top - top);
        visual.glyph_size[1] = @intCast(clip_bottom - clip_top);
        visual.bearings[1] = @intCast((@as(i32, visual.grid_pos[1]) + 1) * ch - clip_top);
        const output_row = if (ri == 0) 0 else if (ri == source.fg_rows.len - 1) target.fg_rows.len - 1 else @as(usize, visual.grid_pos[1]) + 1;
        try target.fg_rows[output_row].append(alloc, visual);
    };
}

test "ghosttex renderer preserves every background and all nonformula glyph coordinates" {
    const alloc = std.testing.allocator;
    var projection: Layout.Projection = .{};
    defer projection.deinit(alloc);
    try projection.build(alloc, .{ .columns = 16, .rows = 12, .cell_width = 8, .cell_height = 16, .regions = &.{.{
        .first = 16,
        .last = 31,
        .left = 0,
        .right = 16,
        .top = 1,
        .source_rows = 1,
        .image_id = 1,
        .width = 40,
        .height = 40,
    }} });
    var source: cell.Contents = .{};
    defer source.deinit(alloc);
    try source.resize(alloc, .{ .columns = 16, .rows = 12 });
    for (0..12) |y| {
        for (0..16) |x| source.bgCell(y, x).* = .{ @intCast(y), @intCast(x), 30, 255 };
        try source.add(alloc, .text, .{ .atlas = .grayscale, .grid_pos = .{ 2, @intCast(y) }, .glyph_size = .{ 8, 16 }, .bearings = .{ 0, 16 }, .color = .{ 255, 255, 255, 255 } });
    }
    source.setCursor(source.fg_rows[2].items[0], .bar);
    var target: cell.Contents = .{};
    defer target.deinit(alloc);
    try compose(alloc, &source, &target, &projection);
    try std.testing.expectEqualSlices(@TypeOf(source.bg_cells[0]), source.bg_cells, target.bg_cells);
    for (source.fg_rows, target.fg_rows, 0..) |a, b, index| {
        if (index == 2) try std.testing.expectEqual(@as(usize, 0), b.items.len) else try std.testing.expectEqualSlices(cell.Key.text.CellType(), a.items, b.items);
    }
    try std.testing.expectEqual(source.getCursorGlyph(), target.getCursorGlyph());
}

test "ghosttex dynamic composition bottom aligns text cursor and image with native margin clipping" {
    const a = std.testing.allocator;
    var projection: Layout.Projection = .{};
    defer projection.deinit(a);
    try projection.build(a, .{ .columns = 16, .rows = 6, .cell_width = 8, .cell_height = 16, .regions = &.{.{ .first = 18, .last = 27, .image_id = 1, .width = 17, .height = 35, .left = 2, .right = 12, .top = 1, .source_rows = 1, .display = false }}, .flow = .{ .columns = 16, .rows = &.{ .{ .used = 2, .wrap = false }, .{ .used = 14, .wrap = false }, .{ .used = 5, .wrap = false }, .{ .used = 2, .wrap = false }, .{ .used = 0, .wrap = false }, .{ .used = 3, .wrap = false } }, .widths = &@as([96]u2, @splat(1)), .cell_width = 8, .cell_height = 16, .first_row = 1, .end_row = 5, .scroll = 0 } });
    var source: cell.Contents = .{};
    defer source.deinit(a);
    try source.resize(a, .{ .columns = 16, .rows = 6 });
    for (0..6) |y| {
        for (0..16) |x| source.bgCell(y, x).* = .{ @intCast(y), @intCast(x), 30, 255 };
        try source.add(a, .text, .{ .atlas = .grayscale, .grid_pos = .{ 0, @intCast(y) }, .glyph_size = .{ 8, 16 }, .bearings = .{ 0, 16 }, .color = .{ 255, 255, 255, 255 } });
    }
    try source.add(a, .text, .{ .atlas = .grayscale, .grid_pos = .{ 12, 1 }, .glyph_size = .{ 8, 16 }, .bearings = .{ 0, 16 }, .color = .{ 255, 255, 255, 255 } });
    source.setCursor(source.fg_rows[6].items[0], .bar);
    var target: cell.Contents = .{};
    defer target.deinit(a);
    try compose(a, &source, &target, &projection);
    try std.testing.expectEqualSlices(@TypeOf(source.bg_cells[0]), source.bg_cells[0..16], target.bg_cells[0..16]);
    try std.testing.expectEqualSlices(@TypeOf(source.bg_cells[0]), source.bg_cells[80..96], target.bg_cells[80..96]);
    // No global text-height change, and neither overflow nor cursor geometry
    // paints over the native row outside the declared scrolling margin.
    try std.testing.expectEqualSlices(cell.Key.text.CellType(), source.fg_rows[1].items, target.fg_rows[1].items);
    try std.testing.expectEqualSlices(cell.Key.text.CellType(), source.fg_rows[6].items, target.fg_rows[6].items);
    try std.testing.expectEqual(source.getCursorGlyph(), target.getCursorGlyph());
    try std.testing.expectEqual(@as(usize, 2), target.fg_rows[4].items.len);
    const neighbor = target.fg_rows[4].items[1];
    try std.testing.expectEqual(@as(u16, 5), neighbor.grid_pos[0]);
    try std.testing.expectEqual(@as(u16, 3), neighbor.grid_pos[1]);
    const bottom = (@as(i32, neighbor.grid_pos[1]) + 1) * 16 - neighbor.bearings[1] + @as(i32, @intCast(neighbor.glyph_size[1]));
    const image = projection.placements.items[0];
    try std.testing.expectEqual(image.y + @as(i32, @intCast(image.height)), bottom);
}
