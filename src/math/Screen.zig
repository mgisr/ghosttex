//! Renderer-owned math state. Reads only copied RenderState rows; never retains
//! untracked PageList pointers or reaches back into a live terminal.
const Screen = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("../terminal/main.zig");
const scanner = terminal.markdown_math;
const Native = @import("Native.zig");
pub const Layout = @import("Layout.zig");

const ByteCell = struct { x: u16, y: i32, output: bool = true };
const Candidate = struct {
    formula: scanner.Formula,
    first: usize,
    last: usize,
    source_rows: u32,
    clipped_top: u32,
    clipped_bottom: u32,
};
pub const Ready = struct { id: u64, image: Native.Image };

worker: ?Native.Worker = null,
source: std.ArrayList(u8) = .empty,
byte_cells: std.ArrayList(ByteCell) = .empty,
row_offsets: std.ArrayList(struct { offset: usize, id: terminal.RenderState.Row.Id }) = .empty,
checkpoints: std.ArrayList(scanner.Checkpoint) = .empty,
boundaries: std.ArrayList(usize) = .empty,
contexts: std.AutoHashMapUnmanaged(terminal.RenderState.Row.Id, scanner.Checkpoint) = .empty,
rows: std.ArrayList(Layout.Row) = .empty,
widths: std.ArrayList(u2) = .empty,
candidates: std.ArrayList(Candidate) = .empty,
regions: std.ArrayList(Layout.Region) = .empty,
ready: std.ArrayList(Ready) = .empty,
projection: Layout.Projection = .{},
snapshot_valid: bool = false,
last_body: u16 = 0,
last_output: u16 = 0,
epoch: usize = 0,
formatted_codex: bool = false,

pub const Parameters = struct {
    enabled: bool,
    single_dollar: bool,
    raw_output: bool = false,
    include_below: bool = false,
    history_start: bool,
    epoch: usize,
    body_end: u16,
    output_end: u16,
    cell_width: u32,
    cell_height: u32,
    cell_baseline: u32,
    font_px: f32,
    foreground: [4]u8,
    scroll: ?u32,
};

pub fn deinit(self: *Screen, alloc: Allocator) void {
    if (self.worker) |*worker| worker.deinit();
    for (self.ready.items) |*ready| ready.image.deinit();
    self.ready.deinit(alloc);
    self.source.deinit(alloc);
    self.byte_cells.deinit(alloc);
    self.row_offsets.deinit(alloc);
    self.checkpoints.deinit(alloc);
    self.boundaries.deinit(alloc);
    self.contexts.deinit(alloc);
    self.rows.deinit(alloc);
    self.widths.deinit(alloc);
    self.candidates.deinit(alloc);
    self.regions.deinit(alloc);
    self.projection.deinit(alloc);
}

pub fn update(self: *Screen, alloc: Allocator, state: *const terminal.RenderState, params: Parameters) !void {
    self.projection.active = false;
    for (self.ready.items) |*ready| ready.image.deinit();
    self.ready.clearRetainingCapacity();
    self.regions.clearRetainingCapacity();
    if (!params.enabled) {
        if (self.worker) |*worker| worker.deinit();
        self.worker = null;
        self.snapshot_valid = false;
        return;
    }
    if (self.epoch != params.epoch) {
        self.contexts.clearRetainingCapacity();
        self.snapshot_valid = false;
        self.epoch = params.epoch;
        self.formatted_codex = false;
    }
    const worker = if (self.worker) |*worker| worker else return;
    worker.begin();
    defer worker.finish();
    if (!self.snapshot_valid or state.dirty != .false or self.last_body != params.body_end or self.last_output != params.output_end) {
        self.snapshot_valid = false;
        self.last_body = params.body_end;
        self.last_output = params.output_end;
        try self.capture(alloc, state, params);
        self.snapshot_valid = true;
    }
    for (self.candidates.items) |candidate| {
        var ticket: u64 = 0;
        const image = worker.request(candidate.formula.body.slice(self.source.items), .{
            .font_px = params.font_px,
            .max_width = @min(@as(u32, state.cols) * params.cell_width, 4096),
            .display = candidate.formula.delimiter.display(),
            .color = params.foreground,
        }, &ticket) orelse continue;
        var owned = image;
        errdefer owned.deinit();
        const top = @as(u64, image.raw.height) * candidate.clipped_top / candidate.source_rows;
        const bottom = @as(u64, image.raw.height) * candidate.clipped_bottom / candidate.source_rows;
        const height: u32 = @intCast(image.raw.height - top - bottom);
        if (height == 0) {
            owned.deinit();
            continue;
        }
        try self.ready.ensureUnusedCapacity(alloc, 1);
        try self.regions.append(alloc, .{
            .first = candidate.first,
            .last = candidate.last,
            .image_id = ticket,
            .width = image.raw.width,
            .height = height,
            .baseline = std.math.clamp(image.raw.baseline - @as(f32, @floatFromInt(top)), 0, @as(f32, @floatFromInt(height))),
            .display = candidate.formula.delimiter.display(),
            .source_y = @intCast(top),
            .clipped_bottom = candidate.clipped_bottom > 0,
        });
        self.ready.appendAssumeCapacity(.{ .id = ticket, .image = image });
    }
    try self.projection.build(alloc, .{ .columns = state.cols, .rows = self.rows.items, .widths = self.widths.items, .regions = self.regions.items, .body_end = params.body_end, .cell_width = params.cell_width, .cell_height = params.cell_height, .cell_baseline = params.cell_baseline, .scroll = params.scroll });
}

