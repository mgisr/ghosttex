//! Versioned Rust ABI. Only the worker calls render; never hold terminal or
//! draw locks across a call. Images retain Rust ownership until deinit.
const std = @import("std");
pub const available = @import("build_options").math;

const Options = extern struct {
    struct_size: u32 = @sizeOf(Options),
    version: u32 = 1,
    font_px: f32,
    max_width: u32,
    max_height: u32 = 4096,
    display: u32,
    color: [4]u8,
};

const Result = extern struct {
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    baseline: f32 = 0,
    data: ?[*]const u8 = null,
    len: usize = 0,
    owner: ?*anyopaque = null,
    error_message: [256]u8 = @splat(0),
};

extern fn ghosttex_math_abi_version() u32;
extern fn ghosttex_math_render([*]const u8, usize, *const Options, *Result) c_int;
extern fn ghosttex_math_free(*Result) void;
const Context = opaque {};
const Wake = *const fn (?*anyopaque) callconv(.c) void;
extern fn ghosttex_math_context_create(?Wake, ?*anyopaque, [*]const u8, usize) ?*Context;
extern fn ghosttex_math_context_destroy(*Context) void;
extern fn ghosttex_math_frame_begin(*Context) void;
extern fn ghosttex_math_frame_finish(*Context) void;
extern fn ghosttex_math_request(*Context, [*]const u8, usize, *const Options, *Result, *u64) c_int;
extern fn ghosttex_math_stats(*Context, *Stats) void;

pub const Stats = extern struct {
    renders: u64 = 0,
    cache_hits: u64 = 0,
    canceled: u64 = 0,
    failures: u64 = 0,
    render_ns: u64 = 0,
    cpu_bytes: u64 = 0,
    queued: u64 = 0,
};

pub const Worker = struct {
    context: *Context,

    pub fn init(wake: ?Wake, userdata: ?*anyopaque) Error!Worker {
        if (comptime !available) return error.Unavailable;
        const path = @import("build_options").math_worker_path;
        return .{ .context = ghosttex_math_context_create(wake, userdata, path.ptr, path.len) orelse return error.Unavailable };
    }

    pub fn deinit(self: *Worker) void {
        if (comptime available) ghosttex_math_context_destroy(self.context);
        self.* = undefined;
    }

    pub fn begin(self: *Worker) void {
        if (comptime available) ghosttex_math_frame_begin(self.context);
    }

    pub fn finish(self: *Worker) void {
        if (comptime available) ghosttex_math_frame_finish(self.context);
    }

    pub fn request(self: *Worker, source: []const u8, params: Parameters, ticket: *u64) ?Image {
        ticket.* = 0;
        if (comptime !available) return null;
        if (source.len == 0 or source.len > 16 * 1024) return null;
        var result: Result = .{};
        const status = ghosttex_math_request(self.context, source.ptr, source.len, &.{
            .font_px = params.font_px,
            .max_width = params.max_width,
            .display = @intFromBool(params.display),
            .color = params.color,
        }, &result, ticket);
        if (status == 0) return .{ .raw = result };
        ghosttex_math_free(&result);
        return null;
    }

    pub fn stats(self: *Worker) Stats {
        var result: Stats = .{};
        if (comptime available) ghosttex_math_stats(self.context, &result);
        return result;
    }
};

pub const Parameters = struct {
    font_px: f32,
    max_width: u32,
    display: bool,
    color: [4]u8,
};

pub const Image = struct {
    raw: Result,

    pub fn deinit(self: *Image) void {
        if (comptime available) ghosttex_math_free(&self.raw);
        self.* = undefined;
    }

    pub fn pixels(self: *const Image) []const u8 {
        return self.raw.data.?[0..self.raw.len];
    }
};

pub const Error = error{ Unavailable, InvalidSource, InvalidImage, RenderFailed };

pub fn render(source: []const u8, params: Parameters, diagnostic: *[256]u8) Error!Image {
    diagnostic.* = @splat(0);
    if (comptime !available) return error.Unavailable;
    if (source.len == 0 or source.len > 16 * 1024 or !std.unicode.utf8ValidateSlice(source))
        return error.InvalidSource;
    if (ghosttex_math_abi_version() != 1) return error.Unavailable;
    var result: Result = .{};
    const status = ghosttex_math_render(source.ptr, source.len, &.{
        .font_px = params.font_px,
        .max_width = params.max_width,
        .display = @intFromBool(params.display),
        .color = params.color,
    }, &result);
    errdefer ghosttex_math_free(&result);
    diagnostic.* = result.error_message;
    if (status != 0) return error.RenderFailed;
    if (result.width == 0 or result.height == 0 or result.width > 4096 or result.height > 4096 or
        result.width > params.max_width or result.stride != result.width * 4 or
        result.len != @as(usize, result.stride) * result.height or result.len > 16 * 1024 * 1024 or
        result.data == null or result.owner == null or !std.math.isFinite(result.baseline) or
        result.baseline < 0 or result.baseline > @as(f32, @floatFromInt(result.height)))
        return error.InvalidImage;
    return .{ .raw = result };
}

test "ghosttex native ABI dimensions alpha and fallback" {
    if (comptime !available) return error.SkipZigTest;
    var diagnostic: [256]u8 = undefined;
    var image = try render("\\frac{x_1}{\\sqrt{y}}", .{
        .font_px = 24,
        .max_width = 512,
        .display = true,
        .color = .{ 255, 255, 255, 255 },
    }, &diagnostic);
    defer image.deinit();
    try std.testing.expect(image.raw.height > 24);
    try std.testing.expect(image.pixels().len > 0);
    try std.testing.expectError(error.RenderFailed, render("\\unknownGhosttexCommand", .{
        .font_px = 24,
        .max_width = 512,
        .display = true,
        .color = .{ 255, 255, 255, 255 },
    }, &diagnostic));
    try std.testing.expect(diagnostic[0] != 0);
}

test "ghosttex native continued fraction from clipped scroll reproduction" {
    if (comptime !available) return error.SkipZigTest;
    var diagnostic: [256]u8 = undefined;
    var image = render("\\varphi\n=\n1+\\cfrac{1}{\n1+\\cfrac{1}{\n1+\\cfrac{1}{1+\\ddots}\n}}\n=\n\\frac{1+\\sqrt5}{2}", .{
        .font_px = 20,
        .max_width = 540,
        .display = true,
        .color = .{ 255, 255, 255, 255 },
    }, &diagnostic) catch |err| {
        std.debug.print("continued fraction render failed: {s}\n", .{std.mem.sliceTo(&diagnostic, 0)});
        return err;
    };
    defer image.deinit();
    try std.testing.expect(image.raw.width > 0);
}
