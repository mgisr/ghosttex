//! Project already-shaped glyphs and cell backgrounds into the math layout.
//! Source glyph buffers remain intact for immediate failure/source fallback.
const std = @import("std");
const cell = @import("cell.zig");
const Layout = @import("../math/Layout.zig");

pub fn compose(alloc: std.mem.Allocator, source: *const cell.Contents, target: *cell.Contents, projection: *const Layout.Projection, cell_height: u32, cell_width: u32) !void {
    if (source.size.rows != target.size.rows or source.size.columns != target.size.columns)
        try target.resize(alloc, source.size)
    else
        target.reset();
    const columns = source.size.columns;
    for (source.bg_cells, projection.logical.items, 0..) |color, entry, index| {
        const p = entry orelse continue;
        if (p.formula) continue;
        for (0..p.rows) |dy| {
            const y = p.y + @as(i32, @intCast(dy));
            const limit = if (index / columns >= projection.body_end) projection.rows else projection.body_end;
            if (y >= 0 and y < limit) target.bgCell(@intCast(y), p.x).* = color;
        }
    }
    // Selection and search stay defined on source cells. Carry their color
    // across the replacement image without changing layout or cache keys.
    for (projection.placements.items) |placement| {
        var color: [4]u8 = .{ 0, 0, 0, 0 };
        for (source.bg_cells[placement.first .. placement.last + 1]) |candidate| {
            if (candidate[3] > color[3]) color = candidate;
        }
        if (color[3] == 0) continue;
        color[3] = @min(color[3], 160);
        const top = @max(0, @divFloor(placement.y, @as(i32, @intCast(cell_height))));
        const bottom = @min(projection.body_end, @divFloor(placement.y + @as(i32, @intCast(placement.height)) - 1, @as(i32, @intCast(cell_height))) + 1);
        const left = @divFloor(placement.x, @as(i32, @intCast(cell_width)));
        const right = @min(projection.columns, @divFloor(placement.x + @as(i32, @intCast(placement.width)) - 1, @as(i32, @intCast(cell_width))) + 1);
        var y = top;
        while (y < bottom) : (y += 1) {
            var x = @max(0, left);
            while (x < right) : (x += 1) target.bgCell(@intCast(y), @intCast(x)).* = color;
        }
    }
    for (source.fg_rows, 0..) |row, ri| for (row.items) |glyph| {
        const logical = @as(usize, glyph.grid_pos[1]) * columns + glyph.grid_pos[0];
        if (logical >= projection.logical.items.len) continue;
        const p = projection.logical.items[logical] orelse continue;
        if (p.formula) continue;
        var visual = glyph;
        const original_y: i32 = @intCast(glyph.grid_pos[1]);
        const footer = original_y >= projection.body_end;
        const limit: i32 = @intCast(@as(u32, if (footer) projection.rows else projection.body_end) * cell_height);
        const top = p.y * @as(i32, @intCast(cell_height)) + @as(i32, @intCast(cell_height)) - glyph.bearings[1] + p.baseline_shift;
        const bottom = top + @as(i32, @intCast(glyph.glyph_size[1]));
        const clip_top = @max(top, 0);
        const clip_bottom = @min(bottom, limit);
        if (clip_bottom <= clip_top) continue;
        visual.grid_pos = .{ p.x, @intCast(std.math.clamp(p.y, 0, @as(i32, projection.rows) - 1)) };
        visual.glyph_pos[1] += @intCast(clip_top - top);
        visual.glyph_size[1] = @intCast(clip_bottom - clip_top);
        visual.bearings[1] = @intCast((@as(i32, visual.grid_pos[1]) + 1) * @as(i32, @intCast(cell_height)) - clip_top);
        // Preserve the two cursor drawing lists and their ordering.
        const output_row = if (ri == 0) 0 else if (ri == source.fg_rows.len - 1) target.fg_rows.len - 1 else @as(usize, visual.grid_pos[1]) + 1;
        try target.fg_rows[output_row].append(alloc, visual);
    };
}