fn capture(self: *Screen, alloc: Allocator, state: *const terminal.RenderState, params: Parameters) !void {
    self.source.clearRetainingCapacity();
    self.byte_cells.clearRetainingCapacity();
    self.candidates.clearRetainingCapacity();
    self.row_offsets.clearRetainingCapacity();
    self.boundaries.clearRetainingCapacity();
    try self.rows.resize(alloc, state.rows);
    try self.widths.resize(alloc, @as(usize, state.rows) * state.cols);
    @memset(self.widths.items, 1);
    const data = state.row_data.slice();
    const cells = data.items(.cells);
    const raw = data.items(.raw);
    const range = state.rowDataRange();
    var first: ?usize = if (params.history_start) range.start else null;
    var context: scanner.Checkpoint = .{};
    if (first == null) for (range.start..state.viewportStart() + 1) |i| {
        if (self.contexts.get(state.row_data.get(i).id())) |saved| {
            first = i;
            context = saved;
            break;
        }
    };
    // Even when syntax context is missing, initialize the logical layout so
    // the raw view remains usable. Unknown context never enables recognition.
    for (0..state.rows) |y| {
        const i = state.viewportStart() + y;
        const raw_cells = cells[i].items(.raw);
        var used: usize = if (raw[i].wrap) state.cols else raw_cells.len;
        if (!raw[i].wrap) while (used > 0 and raw_cells[used - 1].codepoint() == 0 and
            !raw_cells[used - 1].hasStyling()) : (used -= 1)
        {};
        self.rows.items[y] = .{ .used = @intCast(used), .wrap = raw[i].wrap };
        if (state.cursor.viewport) |cursor| if (cursor.y == y) {
            self.rows.items[y].used = @max(self.rows.items[y].used, cursor.x + 1);
        };
        for (raw_cells, 0..) |cell, x| self.widths.items[y * state.cols + x] = switch (cell.wide) {
            .wide => 2,
            .spacer_head, .spacer_tail => 0,
            else => 1,
        };
    }
    const start = first orelse return;
    const end = if (params.include_below) state.rowDataRange().end else state.viewportStart() + params.output_end;
    var previous_input = false;
    for (start..end) |i| {
        try self.row_offsets.append(alloc, .{ .offset = self.source.items.len, .id = state.row_data.get(i).id() });
        const slice = cells[i].slice();
        const raw_cells = slice.items(.raw);
        const graphemes = slice.items(.grapheme);
        var has_input = false;
        var has_output = false;
        for (raw_cells) |cell| if (cell.codepoint() != 0) {
            if (cell.semantic_content == .output) has_output = true else has_input = true;
        };
        if (!raw[i].wrap_continuation and (raw[i].semantic_prompt == .prompt or (previous_input and has_output)))
            try self.boundaries.append(alloc, self.source.items.len);
        if (has_input or has_output) previous_input = has_input;
        var used: usize = raw_cells.len;
        if (!raw[i].wrap) while (used > 0 and raw_cells[used - 1].codepoint() == 0 and
            !raw_cells[used - 1].hasStyling()) : (used -= 1)
        {};
        for (raw_cells[0..used], 0..) |cell, x| {
            if (cell.wide == .spacer_head or cell.wide == .spacer_tail) continue;
            const point: ByteCell = .{ .x = @intCast(x), .y = @intCast(state.viewportY(i)), .output = cell.semantic_content == .output };
            try self.appendCodepoint(alloc, if (cell.codepoint() == 0) ' ' else cell.codepoint(), point);
            if (cell.content_tag == .codepoint_grapheme) for (graphemes[x]) |cp| {
                try self.appendCodepoint(alloc, cp, point);
            };
        }
        if (!raw[i].wrap) try self.appendCodepoint(alloc, '\n', .{ .x = @intCast(used -| 1), .y = @intCast(state.viewportY(i)) });
    }
    if (@import("builtin").os.tag == .linux and
        std.mem.indexOf(u8, self.source.items, "OpenAI Codex (v0.163.0)") != null and !self.formatted_codex)
    {
        self.formatted_codex = true;
        std.log.info("native math: formatted Codex output requires a raw Markdown adapter", .{});
    }
    if (self.formatted_codex and !params.raw_output) return;
    try self.checkpoints.resize(alloc, end - start + 1);
    var iterator: scanner.Iterator = .init(self.source.items, .{ .single_dollar = params.single_dollar });
    context.restore(&iterator);
    iterator.checkpoints = self.checkpoints.items;
    iterator.boundaries = self.boundaries.items;
    while (iterator.next()) |formula| {
        const a = self.byte_cells.items[formula.source.start];
        const b = self.byte_cells.items[formula.source.end - 1];
        if (params.output_end == 0 or b.y < 0 or a.y >= params.output_end) continue;
        if ((a.y < 0 or b.y >= params.output_end) and !formula.delimiter.display()) continue;
        var output_only = true;
        for (self.byte_cells.items[formula.source.start..formula.source.end]) |cell| if (!cell.output) {
            output_only = false;
            break;
        };
        if (!output_only) continue;
        if (self.candidates.items.len == 512) break;
        try self.candidates.append(alloc, .{
            .formula = formula,
            .first = if (a.y < 0) 0 else @as(usize, @intCast(a.y)) * state.cols + a.x,
            .last = if (b.y >= params.output_end) @as(usize, params.output_end) * state.cols - 1 else @as(usize, @intCast(b.y)) * state.cols + b.x,
            .source_rows = @intCast(b.y - a.y + 1),
            .clipped_top = @intCast(@max(-a.y, 0)),
            .clipped_bottom = @intCast(@max(b.y - @as(i32, params.output_end) + 1, 0)),
        });
    }
    // History is immutable to ordinary CUP/erase operations. Reflow/structural
    // changes renew row ids, so a checkpoint cannot match a rearranged row.
    if (self.contexts.count() > 4096) self.contexts.clearRetainingCapacity();
    var row_index: usize = 0;
    for (self.checkpoints.items[0..iterator.checkpoint_count]) |checkpoint| {
        while (row_index < self.row_offsets.items.len and self.row_offsets.items[row_index].offset < checkpoint.offset) : (row_index += 1) {}
        if (row_index < self.row_offsets.items.len and self.row_offsets.items[row_index].offset == checkpoint.offset)
            try self.contexts.put(alloc, self.row_offsets.items[row_index].id, checkpoint);
    }
}

