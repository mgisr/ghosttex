//! Renderer-owned math state. Reads only copied RenderState rows; never retains
//! untracked PageList pointers or reaches back into a live terminal.
const Screen = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("../terminal/main.zig");
const scanner = terminal.markdown_math;
const Native = @import("Native.zig");
const Flow = Layout.Flow;
const Fragments = @import("Fragments.zig");
pub const Layout = @import("Layout.zig");

const ByteCell = struct { x: u16, y: i32, output: bool = true };
const Candidate = struct {
    formula: scanner.Formula,
    first: usize,
    last: usize,
    source_rows: u32,
    top: i32,
    left: u16,
    right: u16,
    owned_body: ?[]u8 = null,
    clip_first: u16 = 0,
    clip_end: ?u16 = null,
    flow_allowed: bool = true,
};
const Prefetch = struct { formula: scanner.Formula, distance: u32 };
const prefetch_limit = 8;
pub const Ready = struct { id: u64, image: Native.Image };

worker: ?Native.Worker = null,
source: std.ArrayList(u8) = .empty,
byte_cells: std.ArrayList(ByteCell) = .empty,
row_offsets: std.ArrayList(struct { offset: usize, id: terminal.RenderState.Row.Id }) = .empty,
checkpoints: std.ArrayList(scanner.Checkpoint) = .empty,
boundaries: std.ArrayList(usize) = .empty,
contexts: std.AutoHashMapUnmanaged(terminal.RenderState.Row.Id, scanner.Checkpoint) = .empty,
candidates: std.ArrayList(Candidate) = .empty,
prefetch: std.ArrayList(Prefetch) = .empty,
regions: std.ArrayList(Layout.Region) = .empty,
ready: std.ArrayList(Ready) = .empty,
projection: Layout.Projection = .{},
snapshot_valid: bool = false,
cursor_row: ?u16 = null,
columns: u16 = 0,
fragments: Fragments = .{},
fragment_rows: std.ArrayList(Fragments.Row) = .empty,
epoch: usize = 0,
screen: terminal.ScreenSet.Key = .primary,
flow_rows: std.ArrayList(Flow.Row) = .empty,
flow_widths: std.ArrayList(u2) = .empty,
flow_key: u64 = 0,

pub const Parameters = struct {
    enabled: bool,
    single_dollar: bool,
    history_start: bool,
    epoch: usize,
    screen: terminal.ScreenSet.Key = .primary,
    history_end: u32 = 0,
    cell_width: u32,
    cell_height: u32,
    font_px: f32,
    foreground: [4]u8,
    dynamic: bool = false,
    flow_first: u16 = 0,
    flow_end: ?u16 = null,
    flow_scroll: ?u32 = null,
    flow_key: u64 = 0,
    flow_follow_bottom: bool = true,
    preedit_width: u16 = 0,
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
    self.clearCandidates(alloc);
    self.candidates.deinit(alloc);
    self.fragments.deinit(alloc);
    self.fragment_rows.deinit(alloc);
    self.prefetch.deinit(alloc);
    self.regions.deinit(alloc);
    self.projection.deinit(alloc);
    self.flow_rows.deinit(alloc);
    self.flow_widths.deinit(alloc);
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
        self.fragments.clear(alloc);
        self.clearCandidates(alloc);
        return;
    }
    if (self.epoch != params.epoch or self.screen != params.screen or self.columns != state.cols) {
        self.contexts.clearRetainingCapacity();
        self.fragments.clear(alloc);
        self.columns = state.cols;
        self.snapshot_valid = false;
        self.epoch = params.epoch;
        self.screen = params.screen;
    }
    const worker = if (self.worker) |*worker| worker else return;
    worker.begin();
    defer worker.finish();
    const cursor_row = if (state.cursor.viewport) |cursor| cursor.y else null;
    if (!self.snapshot_valid or state.dirty != .false or self.cursor_row != cursor_row) {
        self.snapshot_valid = false;
        self.cursor_row = cursor_row;
        try self.capture(alloc, state, params);
        self.snapshot_valid = true;
    }
    const request_params: Native.Parameters = .{
        .font_px = params.font_px,
        .max_width = @min(@as(u32, state.cols) * params.cell_width, 4096),
        .display = false,
        .color = params.foreground,
    };
    var pending_inline: std.ArrayList(usize) = .empty;
    defer pending_inline.deinit(alloc);
    for (self.candidates.items, 0..) |candidate, candidate_index| {
        var ticket: u64 = 0;
        var options = request_params;
        options.display = candidate.formula.delimiter.display();
        const image = worker.request(candidate.owned_body orelse candidate.formula.body.slice(self.source.items), options, &ticket) orelse {
            if (!options.display) try pending_inline.append(alloc, candidate_index);
            continue;
        };
        var owned = image;
        errdefer owned.deinit();
        try self.ready.ensureUnusedCapacity(alloc, 1);
        try self.regions.append(alloc, .{
            .first = candidate.first,
            .last = candidate.last,
            .image_id = ticket,
            .width = image.raw.width,
            .height = image.raw.height,
            .left = candidate.left,
            .right = candidate.right,
            .top = candidate.top,
            .source_rows = candidate.source_rows,
            .display = candidate.formula.delimiter.display(),
            .flow_allowed = candidate.flow_allowed,
            .clip_first = candidate.clip_first,
            .clip_end = candidate.clip_end,
        });
        self.ready.appendAssumeCapacity(.{ .id = ticket, .image = image });
    }
    // Queue visible work first. Warm only the nearest few offscreen formulas
    // so scrolling can reuse their images without an intervening raw layout.
    for (self.prefetch.items) |entry| {
        var ticket: u64 = 0;
        var options = request_params;
        options.display = entry.formula.delimiter.display();
        if (worker.request(entry.formula.body.slice(self.source.items), options, &ticket)) |image| {
            var owned = image;
            owned.deinit();
        }
    }
    var flow: ?Flow.Input = null;
    if (params.dynamic) {
        try self.flow_rows.resize(alloc, state.rows);
        try self.flow_widths.resize(alloc, @as(usize, state.rows) * state.cols);
        const data = state.row_data.slice();
        for (0..state.rows) |y| {
            const native_row = state.viewportStart() + y;
            const raw = data.items(.cells)[native_row].slice().items(.raw);
            var used: usize = raw.len;
            while (used > 0 and raw[used - 1].codepoint() == 0) : (used -= 1) {}
            if (state.cursor.viewport) |cursor| if (cursor.y == y) {
                used = @max(used, @min(state.cols, @as(usize, cursor.x) + @max(1, params.preedit_width)));
            };
            var elastic = used == 0;
            for (raw) |cell| if (cell.hasStyling()) {
                elastic = false;
                break;
            };
            self.flow_rows.items[y] = .{ .used = @intCast(used), .wrap = data.items(.raw)[native_row].wrap, .elastic = elastic };
            for (raw, 0..) |cell, x| self.flow_widths.items[y * state.cols + x] = switch (cell.wide) {
                .spacer_head, .spacer_tail => 0,
                .wide => 2,
                else => 1,
            };
        }
        // Commit complete paragraphs, rather than moving neighbors again for
        // each asynchronously ready formula. A rejected formula affects only
        // its own paragraph, never unrelated output elsewhere in the screen.
        var region_index: usize = 0;
        while (region_index < self.regions.items.len) {
            const region = self.regions.items[region_index];
            if (region.display) {
                region_index += 1;
                continue;
            }
            var first = region.first / state.cols;
            var end = region.last / state.cols + 1;
            var changed = true;
            while (changed) {
                const old_first = first;
                const old_end = end;
                while (first > 0 and self.flow_rows.items[first - 1].wrap) : (first -= 1) {}
                while (end < state.rows and self.flow_rows.items[end - 1].wrap) : (end += 1) {}
                for (self.candidates.items) |candidate| {
                    if (candidate.formula.delimiter.display() or candidate.first / state.cols >= end or candidate.last / state.cols < first) continue;
                    first = @min(first, candidate.first / state.cols);
                    end = @max(end, candidate.last / state.cols + 1);
                }
                changed = first != old_first or end != old_end;
            }
            var incomplete = false;
            for (pending_inline.items) |index| {
                const candidate = self.candidates.items[index];
                if (candidate.first / state.cols < end and candidate.last / state.cols >= first) {
                    incomplete = true;
                    break;
                }
            }
            if (incomplete) _ = self.regions.orderedRemove(region_index) else region_index += 1;
        }
        var hash = std.hash.Wyhash.init(params.epoch ^ @backingInt(params.screen));
        hash.update(std.mem.asBytes(&state.cols));
        hash.update(std.mem.asBytes(&state.rows));
        hash.update(std.mem.asBytes(&params.cell_width));
        hash.update(std.mem.asBytes(&params.cell_height));
        hash.update(std.mem.asBytes(&params.flow_first));
        const flow_end = params.flow_end orelse state.rows;
        hash.update(std.mem.asBytes(&flow_end));
        hash.update(self.source.items);
        self.flow_key = hash.final();
        flow = .{ .columns = state.cols, .rows = self.flow_rows.items, .widths = self.flow_widths.items, .cell_width = params.cell_width, .cell_height = params.cell_height, .first_row = params.flow_first, .end_row = params.flow_end orelse state.rows, .scroll = if (self.flow_key == params.flow_key) params.flow_scroll else if (params.flow_follow_bottom) null else 0 };
    }
    try self.projection.build(alloc, .{ .columns = state.cols, .rows = state.rows, .regions = self.regions.items, .cell_width = params.cell_width, .cell_height = params.cell_height, .flow = flow });
}

