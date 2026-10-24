//! Geometry submitted with a frame, never the renderer's pending layout.
//! Preparation may allocate; commit swaps complete maps without allocation.
const Viewport = @This();
const std = @import("std");
const Layout = @import("Layout.zig");
pub const Point = struct { x: u16, y: u16 };
pub const Request = struct { key: u64 = 0, scroll: ?u32 = null, follow_bottom: bool = false };
pub const WheelOwner = enum { terminal, application };
const Frame = struct {
    positions: std.ArrayList(Layout.Flow.Position) = .empty,
    inverse: std.ArrayList(Point) = .empty,
    assigned: std.ArrayList(bool) = .empty,
    columns: u16 = 0,
    rows: u16 = 0,
    first: u16 = 0,
    end: u16 = 0,
    active: bool = false,
    key: u64 = 0,
    scroll: u32 = 0,
    excess: u32 = 0,
    fn deinit(self: *Frame, alloc: std.mem.Allocator) void {
        self.positions.deinit(alloc);
        self.inverse.deinit(alloc);
        self.assigned.deinit(alloc);
    }
};
mutex: std.Io.Mutex = .init,
frame: Frame = .{},
staging: Frame = .{},
requested: ?u32 = null,

pub fn deinit(self: *Viewport, alloc: std.mem.Allocator) void {
    self.frame.deinit(alloc);
    self.staging.deinit(alloc);
}
/// Renderer-only, serialized by its draw mutex. UI reads only `frame`.
pub fn prepare(self: *Viewport, alloc: std.mem.Allocator, projection: ?*const Layout.Projection, key: u64) !void {
    const frame = &self.staging;
    frame.active = false;
    const p = projection orelse return;
    if (!p.active or !p.flow_active) return;
    try frame.positions.resize(alloc, p.flow.positions.items.len);
    try frame.inverse.resize(alloc, p.flow.positions.items.len);
    try frame.assigned.resize(alloc, p.flow.positions.items.len);
    @memset(frame.assigned.items, false);
    @memcpy(frame.positions.items, p.flow.positions.items);
    frame.columns = p.columns;
    frame.rows = p.rows;
    frame.first = p.flow_first;
    frame.end = p.flow_end;
    frame.key = key;
    frame.scroll = p.flow.scroll;
    frame.excess = p.flow.excess;
    for (frame.inverse.items, 0..) |*point, i| point.* = .{ .x = @intCast(i % p.columns), .y = @intCast(i / p.columns) };
    for (frame.positions.items, 0..) |mapped, i| {
        if (!mapped.valid) continue;
        if (mapped.formula and i + 1 < frame.positions.items.len) {
            const next = frame.positions.items[i + 1];
            if (next.formula and next.x == mapped.x and next.y == mapped.y and next.rows == mapped.rows) continue;
        }
        for (0..mapped.rows) |dy| {
            const y = mapped.y + @as(i32, @intCast(dy));
            const inside = i / p.columns >= frame.first and i / p.columns < frame.end;
            const first: i32 = if (inside) frame.first else 0;
            const end: i32 = if (inside) frame.end else frame.rows;
            if (y < first or y >= end) continue;
            frame.inverse.items[@as(usize, @intCast(y)) * p.columns + mapped.x] = .{ .x = @intCast(i % p.columns), .y = @intCast(i / p.columns) };
            frame.assigned.items[@as(usize, @intCast(y)) * p.columns + mapped.x] = true;
        }
    }
    for (p.flow.images.items) |image| {
        const formula = p.flow_formulas.items[image.index];
        const top = @max(@as(i32, frame.first), @divFloor(image.y, @as(i32, @intCast(p.cell_height))));
        const bottom = @min(@as(i32, frame.end), @divFloor(image.y + @as(i32, @intCast(image.height)) - 1, @as(i32, @intCast(p.cell_height))) + 1);
        const left: usize = @intCast(@divFloor(image.x, @as(i32, @intCast(p.cell_width))));
        const right: usize = @min(frame.columns, @as(usize, @intCast(@divFloor(image.x + @as(i32, @intCast(image.width)) - 1, @as(i32, @intCast(p.cell_width))) + 1)));
        var y = top;
        while (y < bottom) : (y += 1) {
            for (left..right) |x| {
                const index = if ((x - left) * 2 >= right - left) formula.last else formula.first;
                frame.inverse.items[@as(usize, @intCast(y)) * frame.columns + x] = .{ .x = @intCast(index % frame.columns), .y = @intCast(index / frame.columns) };
                frame.assigned.items[@as(usize, @intCast(y)) * frame.columns + x] = true;
            }
        }
    }
    // Dragging into the unused right side of a flowed line selects that
    // line's last source cell, not an unrelated native row underneath it.
    for (0..frame.rows) |y| {
        var previous: ?Point = null;
        for (0..frame.columns) |x| {
            const index = y * frame.columns + x;
            if (frame.assigned.items[index]) previous = frame.inverse.items[index] else if (previous) |point| frame.inverse.items[index] = point;
        }
    }
    frame.active = true;
}
/// Call only after all fallible frame operations succeeded. If drawing aborts,
/// the old frame and its hit map remain paired. No allocation in this step.
pub fn commit(self: *Viewport, io: std.Io) void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    const followed_bottom = (self.requested orelse self.frame.scroll) == self.frame.excess;
    if (!self.staging.active or self.frame.key != self.staging.key or self.requested == self.staging.scroll or
        (followed_bottom and self.staging.scroll == self.staging.excess) or
        (self.requested != null and self.requested.? > self.staging.excess)) self.requested = null;
    std.mem.swap(Frame, &self.frame, &self.staging);
}
pub fn request(self: *Viewport, io: std.Io) Request {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    if (!self.frame.active) return .{};
    const offset = self.requested orelse self.frame.scroll;
    return .{ .key = self.frame.key, .scroll = offset, .follow_bottom = offset == self.frame.excess };
}
pub fn followBottom(self: *Viewport, io: std.Io) void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    if (self.frame.active) self.requested = self.frame.excess;
}
pub fn followTop(self: *Viewport, io: std.Io) void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    if (self.frame.active) self.requested = 0;
}
pub fn hit(self: *Viewport, io: std.Io, x: u16, y: u16) Point {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    const frame = &self.frame;
    if (!frame.active or x >= frame.columns or y >= frame.rows) return .{ .x = x, .y = y };
    return frame.inverse.items[@as(usize, y) * frame.columns + x];
}
pub fn position(self: *Viewport, io: std.Io, x: u16, y: u16) Point {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    const frame = &self.frame;
    if (!frame.active or x >= frame.columns or y >= frame.rows) return .{ .x = x, .y = y };
    const p = frame.positions.items[@as(usize, y) * frame.columns + x];
    if (!p.valid) return .{ .x = x, .y = y };
    return .{ .x = p.x, .y = @intCast(std.math.clamp(p.y + p.rows - 1, 0, @as(i32, frame.rows) - 1)) };
}
/// Consume only visual overflow, leaving native mouse/scroll mode selection
/// unchanged. Native scrolling margins, if set, bound the visual viewport.
pub fn wheel(self: *Viewport, io: std.Io, delta: isize, y: u16, owner: WheelOwner) isize {
    // A program which requested mouse reports or alternate-scroll keys owns
    // those events. Expanding a formula does not revoke that VT contract.
    if (owner == .application) return delta;
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    if (y < self.frame.first or y >= self.frame.end) return delta;
    return self.scrollLocked(delta);
}
pub fn scrollBy(self: *Viewport, io: std.Io, delta: isize) isize {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    return self.scrollLocked(delta);
}
fn scrollLocked(self: *Viewport, delta: isize) isize {
    const frame = &self.frame;
    if (!frame.active or frame.excess == 0) return delta;
    const current: i64 = self.requested orelse frame.scroll;
    const next = std.math.clamp(current - delta, 0, @as(i64, frame.excess));
    const consumed = current - next;
    self.requested = @intCast(next);
    return delta - @as(isize, @intCast(consumed));
}