fn appendCodepoint(self: *Screen, alloc: Allocator, cp: u21, point: ByteCell) !void {
    var buffer: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &buffer) catch return;
    if (self.source.items.len + len > 256 * 1024) return error.SnapshotTooLarge;
    try self.source.appendSlice(alloc, buffer[0..len]);
    try self.byte_cells.appendNTimes(alloc, point, len);
}

test "ghosttex screen native results preserve VT source and clear lifecycle" {
    if (comptime !Native.available) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var t = try terminal.Terminal.init(std.testing.io, alloc, .{ .cols = 60, .rows = 16 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("Inline \\(x^2\\) tail\r\n\\[\\frac{a}{b}\\]\r\n> ```tex\r\n> \\(hidden\\)\r\n> ```\r\ninput: ");
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    state.overscan_request.above = 8;
    try state.update(alloc, &t);
    var math_screen: Screen = .{};
    defer math_screen.deinit(alloc);
    math_screen.worker = try Native.Worker.init(null, null);
    const parameters: Parameters = .{ .enabled = true, .single_dollar = false, .history_start = true, .epoch = 0, .body_end = 13, .output_end = 5, .cell_width = 9, .cell_height = 20, .cell_baseline = 5, .font_px = 20, .foreground = .{ 255, 255, 255, 255 }, .scroll = null };
    for (0..200) |_| {
        try math_screen.update(alloc, &state, parameters);
        if (math_screen.ready.items.len == 2) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
    }
    try std.testing.expectEqual(@as(usize, 2), math_screen.candidates.items.len);
    try std.testing.expectEqual(@as(usize, 2), math_screen.ready.items.len);
    try std.testing.expect(math_screen.projection.active);
    const renders = math_screen.worker.?.stats().renders;
    try math_screen.update(alloc, &state, parameters);
    try std.testing.expectEqual(renders, math_screen.worker.?.stats().renders);
    var original: std.Io.Writer.Allocating = .init(alloc);
    defer original.deinit();
    const formatter: terminal.formatter.ScreenFormatter = .init(t.screens.active, .{ .emit = .plain, .unwrap = true });
    try formatter.format(&original.writer);
    try std.testing.expect(std.mem.indexOf(u8, original.writer.buffered(), "\\(x^2\\)") != null);
    stream.nextSlice("\x1b[2J\x1b[Hplain output\r\ninput: ");
    try state.update(alloc, &t);
    try math_screen.update(alloc, &state, parameters);
    try std.testing.expect(!math_screen.projection.active);
    try std.testing.expectEqual(@as(usize, 0), math_screen.ready.items.len);
    try std.testing.expectEqual(@as(usize, 0), math_screen.candidates.items.len);
}

test "ghosttex screen partial blocks reuse the full cached image while scrolling" {
    if (comptime !Native.available) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var t = try terminal.Terminal.init(std.testing.io, alloc, .{ .cols = 60, .rows = 4 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("before\r\nprefix\r\n$$\r\n\\frac{x}{y}\r\n$$\r\nafter\r\nlast\r\ninput");
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    state.overscan_request = .{ .above = 8, .below = 8 };
    try state.update(alloc, &t);
    var screen: Screen = .{};
    defer screen.deinit(alloc);
    screen.worker = try Native.Worker.init(null, null);
    var params: Parameters = .{ .enabled = true, .single_dollar = false, .history_start = true, .epoch = 0, .body_end = 4, .output_end = 3, .cell_width = 9, .cell_height = 20, .cell_baseline = 5, .font_px = 20, .foreground = .{ 255, 255, 255, 255 }, .scroll = null };
    for (0..200) |_| {
        try screen.update(alloc, &state, params);
        if (screen.ready.items.len == 1) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
    }
    try std.testing.expectEqual(@as(usize, 1), screen.ready.items.len);
    try std.testing.expect(screen.regions.items[0].source_y > 0);
    try std.testing.expect(screen.regions.items[0].height < screen.ready.items[0].image.raw.height);
    const ticket = screen.ready.items[0].id;
    const renders = screen.worker.?.stats().renders;

    // At the top, the closing delimiter is below the viewport. Capture it
    // through overscan, then crop the same texture at the bottom.
    t.scrollViewport(.top);
    try state.update(alloc, &t);
    params.output_end = 4;
    params.include_below = true;
    try screen.update(alloc, &state, params);
    try std.testing.expectEqual(@as(usize, 1), screen.ready.items.len);
    try std.testing.expectEqual(@as(u32, 0), screen.regions.items[0].source_y);
    try std.testing.expect(screen.regions.items[0].clipped_bottom);
    try std.testing.expectEqual(ticket, screen.ready.items[0].id);

    // Showing the entire source range reuses the complete original image.
    t.scrollViewport(.{ .row = 1 });
    try state.update(alloc, &t);
    try screen.update(alloc, &state, params);
    try std.testing.expectEqual(@as(usize, 1), screen.ready.items.len);
    try std.testing.expect(!screen.regions.items[0].clipped_bottom);
    try std.testing.expectEqual(screen.ready.items[0].image.raw.height, screen.regions.items[0].height);
    try std.testing.expectEqual(ticket, screen.ready.items[0].id);
    try std.testing.expectEqual(renders, screen.worker.?.stats().renders);
}

test "ghosttex screen guards verified Codex output and excludes marked input" {
    const alloc = std.testing.allocator;
    var t = try terminal.Terminal.init(std.testing.io, alloc, .{ .cols = 60, .rows = 12 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("OpenAI Codex (v0.163.0)\r\nInline code: \\(not math\\)\r\ninput: ");
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    var screen: Screen = .{};
    defer screen.deinit(alloc);
    var params: Parameters = .{ .enabled = true, .single_dollar = false, .history_start = true, .epoch = 0, .body_end = 12, .output_end = 2, .cell_width = 9, .cell_height = 20, .cell_baseline = 5, .font_px = 20, .foreground = .{ 255, 255, 255, 255 }, .scroll = null };
    try screen.capture(alloc, &state, params);
    if (comptime @import("builtin").os.tag == .linux) {
        try std.testing.expect(screen.formatted_codex);
        try std.testing.expectEqual(@as(usize, 0), screen.candidates.items.len);
    }
    stream.nextSlice("\x1b[2J\x1b[H\x1b]133;A\x1b\\> \x1b]133;B\x1b\\\\(input\\) `\r\n\x1b]133;C\x1b\\\\(output\\)\r\n\x1b]133;A\x1b\\> \x1b]133;B\x1b\\");
    try state.update(alloc, &t);
    params.raw_output = true;
    try screen.capture(alloc, &state, params);
    try std.testing.expectEqual(@as(usize, 1), screen.candidates.items.len);
    try std.testing.expectEqualStrings("output", screen.candidates.items[0].formula.body.slice(screen.source.items));
}
