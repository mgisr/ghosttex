//! Small shared bridge between renderer geometry and UI input. Its lock is
//! independent of terminal and draw locks; callers never retain slices.
const Interaction = @This();
const std = @import("std");
const Layout = @import("Layout.zig");

mutex: std.Io.Mutex = .init,
inverse: std.ArrayList(Layout.Point) = .empty,
forward: std.ArrayList(?Layout.Position) = .empty,
columns: u16 = 0,
rows: u16 = 0,
active: std.atomic.Value(bool) = .init(false),
excess: u32 = 0,
scroll: u32 = 0,
requested: ?u32 = null,
disabled: std.atomic.Value(bool) = .init(false),

pub fn deinit(self: *Interaction, alloc: std.mem.Allocator) void {
    self.inverse.deinit(alloc);
    self.forward.deinit(alloc);
}

pub fn publish(self: *Interaction, alloc: std.mem.Allocator, io: std.Io, projection: ?*const Layout.Projection) !void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    self.active.store(false, .release);
    const p = projection orelse return;
    if (!p.active) return;
    try self.inverse.resize(alloc, p.inverse.items.len);
    try self.forward.resize(alloc, p.logical.items.len);
    @memcpy(self.inverse.items, p.inverse.items);
    @memcpy(self.forward.items, p.logical.items);
    self.columns = p.columns;
    self.rows = p.rows;
    self.excess = p.excess;
    self.scroll = p.scroll;
    self.active.store(true, .release);
}

pub fn hit(self: *Interaction, io: std.Io, x: u16, y: u16) Layout.Point {
    if (!self.active.load(.acquire)) return .{ .x = x, .y = y };
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    if (!self.active.load(.monotonic) or x >= self.columns or y >= self.rows) return .{ .x = x, .y = y };
    return self.inverse.items[@as(usize, y) * self.columns + x];
}

/// Consume the visual part of a wheel delta; return the logical remainder.
pub fn wheel(self: *Interaction, io: std.Io, delta: isize) isize {
    if (!self.active.load(.acquire)) return delta;
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    if (!self.active.load(.monotonic) or self.excess == 0) return delta;
    const current: i64 = self.scroll;
    const next: i64 = std.math.clamp(current - delta, 0, self.excess);
    const consumed = current - next;
    self.requested = @intCast(next);
    self.scroll = @intCast(next);
    return delta - @as(isize, @intCast(consumed));
}

pub fn position(self: *Interaction, io: std.Io, x: u16, y: u16) ?Layout.Position {
    if (!self.active.load(.acquire)) return null;
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    if (!self.active.load(.monotonic) or x >= self.columns or y >= self.rows) return null;
    return self.forward.items[@as(usize, y) * self.columns + x];
}

pub fn requestedScroll(self: *Interaction, io: std.Io) ?u32 {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    return self.requested;
}

pub fn resetScroll(self: *Interaction, io: std.Io) void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    self.requested = null;
}

test "ghosttex interaction consumes visual scrolling and restores raw coordinates" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var projection: Layout.Projection = .{};
    defer projection.deinit(alloc);
    try projection.build(alloc, .{ .columns = 8, .rows = &.{ .{ .used = 6, .wrap = false }, .{ .used = 2, .wrap = false }, .{ .used = 2, .wrap = false }, .{ .used = 4, .wrap = false } }, .widths = &@as([32]u2, @splat(1)), .regions = &.{.{ .first = 0, .last = 5, .image_id = 1, .width = 30, .height = 60, .baseline = 40, .display = true }}, .cell_width = 8, .cell_height = 16, .cell_baseline = 4, .body_end = 3 });
    var interaction: Interaction = .{};
    defer interaction.deinit(alloc);
    try interaction.publish(alloc, io, &projection);
    try std.testing.expectEqual(@as(isize, 0), interaction.wheel(io, 2));
    try std.testing.expectEqual(@as(?u32, 2), interaction.requestedScroll(io));
    try std.testing.expectEqual(@as(isize, 3), interaction.wheel(io, 5));
    try std.testing.expectEqual(@as(?u32, 0), interaction.requestedScroll(io));
    const footer = interaction.position(io, 2, 3).?;
    try std.testing.expectEqual(@as(i32, 3), footer.y);
    try std.testing.expectEqual(Layout.Point{ .x = 2, .y = 3 }, interaction.hit(io, 2, 3));
    try interaction.publish(alloc, io, null);
    try std.testing.expect(interaction.position(io, 0, 0) == null);
    try std.testing.expectEqual(Layout.Point{ .x = 4, .y = 1 }, interaction.hit(io, 4, 1));
    try std.testing.expectEqual(@as(isize, 5), interaction.wheel(io, 5));
}