test "ghosttex viewport publishes complete frames and restores native hits on fallback" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var projection: Layout.Projection = .{};
    defer projection.deinit(a);
    try projection.build(a, .{ .columns = 16, .rows = 5, .cell_width = 8, .cell_height = 16, .regions = &.{.{ .first = 18, .last = 27, .image_id = 1, .width = 17, .height = 35, .left = 2, .right = 12, .top = 1, .source_rows = 1, .display = false }}, .flow = .{ .columns = 16, .rows = &.{ .{ .used = 3, .wrap = false }, .{ .used = 14, .wrap = false }, .{ .used = 5, .wrap = false }, .{ .used = 4, .wrap = false }, .{ .used = 2, .wrap = false } }, .widths = &@as([80]u2, @splat(1)), .cell_width = 8, .cell_height = 16, .first_row = 1, .end_row = 4, .scroll = 0 } });
    var view: Viewport = .{};
    defer view.deinit(a);
    try view.prepare(a, &projection, 42);
    // A pending frame must not change input mapping.
    try std.testing.expectEqual(Point{ .x = 5, .y = 3 }, view.hit(io, 5, 3));
    view.commit(io);
    try std.testing.expectEqual(Point{ .x = 12, .y = 1 }, view.hit(io, 5, 3));
    try std.testing.expectEqual(Point{ .x = 5, .y = 3 }, view.position(io, 12, 1));
    try std.testing.expectEqual(Point{ .x = 13, .y = 1 }, view.hit(io, 14, 3));
    try std.testing.expectEqual(Point{ .x = 2, .y = 1 }, view.hit(io, 2, 2));
    try std.testing.expectEqual(Point{ .x = 11, .y = 1 }, view.hit(io, 4, 2));
    try view.prepare(a, null, 0);
    try std.testing.expectEqual(Point{ .x = 12, .y = 1 }, view.hit(io, 5, 3));
    view.commit(io);
    try std.testing.expectEqual(Point{ .x = 5, .y = 3 }, view.hit(io, 5, 3));
    try std.testing.expectEqual(@as(isize, 4), view.wheel(io, 4, 2, .terminal));
}