fn clearCandidates(self: *Screen, alloc: Allocator) void {
    for (self.candidates.items) |candidate| if (candidate.owned_body) |body| alloc.free(body);
    self.candidates.clearRetainingCapacity();
}

fn capture(self: *Screen, alloc: Allocator, state: *const terminal.RenderState, params: Parameters) !void {
    self.source.clearRetainingCapacity();
    self.byte_cells.clearRetainingCapacity();
    self.clearCandidates(alloc);
    self.prefetch.clearRetainingCapacity();
    self.row_offsets.clearRetainingCapacity();
    self.boundaries.clearRetainingCapacity();
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
    const start = first orelse return;
    const end = state.rowDataRange().end;
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
    try self.checkpoints.resize(alloc, end - start + 1);
    var iterator: scanner.Iterator = .init(self.source.items, .{ .single_dollar = params.single_dollar, .multiline_paren = true });
    context.restore(&iterator);
    iterator.checkpoints = self.checkpoints.items;
    iterator.boundaries = self.boundaries.items;
    // Establish explicit code context first. Known fragments must be resolved
    // before parsing formulas, since a clipped closing $$ is otherwise an
    // apparent opening delimiter and can swallow the next complete block.
    var complete: std.ArrayList(Fragments.Complete) = .empty;
    defer complete.deinit(alloc);
    while (iterator.next()) |formula| {
        if (!formula.delimiter.display()) continue;
        const a = self.byte_cells.items[formula.source.start];
        const b = self.byte_cells.items[formula.source.end - 1];
        if (a.y == b.y or b.y < 0 or a.y >= state.rows) continue;
        try complete.append(alloc, .{ .top = a.y, .rows = @intCast(b.y - a.y + 1), .delimiter = formula.delimiter });
    }
    // Capture per-row provenance after scanning, so explicit code and marked
    // input cannot be recovered as a cached display formula.
    try self.fragment_rows.resize(alloc, self.row_offsets.items.len);
    var cp: usize = 0;
    for (self.row_offsets.items, 0..) |row, i| {
        const limit = if (i + 1 < self.row_offsets.items.len) self.row_offsets.items[i + 1].offset else self.source.items.len;
        while (cp + 1 < iterator.checkpoint_count and self.checkpoints.items[cp + 1].offset <= row.offset) : (cp += 1) {}
        const checkpoint: scanner.Checkpoint = if (iterator.checkpoint_count > 0) self.checkpoints.items[cp] else .{};
        var output = true;
        for (self.byte_cells.items[row.offset..limit]) |cell| if (!cell.output) {
            output = false;
            break;
        };
        self.fragment_rows.items[i] = .{ .text = std.mem.trimEnd(u8, self.source.items[row.offset..limit], " \t\r\n"), .output = output, .code = checkpoint.code_ticks != 0 or checkpoint.fence_len != 0 };
    }
    const visible = self.fragment_rows.items[state.viewportStart() - start ..][0..state.rows];
    const matches = try self.fragments.recoverComplete(alloc, state.cols, visible, complete.items);
    var exclusions: std.ArrayList(scanner.Range) = .empty;
    defer exclusions.deinit(alloc);
    for (matches) |match| {
        const first_row = state.viewportStart() - start + match.first;
        const end_row = state.viewportStart() - start + match.end;
        try exclusions.append(alloc, .{
            .start = self.row_offsets.items[first_row].offset,
            .end = if (end_row < self.row_offsets.items.len) self.row_offsets.items[end_row].offset else self.source.items.len,
        });
    }
    std.mem.sort(scanner.Range, exclusions.items, {}, struct {
        fn less(_: void, a: scanner.Range, b: scanner.Range) bool {
            return a.start < b.start;
        }
    }.less);
    iterator = .init(self.source.items, .{ .single_dollar = params.single_dollar, .multiline_paren = true });
    context.restore(&iterator);
    iterator.checkpoints = self.checkpoints.items;
    iterator.boundaries = self.boundaries.items;
    iterator.exclusions = exclusions.items;
    while (iterator.next()) |formula| {
        const a = self.byte_cells.items[formula.source.start];
        const b = self.byte_cells.items[formula.source.end - 1];
        var output_only = true;
        for (self.byte_cells.items[formula.source.start..formula.source.end]) |cell| if (!cell.output) {
            output_only = false;
            break;
        };
        if (!output_only) continue;
        if (b.y < 0 or a.y >= state.rows) {
            const distance: u32 = @intCast(if (b.y < 0) -b.y else a.y - @as(i32, state.rows) + 1);
            var at: usize = 0;
            while (at < self.prefetch.items.len and self.prefetch.items[at].distance <= distance) : (at += 1) {}
            if (at == prefetch_limit) continue;
            if (self.prefetch.items.len == prefetch_limit) _ = self.prefetch.pop();
            try self.prefetch.insert(alloc, at, .{ .formula = formula, .distance = distance });
            continue;
        }
        // Keep the editing row in source form, regardless of which program
        // owns it. Do not obscure the cursor or infer an input region.
        if (state.cursor.viewport) |cursor| if (cursor.y >= a.y and cursor.y <= b.y) continue;
        const multiline = a.y != b.y;
        var isolated = false;
        if (formula.delimiter.display()) {
            // Full-row centering is safe only when delimiters have no adjacent
            // text. Preserve other content on the opening/closing rows.
            isolated = true;
            var edge = formula.source.start;
            while (edge > 0 and self.byte_cells.items[edge - 1].y == a.y) {
                edge -= 1;
                if (self.source.items[edge] > ' ') isolated = false;
            }
            edge = formula.source.end;
            while (edge < self.source.items.len and self.byte_cells.items[edge].y == b.y) : (edge += 1) {
                if (self.source.items[edge] > ' ') isolated = false;
            }
        }
        if (multiline and formula.delimiter.display() and !isolated) continue;
        if (self.candidates.items.len == 512) break;
        // Inline TeX can wrap in the native grid. Mask its complete linear
        // source span, but fit the image into one source-owned row segment.
        // Choose using the full formula, independent of viewport clipping;
        // neighboring text and terminal coordinates must never be moved.
        var top = a.y;
        var left = if (isolated) @as(u16, 0) else a.x;
        var right = if (isolated) state.cols else b.x + 1;
        var rows: u32 = @intCast(b.y - a.y + 1);
        var body: ?[]u8 = null;
        if (multiline and !formula.delimiter.display()) {
            right = state.cols;
            rows = 1;
            const last_width = b.x + 1;
            if (b.y - a.y > 1 or last_width > right - left) {
                top = a.y + 1;
                left = 0;
                right = if (b.y - a.y > 1) state.cols else last_width;
            }
            // A program may wrap with explicit cursor positioning instead of
            // the terminal's soft-wrap flag, including inside a TeX command.
            // Remove only breaks at a full physical row. Genuine short-line
            // TeX whitespace is retained, including inside \\text{...}.
            var joined: std.ArrayList(u8) = .empty;
            defer joined.deinit(alloc);
            for (formula.body.start..formula.body.end) |offset| {
                if (self.source.items[offset] == '\n' and self.byte_cells.items[offset].x + 1 == state.cols) continue;
                try joined.append(alloc, self.source.items[offset]);
            }
            body = try joined.toOwnedSlice(alloc);
        }
        errdefer if (body) |owned| alloc.free(owned);
        try self.candidates.append(alloc, .{
            .formula = formula,
            .first = if (a.y < 0) 0 else @as(usize, @intCast(a.y)) * state.cols + a.x,
            .last = if (b.y >= state.rows) @as(usize, state.rows) * state.cols - 1 else @as(usize, @intCast(b.y)) * state.cols + b.x,
            .source_rows = rows,
            .top = top,
            .left = left,
            .right = right,
            .owned_body = body,
            .flow_allowed = a.y >= 0 and b.y < state.rows,
        });
    }
    for (self.candidates.items) |candidate| {
        if (!candidate.formula.delimiter.display() or candidate.source_rows < 3 or candidate.left != 0 or candidate.right != state.cols) continue;
        const row = @as(i32, @intCast(state.viewportStart() - start)) + candidate.top;
        if (row < 0 or @as(usize, @intCast(row)) + candidate.source_rows > self.fragment_rows.items.len) continue;
        try self.fragments.remember(alloc, state.cols, self.fragment_rows.items[@intCast(row)..][0..candidate.source_rows], candidate.formula.body.slice(self.source.items), candidate.formula.delimiter);
    }
    for (matches) |match| {
        if (state.cursor.viewport) |cursor| if (cursor.y >= match.first and cursor.y < match.end) continue;
        const first_cell = @as(usize, match.first) * state.cols;
        const last_cell = @as(usize, match.end) * state.cols - 1;
        var overlap = false;
        for (self.candidates.items) |candidate| if (candidate.first <= last_cell and first_cell <= candidate.last) {
            overlap = true;
            break;
        };
        if (overlap) continue;
        const block = self.fragments.get(match.id) orelse continue;
        const body = try alloc.dupe(u8, block.body);
        errdefer alloc.free(body);
        try self.candidates.append(alloc, .{
            .formula = .{ .source = .{ .start = 0, .end = 0 }, .body = .{ .start = 0, .end = 0 }, .delimiter = block.delimiter },
            .first = first_cell,
            .last = last_cell,
            .source_rows = @intCast(block.lines.len),
            .top = match.top,
            .left = 0,
            .right = state.cols,
            .owned_body = body,
            .clip_first = match.first,
            .clip_end = match.end,
        });
    }
    std.mem.sort(Candidate, self.candidates.items, {}, struct {
        fn less(_: void, a: Candidate, b: Candidate) bool {
            return a.first < b.first;
        }
    }.less);
    // History is immutable to ordinary CUP/erase operations. Reflow/structural
    // changes renew row ids, so a checkpoint cannot match a rearranged row.
    if (self.contexts.count() > 4096) self.contexts.clearRetainingCapacity();
    var row_index: usize = 0;
    for (self.checkpoints.items[0..iterator.checkpoint_count]) |checkpoint| {
        while (row_index < self.row_offsets.items.len and self.row_offsets.items[row_index].offset < checkpoint.offset) : (row_index += 1) {}
        if (row_index < self.row_offsets.items.len and self.row_offsets.items[row_index].offset == checkpoint.offset and
            state.viewportY(start + row_index) < params.history_end)
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
fn testParameters(state: *const terminal.RenderState) Parameters {
    return .{ .enabled = true, .single_dollar = false, .history_start = true, .epoch = 0, .screen = state.screen, .cell_width = 9, .cell_height = 20, .font_px = 20, .foreground = .{ 255, 255, 255, 255 } };
}

fn waitForImages(screen: *Screen, state: *const terminal.RenderState, expected: usize) !void {
    return waitForImagesWithParameters(screen, state, expected, testParameters(state));
}

fn waitForImagesWithParameters(screen: *Screen, state: *const terminal.RenderState, expected: usize, params: Parameters) !void {
    for (0..300) |_| {
        try screen.update(std.testing.allocator, state, params);
        if (screen.ready.items.len == expected) return;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
    }
    try std.testing.expectEqual(expected, screen.ready.items.len);
}

test "ghosttex dynamic rapid bidirectional scroll preserves VT margins cursor modes and cached images" {
    if (comptime !Native.available) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const Viewport = @import("Viewport.zig");
    for ([_]bool{ false, true }) |alternate| {
        var t = try terminal.Terminal.init(std.testing.io, alloc, .{ .cols = 120, .rows = 24 });
        defer t.deinit(alloc);
        var stream = t.vtStream();
        defer stream.deinit();
        if (alternate) stream.nextSlice("\x1b[?1049h");
        for (3..20) |row| {
            var buffer: [64]u8 = undefined;
            stream.nextSlice(try std.fmt.bufPrint(&buffer, "\x1b[{d};1Hbody row", .{row + 1}));
        }
        stream.nextSlice("\x1b[?1003h\x1b[?1006h\x1b[?2004h\x1b[4;20r\x1b[Hnative header\x1b[4;1Hprefix \\(\\begin{pmatrix}1&2\\\\3&4\\end{pmatrix}\\) tail\x1b[5;1Hplain row\x1b[8;1Hsecond \\(\\frac{1}{1+x}\\) after\x1b[21;1Hnative fixed row\x1b[23;1Hinput: ");
        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);
        var before: std.Io.Writer.Allocating = .init(alloc);
        defer before.deinit();
        const formatter: terminal.formatter.ScreenFormatter = .init(t.screens.active, .{ .emit = .vt, .unwrap = false });
        try formatter.format(&before.writer);
        var screen: Screen = .{};
        defer screen.deinit(alloc);
        screen.worker = try Native.Worker.init(null, null);
        var params = testParameters(&state);
        params.dynamic = true;
        params.flow_first = 3;
        params.flow_end = 20;
        try waitForImagesWithParameters(&screen, &state, 2, params);
        const ids = [_]u64{ screen.regions.items[0].image_id, screen.regions.items[1].image_id };
        const renders = screen.worker.?.stats().renders;
        var view: Viewport = .{};
        defer view.deinit(alloc);
        try view.prepare(alloc, &screen.projection, screen.flow_key);
        view.commit(std.testing.io);
        try std.testing.expect(screen.projection.flow.excess > 0);
        for (0..100) |iteration| {
            const delta: isize = if (iteration % 4 < 2) 3 else -3;
            const old = view.request(std.testing.io).scroll.?;
            try std.testing.expectEqual(delta, view.wheel(std.testing.io, delta, 8, .application));
            try std.testing.expectEqual(old, view.request(std.testing.io).scroll.?);
            const remainder = view.wheel(std.testing.io, delta, 8, .terminal);
            const request = view.request(std.testing.io);
            try std.testing.expectEqual(delta, @as(isize, @intCast(old)) - @as(isize, @intCast(request.scroll.?)) + remainder);
            params.flow_key = request.key;
            params.flow_scroll = request.scroll;
            try screen.update(alloc, &state, params);
            try view.prepare(alloc, &screen.projection, screen.flow_key);
            view.commit(std.testing.io);
            try std.testing.expectEqual(ids[0], screen.regions.items[0].image_id);
            try std.testing.expectEqual(ids[1], screen.regions.items[1].image_id);
            try std.testing.expectEqual(Viewport.Point{ .x = 7, .y = 22 }, view.position(std.testing.io, 7, 22));
            try std.testing.expectEqual(Viewport.Point{ .x = 2, .y = 20 }, view.hit(std.testing.io, 2, 20));
            for (screen.projection.placements.items) |image| {
                try std.testing.expect(image.clip_top >= 60);
                try std.testing.expect(image.clip_bottom <= 400);
            }
        }
        try std.testing.expectEqual(renders, screen.worker.?.stats().renders);
        try std.testing.expectEqual(@as(usize, 3), t.scrolling_region.top);
        try std.testing.expectEqual(@as(usize, 19), t.scrolling_region.bottom);
        try std.testing.expect(t.flags.mouse_event != .none);
        try std.testing.expect(t.modes.get(.bracketed_paste));
        var after: std.Io.Writer.Allocating = .init(alloc);
        defer after.deinit();
        try formatter.format(&after.writer);
        try std.testing.expectEqualStrings(before.writer.buffered(), after.writer.buffered());
        stream.nextSlice("\x1b[4;1H\x1b[Kchanged\x1b[8;1H\x1b[Kplain\x1b[23;8H");
        try state.update(alloc, &t);
        try screen.update(alloc, &state, params);
        try view.prepare(alloc, &screen.projection, screen.flow_key);
        view.commit(std.testing.io);
        try std.testing.expect(!screen.projection.active);
        try std.testing.expectEqual(Viewport.Point{ .x = 9, .y = 8 }, view.hit(std.testing.io, 9, 8));
    }
}

test "ghosttex unsupported inline formula leaves only its own paragraph in source" {
    if (comptime !Native.available) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var t = try terminal.Terminal.init(std.testing.io, alloc, .{ .cols = 100, .rows = 12 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("first \\(\\unknownGhosttexCommand{x}\\) source\r\nsecond \\(x^2\\) rendered\r\ninput: ");
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    var screen: Screen = .{};
    defer screen.deinit(alloc);
    screen.worker = try Native.Worker.init(null, null);
    var params = testParameters(&state);
    params.dynamic = true;
    try waitForImagesWithParameters(&screen, &state, 1, params);
    try std.testing.expectEqual(@as(usize, 1), screen.regions.items.len);
    try std.testing.expectEqual(@as(usize, 1), screen.regions.items[0].first / state.cols);
    for (screen.projection.formula_cells.items[0..state.cols]) |hidden| try std.testing.expect(!hidden);
}

test "ghosttex dynamic wrapped paragraph preserves empty cursor cell and IME span" {
    if (comptime !Native.available) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var t = try terminal.Terminal.init(std.testing.io, alloc, .{ .cols = 40, .rows = 12 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("pre \\(x^2\\) tail with enough plain text to wrap and edit here");
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    const cursor = state.cursor.viewport.?;
    try std.testing.expectEqual(@as(u16, 1), cursor.y);
    var screen: Screen = .{};
    defer screen.deinit(alloc);
    screen.worker = try Native.Worker.init(null, null);
    var params = testParameters(&state);
    params.dynamic = true;
    params.preedit_width = 4;
    try waitForImagesWithParameters(&screen, &state, 1, params);
    try std.testing.expect(screen.projection.flow_active);
    const first = @as(usize, cursor.y) * state.cols + cursor.x;
    for (screen.projection.flow.positions.items[first..][0..4]) |position| try std.testing.expect(position.valid and !position.formula);
}

test "ghosttex inline paragraph renders every complete formula across native and explicit wraps" {
    if (comptime !Native.available) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const paragraph = @embedFile("testdata/inline-paragraph.txt");
    var expected: std.ArrayList(scanner.Formula) = .empty;
    defer expected.deinit(alloc);
    var it: scanner.Iterator = .init(paragraph, .{});
    while (it.next()) |formula| try expected.append(alloc, formula);
    try std.testing.expectEqual(@as(usize, 16), expected.items.len);
    for ([_]u16{ 80, 140, 240 }) |cols| {
        for ([_]bool{ false, true }) |hard_wrap| {
            var t = try terminal.Terminal.init(std.testing.io, alloc, .{ .cols = cols, .rows = 50 });
            defer t.deinit(alloc);
            var stream = t.vtStream();
            defer stream.deinit();
            stream.nextSlice(paragraph);
            // First use real Unicode terminal wrapping, then replay the exact
            // same cells as hard rows, like a generic CUP-driven TUI redraw.
            var state: terminal.RenderState = .empty;
            defer state.deinit(alloc);
            try state.update(alloc, &t);
            if (hard_wrap) {
                var buffer: std.Io.Writer.Allocating = .init(alloc);
                defer buffer.deinit();
                const formatter: terminal.formatter.ScreenFormatter = .init(t.screens.active, .{ .emit = .plain, .unwrap = false });
                try formatter.format(&buffer.writer);
                stream.nextSlice("\x1b[2J\x1b[H");
                var lines = std.mem.splitScalar(u8, buffer.writer.buffered(), '\n');
                while (lines.next()) |line| {
                    stream.nextSlice(line);
                    stream.nextSlice("\r\n");
                }
            }
            stream.nextSlice("\x1b[50;1Hinput: ");
            try state.update(alloc, &t);
            var before: std.Io.Writer.Allocating = .init(alloc);
            defer before.deinit();
            const formatter: terminal.formatter.ScreenFormatter = .init(t.screens.active, .{ .emit = .vt, .unwrap = false });
            try formatter.format(&before.writer);
            var screen: Screen = .{};
            defer screen.deinit(alloc);
            screen.worker = try Native.Worker.init(null, null);
            try waitForImages(&screen, &state, expected.items.len);
            for (screen.candidates.items, expected.items) |candidate, formula| {
                try std.testing.expectEqualStrings(formula.body.slice(paragraph), candidate.owned_body orelse candidate.formula.body.slice(screen.source.items));
            }
            for (screen.projection.placements.items) |image| {
                try std.testing.expect(image.y >= 0);
                const row: usize = @intCast(@divTrunc(image.y, 20));
                const left: usize = @intCast(@divTrunc(image.x, 9));
                const right: usize = @intCast(@divTrunc(image.x + @as(i32, @intCast(image.width)) - 1, 9));
                try std.testing.expect(row * cols + left >= image.first);
                try std.testing.expect(row * cols + right <= image.last);
                try std.testing.expect(image.height <= 20);
                try std.testing.expectEqual(@as(i32, 0), @mod(image.y + @as(i32, @intCast(image.height)), 20));
            }
            for (screen.projection.formula_cells.items, 0..) |masked, index| {
                var source_cell = false;
                for (screen.candidates.items) |candidate| if (index >= candidate.first and index <= candidate.last) {
                    source_cell = true;
                    break;
                };
                try std.testing.expectEqual(source_cell, masked);
            }
            var dynamic = testParameters(&state);
            dynamic.dynamic = true;
            try screen.update(alloc, &state, dynamic);
            try std.testing.expect(screen.projection.flow_active);
            try std.testing.expectEqual(expected.items.len, screen.projection.flow.images.items.len);
            const Viewport = @import("Viewport.zig");
            var view: Viewport = .{};
            defer view.deinit(alloc);
            try view.prepare(alloc, &screen.projection, screen.flow_key);
            view.commit(std.testing.io);
            // The native bottom cursor stays at the bottom without recognizing
            // an input widget, title, background color, or owning program.
            try std.testing.expectEqual(Viewport.Point{ .x = 7, .y = 49 }, view.position(std.testing.io, 7, 49));
            for (screen.projection.flow.images.items) |image| {
                const region_index = screen.projection.flow_regions.items[image.index];
                const region = screen.regions.items[region_index];
                try std.testing.expectEqual(region.height, image.height);
                const token = screen.projection.flow.positions.items[region.first];
                try std.testing.expectEqual((token.y + token.rows) * 20, image.y + @as(i32, @intCast(image.height)));
                const next = region.last + 1;
                if (next < screen.projection.flow.positions.items.len) {
                    const neighbor = screen.projection.flow.positions.items[next];
                    if (neighbor.valid and !neighbor.formula and neighbor.y == token.y) {
                        const gap = @as(i32, neighbor.x) * 9 - image.x - @as(i32, @intCast(image.width));
                        try std.testing.expect(gap >= 0 and gap < 9);
                    }
                }
            }
            for (screen.projection.flow.positions.items, 0..) |position, i| {
                if (!position.valid or screen.projection.formula_cells.items[i] or screen.flow_widths.items[i] == 0 or
                    i % cols >= screen.flow_rows.items[i / cols].used) continue;
                const y = position.y + position.rows - 1;
                if (y < 0 or y >= state.rows) continue;
                try std.testing.expectEqual(Viewport.Point{ .x = @intCast(i % cols), .y = @intCast(i / cols) }, view.hit(std.testing.io, position.x, @intCast(y)));
            }
            var after: std.Io.Writer.Allocating = .init(alloc);
            defer after.deinit();
            try formatter.format(&after.writer);
            try std.testing.expectEqualStrings(before.writer.buffered(), after.writer.buffered());
        }
    }
}

test "ghosttex grid screen recognizes math on both screens without changing VT state" {
    if (comptime !Native.available) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var t = try terminal.Terminal.init(std.testing.io, alloc, .{ .cols = 60, .rows = 12 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    var screen: Screen = .{};
    defer screen.deinit(alloc);
    screen.worker = try Native.Worker.init(null, null);
    for ([_][]const u8{ "", "\x1b[?1049h\x1b[?1003h\x1b[?1006h" }) |mode| {
        stream.nextSlice(mode);
        stream.nextSlice("\x1b[HInline \\(x^2\\) tail\r\n\\[\r\n\\frac{a}{b}\r\n\\]\r\ninput: ");
        try state.update(alloc, &t);
        const cursor = t.screens.active.cursor;
        var before: std.Io.Writer.Allocating = .init(alloc);
        defer before.deinit();
        const formatter: terminal.formatter.ScreenFormatter = .init(t.screens.active, .{ .emit = .vt, .unwrap = false });
        try formatter.format(&before.writer);
        try waitForImages(&screen, &state, 2);
        var after: std.Io.Writer.Allocating = .init(alloc);
        defer after.deinit();
        try formatter.format(&after.writer);
        try std.testing.expectEqualStrings(before.writer.buffered(), after.writer.buffered());
        try std.testing.expectEqual(cursor.x, t.screens.active.cursor.x);
        try std.testing.expectEqual(cursor.y, t.screens.active.cursor.y);
        try std.testing.expectEqual(@as(u16, 60), t.screens.active.pages.cols);
        try std.testing.expectEqual(@as(u16, 12), t.screens.active.pages.rows);
        // A cursor-only change must reveal the editing row immediately,
        // without waiting for text damage or altering its coordinates.
        stream.nextSlice("\x1b[1;2H");
        try state.update(alloc, &t);
        state.dirty = .false;
        try screen.update(alloc, &state, testParameters(&state));
        try std.testing.expectEqual(@as(usize, 1), screen.ready.items.len);
        stream.nextSlice("\x1b[5;8H");
        try state.update(alloc, &t);
        state.dirty = .false;
        try screen.update(alloc, &state, testParameters(&state));
        try std.testing.expectEqual(@as(usize, 2), screen.ready.items.len);
        if (mode.len > 0) {
            try std.testing.expectEqual(terminal.ScreenSet.Key.alternate, t.screens.active_key);
            try std.testing.expect(t.flags.mouse_event != .none);
        }
        stream.nextSlice("\x1b[2J\x1b[Hplain output\r\n");
        try state.update(alloc, &t);
        try screen.update(alloc, &state, testParameters(&state));
        try std.testing.expect(!screen.projection.active);
        try std.testing.expectEqual(@as(usize, 0), screen.ready.items.len);
    }
}

test "ghosttex grid screen excludes editing row marked input and nonisolated blocks" {
    const alloc = std.testing.allocator;
    var t = try terminal.Terminal.init(std.testing.io, alloc, .{ .cols = 60, .rows = 16 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("title does not select rendering rules\r\n\\(output\\)\r\nprefix \\[\r\nx\r\n\\] suffix\r\n\\[standalone\\]\r\n" ++
        "\x1b]133;A\x1b\\> \x1b]133;B\x1b\\\\(input\\)\r\n\x1b]133;C\x1b\\\\(editing\\)");
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    var screen: Screen = .{};
    defer screen.deinit(alloc);
    try screen.capture(alloc, &state, testParameters(&state));
    try std.testing.expectEqual(@as(usize, 2), screen.candidates.items.len);
    try std.testing.expectEqualStrings("output", screen.candidates.items[0].formula.body.slice(screen.source.items));
    try std.testing.expectEqual(@as(u16, 0), screen.candidates.items[1].left);
    try std.testing.expectEqual(state.cols, screen.candidates.items[1].right);
}

test "ghosttex grid scroll uses stable full formula bounds and cached image" {
    if (comptime !Native.available) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var t = try terminal.Terminal.init(std.testing.io, alloc, .{ .cols = 60, .rows = 4 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("before\r\n\\[\r\n\\frac{x}{y}\r\n\\]\r\nafter\r\nlast\r\ninput");
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    state.overscan_request = .{ .above = 16, .below = 16 };
    try state.update(alloc, &t);
    var screen: Screen = .{};
    defer screen.deinit(alloc);
    screen.worker = try Native.Worker.init(null, null);
    try waitForImages(&screen, &state, 1);
    const bottom = screen.projection.placements.items[0];
    const renders = screen.worker.?.stats().renders;
    t.scrollViewport(.top);
    try state.update(alloc, &t);
    try screen.update(alloc, &state, testParameters(&state));
    try std.testing.expectEqual(@as(usize, 1), screen.ready.items.len);
    const top = screen.projection.placements.items[0];
    try std.testing.expectEqual(bottom.height, top.height);
    try std.testing.expectEqual(bottom.width, top.width);
    try std.testing.expectEqual(bottom.image_id, top.image_id);
    try std.testing.expectEqual(@as(i32, 60), top.y - bottom.y);
    try std.testing.expectEqual(renders, screen.worker.?.stats().renders);
}

test "ghosttex clipped redraw retains previously observed complete block" {
    if (comptime !Native.available) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var t = try terminal.Terminal.init(std.testing.io, alloc, .{ .cols = 60, .rows = 12 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b[?1049hheader\r\n\\[\r\n\\begin{aligned}\r\na&=b+c\\\\\r\nb&=c+d\\\\\r\nc&=d+e\r\n\\end{aligned}\r\n\\]\r\ninput");
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    var screen: Screen = .{};
    defer screen.deinit(alloc);
    screen.worker = try Native.Worker.init(null, null);
    try waitForImages(&screen, &state, 1);
    const original = screen.projection.placements.items[0];
    const renders = screen.worker.?.stats().renders;
    // A generic redraw supplies only a suffix, not a terminal scrollback row.
    stream.nextSlice("\x1b[Hheader\x1b[K\r\nb&=c+d\\\\\x1b[K\r\nc&=d+e\x1b[K\r\n\\end{aligned}\x1b[K\r\n\\]\x1b[K\r\n\x1b[J\x1b[12;1Hinput");
    try state.update(alloc, &t);
    try screen.update(alloc, &state, testParameters(&state));
    try std.testing.expectEqual(@as(usize, 1), screen.ready.items.len);
    const clipped = screen.projection.placements.items[0];
    try std.testing.expectEqual(original.image_id, clipped.image_id);
    try std.testing.expectEqual(original.height, clipped.height);
    try std.testing.expectEqual(original.y - 60, clipped.y);
    try std.testing.expectEqual(@as(i32, 20), clipped.clip_top);
    try std.testing.expectEqual(@as(i32, 100), clipped.clip_bottom);
    try std.testing.expectEqual(renders, screen.worker.?.stats().renders);
    try std.testing.expect(!screen.projection.formula_cells.items[0]);
    stream.nextSlice("\x1b[2;1H");
    try state.update(alloc, &t);
    try screen.update(alloc, &state, testParameters(&state));
    try std.testing.expectEqual(@as(usize, 0), screen.ready.items.len);
    stream.nextSlice("\x1b[12;1H");
    try state.update(alloc, &t);
    try screen.update(alloc, &state, testParameters(&state));
    try std.testing.expectEqual(@as(usize, 1), screen.ready.items.len);
    // Changed source and explicit code must never reuse the cached formula.
    stream.nextSlice("\x1b[2;1Hchanged\x1b[K");
    try state.update(alloc, &t);
    try screen.update(alloc, &state, testParameters(&state));
    try std.testing.expectEqual(@as(usize, 0), screen.ready.items.len);
    stream.nextSlice("\x1b[H```tex\x1b[K\r\nb&=c+d\\\\\x1b[K\r\nc&=d+e\x1b[K\r\n\\end{aligned}\x1b[K\r\n\\]\x1b[K\r\n```\x1b[K\x1b[12;1Hinput");
    try state.update(alloc, &t);
    try screen.update(alloc, &state, testParameters(&state));
    try std.testing.expectEqual(@as(usize, 0), screen.ready.items.len);
    stream.nextSlice("\x1b[Hheader\x1b[K\r\nb&=c+d\\\\\x1b[K\r\nc&=d+e\x1b[K\r\n\\end{aligned}\x1b[K\r\n\\]\x1b[K\r\n\x1b[J\x1b[12;1Hinput");
    try state.update(alloc, &t);
    var reset = testParameters(&state);
    reset.epoch = 1;
    try screen.update(alloc, &state, reset);
    try std.testing.expectEqual(@as(usize, 0), screen.ready.items.len);
}

test "ghosttex multiple clipped dollar blocks inside stationary surrounding rows" {
    if (comptime !Native.available) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var t = try terminal.Terminal.init(std.testing.io, alloc, .{ .cols = 60, .rows = 24 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b[?1049hheader\r\n$$\r\na=1\r\nb=2\r\nc=3\r\n$$\r\n\r\nheading\r\n$$\r\nx+y=z\r\n$$\r\n\r\nheading\r\n$$\r\nu=4\r\nv=5\r\nw=6\r\nz=7\r\n$$\x1b[24;1Hinput");
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    var screen: Screen = .{};
    defer screen.deinit(alloc);
    screen.worker = try Native.Worker.init(null, null);
    try waitForImages(&screen, &state, 3);
    try std.testing.expectEqual(@as(usize, 3), screen.candidates.items.len);
    var image_ids: [3]u64 = undefined;
    for (screen.ready.items, &image_ids) |image, *id| id.* = image.id;
    const renders = screen.worker.?.stats().renders;
    // Two independent partial formulas, a complete formula between them,
    // and stationary content both above and below the partial source.
    stream.nextSlice("\x1b[2J\x1b[Hheader\r\nb=2\r\nc=3\r\n$$\r\n\r\nheading\r\n$$\r\nx+y=z\r\n$$\x1b[17;1Hheading\r\n$$\r\nu=4\r\nv=5\r\nw=6\x1b[22;1Hstatus\r\nfooter\r\ninput");
    try state.update(alloc, &t);
    try screen.update(alloc, &state, testParameters(&state));
    try std.testing.expectEqual(@as(usize, 3), screen.candidates.items.len);
    try std.testing.expectEqual(@as(usize, 3), screen.ready.items.len);
    for (screen.ready.items, image_ids) |image, id| try std.testing.expectEqual(id, image.id);
    try std.testing.expectEqual(renders, screen.worker.?.stats().renders);
    const upper = screen.candidates.items[0];
    try std.testing.expectEqualStrings("\na=1\nb=2\nc=3\n", upper.owned_body.?);
    try std.testing.expectEqual(@as(u16, 1), upper.clip_first);
    try std.testing.expectEqual(@as(u16, 4), upper.clip_end.?);
    const lower = screen.candidates.items[2];
    try std.testing.expectEqualStrings("\nu=4\nv=5\nw=6\nz=7\n", lower.owned_body.?);
    try std.testing.expectEqual(@as(u16, 17), lower.clip_first);
    try std.testing.expectEqual(@as(u16, 21), lower.clip_end.?);
    // Both partial matches remain stable even as unrelated rows change.
    stream.nextSlice("\x1b[23;1Hfooter changed\x1b[24;1Hinput");
    try state.update(alloc, &t);
    try screen.update(alloc, &state, testParameters(&state));
    try std.testing.expectEqual(@as(usize, 3), screen.candidates.items.len);
    try std.testing.expectEqual(renders, screen.worker.?.stats().renders);
    // Reverse direction: reveal another row at the top while the lower
    // formula shrinks against the same clipping boundary above the footer.
    stream.nextSlice("\x1b[2;1Ha=1\x1b[K\r\nb=2\x1b[K\r\nc=3\x1b[K\r\n$$\x1b[K\x1b[18;1H\x1b[K\r\n$$\x1b[K\r\nu=4\x1b[K\r\nv=5\x1b[K\x1b[24;1Hinput");
    try state.update(alloc, &t);
    try screen.update(alloc, &state, testParameters(&state));
    try std.testing.expectEqual(@as(usize, 3), screen.ready.items.len);
    for (screen.ready.items, image_ids) |image, id| try std.testing.expectEqual(id, image.id);
    try std.testing.expectEqual(renders, screen.worker.?.stats().renders);
    // An earlier, closed code fence does not classify following output as code.
    stream.nextSlice("\x1b[H```tex\x1b[K\r\ncode\x1b[K\r\n```\x1b[K\r\nb=2\x1b[K\r\nc=3\x1b[K\r\n$$\x1b[K\x1b[24;1Hinput");
    try state.update(alloc, &t);
    try screen.update(alloc, &state, testParameters(&state));
    try std.testing.expectEqual(@as(usize, 3), screen.ready.items.len);
    for (screen.ready.items, image_ids) |image, id| try std.testing.expectEqual(id, image.id);
    try std.testing.expectEqual(renders, screen.worker.?.stats().renders);
}

test "ghosttex continued fraction native images survive every scroll position" {
    if (comptime !Native.available) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const lines = [_][]const u8{ "\\[", "\\varphi", "=", "1+\\cfrac{1}{", "1+\\cfrac{1}{", "1+\\cfrac{1}{1+\\ddots}", "}}", "=", "\\frac{1+\\sqrt5}{2}", "\\]" };
    var t = try terminal.Terminal.init(std.testing.io, alloc, .{ .cols = 60, .rows = 24 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b[?1049h\x1b[4;1H\\[\r\n\\varphi\r\n=\r\n1+\\cfrac{1}{\r\n1+\\cfrac{1}{\r\n1+\\cfrac{1}{1+\\ddots}\r\n}}\r\n=\r\n\\frac{1+\\sqrt5}{2}\r\n\\]\x1b[24;1Hinput");
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    var screen: Screen = .{};
    defer screen.deinit(alloc);
    screen.worker = try Native.Worker.init(null, null);
    try waitForImages(&screen, &state, 1);
    const image_id = screen.ready.items[0].id;
    const renders = screen.worker.?.stats().renders;
    for (0..2) |direction| for (0..29) |step| {
        const top = if (direction == 0) @as(i32, 19) - @as(i32, @intCast(step)) else @as(i32, @intCast(step)) - 9;
        var frame: std.Io.Writer.Allocating = .init(alloc);
        defer frame.deinit();
        for (0..24) |y| {
            const offset = @as(i32, @intCast(y)) - top;
            const text: []const u8 = if (y == 0) "header" else if (y == 21) "status" else if (y == 22) "footer" else if (y == 23) "input" else if (offset >= 0 and offset < lines.len) lines[@intCast(offset)] else "";
            try frame.writer.print("\x1b[{d};1H{s}\x1b[K", .{ y + 1, text });
        }
        stream.nextSlice(frame.writer.buffered());
        try state.update(alloc, &t);
        try screen.update(alloc, &state, testParameters(&state));
        if (@min(21, top + @as(i32, @intCast(lines.len))) - @max(1, top) >= 3) {
            if (screen.ready.items.len != 1) std.debug.print("continued fraction disappeared at top={d} direction={d}\n", .{ top, direction });
            try std.testing.expectEqual(@as(usize, 1), screen.ready.items.len);
        }
        for (screen.ready.items) |image| try std.testing.expectEqual(image_id, image.id);
        try std.testing.expectEqual(renders, screen.worker.?.stats().renders);
    };
}

test "ghosttex complete inverse matrix overrides shared cached multiplication prefix" {
    if (comptime !Native.available) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var t = try terminal.Terminal.init(std.testing.io, alloc, .{ .cols = 60, .rows = 24 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    const multiplication = "\\[\r\n\\begin{pmatrix}\r\na&b\\\\\r\nc&d\r\n\\end{pmatrix}\r\n\\begin{pmatrix}\r\nx\\\\\r\ny\r\n\\end{pmatrix}\r\n=\r\n\\begin{pmatrix}\r\nax+by\\\\\r\ncx+dy\r\n\\end{pmatrix}\r\n\\]";
    const inverse = "\\[\r\n\\begin{pmatrix}\r\na&b\\\\\r\nc&d\r\n\\end{pmatrix}^{-1}\r\n=\r\n\\frac{1}{ad-bc}\r\n\\begin{pmatrix}\r\nd&-b\\\\\r\n-c&a\r\n\\end{pmatrix},\r\n\\qquad ad-bc\\ne0\r\n\\]";
    stream.nextSlice("\x1b[?1049h\x1b[2;1H" ++ multiplication ++ "\x1b[24;1Hinput");
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    var screen: Screen = .{};
    defer screen.deinit(alloc);
    screen.worker = try Native.Worker.init(null, null);
    try waitForImages(&screen, &state, 1);
    const multiplication_id = screen.ready.items[0].id;
    stream.nextSlice("\x1b[2J\x1b[4;1H" ++ inverse ++ "\x1b[24;1Hinput");
    try state.update(alloc, &t);
    try waitForImages(&screen, &state, 1);
    try std.testing.expect(screen.ready.items[0].id != multiplication_id);
    try std.testing.expectEqual(@as(usize, 1), screen.candidates.items.len);
    const candidate = screen.candidates.items[0];
    try std.testing.expectEqual(@as(u32, 13), candidate.source_rows);
    try std.testing.expectEqual(@as(i32, 3), candidate.top);
    const body = candidate.owned_body orelse candidate.formula.body.slice(screen.source.items);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\end{pmatrix}^{-1}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\qquad ad-bc\\ne0") != null);
    for (3 * 60..16 * 60) |cell| try std.testing.expect(screen.projection.formula_cells.items[cell]);
    const inverse_id = screen.ready.items[0].id;
    const renders = screen.worker.?.stats().renders;
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);
    var split = std.mem.splitSequence(u8, inverse, "\r\n");
    while (split.next()) |line| try lines.append(alloc, line);
    for (3..21) |top| {
        var frame: std.Io.Writer.Allocating = .init(alloc);
        defer frame.deinit();
        for (0..24) |y| {
            const text: []const u8 = if (y == 0) "header" else if (y == 21) "status" else if (y == 22) "footer" else if (y == 23) "input" else if (y >= top and y - top < lines.items.len) lines.items[y - top] else "";
            try frame.writer.print("\x1b[{d};1H{s}\x1b[K", .{ y + 1, text });
        }
        stream.nextSlice(frame.writer.buffered());
        try state.update(alloc, &t);
        try screen.update(alloc, &state, testParameters(&state));
        if (screen.ready.items.len != 1) std.debug.print("inverse matrix disappeared at top={d}\n", .{top});
        try std.testing.expectEqual(@as(usize, 1), screen.ready.items.len);
        try std.testing.expectEqual(inverse_id, screen.ready.items[0].id);
        try std.testing.expectEqual(renders, screen.worker.?.stats().renders);
    }
}