test "ghosttex viewport keeps pending wheel requests across an older submitted frame" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var view: Viewport = .{};
    defer view.deinit(a);
    view.frame = .{ .active = true, .columns = 10, .rows = 6, .first = 1, .end = 5, .key = 7, .scroll = 4, .excess = 4 };
    try std.testing.expectEqual(@as(isize, 3), view.wheel(io, 3, 2, .application));
    try std.testing.expectEqual(@as(?u32, 4), view.request(io).scroll);
    try std.testing.expectEqual(@as(isize, 0), view.wheel(io, 1, 2, .terminal));
    view.staging = .{ .active = true, .key = 7, .scroll = 4, .excess = 4, .first = 1, .end = 5 };
    view.commit(io);
    try std.testing.expectEqual(@as(?u32, 3), view.request(io).scroll);
    try std.testing.expectEqual(@as(isize, 2), view.wheel(io, 5, 2, .terminal));
    try std.testing.expectEqual(@as(?u32, 0), view.request(io).scroll);
    try std.testing.expectEqual(@as(isize, -2), view.wheel(io, -6, 2, .terminal));
    try std.testing.expectEqual(@as(?u32, 4), view.request(io).scroll);
    try std.testing.expectEqual(@as(isize, 1), view.wheel(io, 1, 5, .terminal));
}

test "ghosttex viewport follows growing image height and clamps pending pan after shrinking" {
    const io = std.testing.io;
    var view: Viewport = .{};
    view.frame = .{ .active = true, .key = 7, .scroll = 4, .excess = 4, .first = 0, .end = 6 };
    try std.testing.expect(view.request(io).follow_bottom);
    // An asynchronously ready taller image must not leave the cursor below
    // the viewport merely because the previous bottom had a smaller offset.
    view.staging = .{ .active = true, .key = 7, .scroll = 6, .excess = 6, .first = 0, .end = 6 };
    view.commit(io);
    try std.testing.expect(view.request(io).follow_bottom);
    try std.testing.expectEqual(@as(?u32, 6), view.request(io).scroll);
    try std.testing.expectEqual(@as(isize, 0), view.wheel(io, 1, 2, .terminal));
    try std.testing.expect(!view.request(io).follow_bottom);
    view.staging = .{ .active = true, .key = 7, .scroll = 2, .excess = 2, .first = 0, .end = 6 };
    view.commit(io);
    try std.testing.expectEqual(@as(?u32, 2), view.request(io).scroll);
    try std.testing.expectEqual(@as(isize, 0), view.wheel(io, 1, 2, .terminal));
    try std.testing.expectEqual(@as(?u32, 1), view.request(io).scroll);
}
