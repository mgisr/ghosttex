//! Tests the recognizer at the decoded terminal boundary, rather than stripping
//! ANSI from a second copy of the PTY stream. No renderer or UI is involved.
const std = @import("std");
const math = @import("markdown_math.zig");
const formatter = @import("formatter.zig");
const Terminal = @import("Terminal.zig");

test "ghosttex shell substitution colors fragments and soft wraps retain dollar math" {
    const alloc = std.testing.allocator;
    var terminal = try Terminal.init(std.testing.io, alloc, .{ .cols = 32, .rows = 14 });
    defer terminal.deinit(alloc);
    var stream = terminal.vtStream();
    defer stream.deinit();
    const command = "Running DB_URL=\"$(cat /tmp/local-dsn)\" RELAY=\"http://127.0.0.1:$(cat /tmp/port)\"";
    const output = "\x1b[32m" ++ command ++ "\x1b[0m\r\n正文 $x^2$ and $(a+b)^2$\r\n";
    var text: std.Io.Writer.Allocating = .init(alloc);
    defer text.deinit();
    // Observe each immutable terminal snapshot, including snapshots cut just
    // after the second '$' and those crossing physical auto-wrap boundaries.
    for (output) |byte| {
        stream.nextSlice(&.{byte});
        text.clearRetainingCapacity();
        var fmt: formatter.ScreenFormatter = .init(terminal.screens.active, .{ .emit = .plain, .unwrap = true, .trim = false });
        try fmt.format(&text.writer);
        const source = text.writer.buffered();
        var it: math.Iterator = .init(source, .{ .single_dollar = true });
        while (it.next()) |formula| {
            const body = formula.body.slice(source);
            try std.testing.expect(std.mem.eql(u8, body, "x^2") or std.mem.eql(u8, body, "(a+b)^2"));
        }
    }
    const source = text.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, source, command) != null);
    var it: math.Iterator = .init(source, .{ .single_dollar = true });
    try std.testing.expectEqualStrings("x^2", it.next().?.body.slice(source));
    try std.testing.expectEqualStrings("(a+b)^2", it.next().?.body.slice(source));
    try std.testing.expect(it.next() == null);
}

test "ghosttex math terminal byte fragments ANSI Unicode and soft wrapping" {
    const alloc = std.testing.allocator;
    var terminal = try Terminal.init(std.testing.io, alloc, .{ .cols = 10, .rows = 16 });
    defer terminal.deinit(alloc);
    var stream = terminal.vtStream();
    defer stream.deinit();
    const output = "\x1b[31m\\(\\frac{1}{2}\\)\x1b[0m\r\n\\(hard\r\nbreak\\)\r\n中文 \\(ok\\)";
    for (output) |byte| stream.nextSlice(&.{byte});

    var text: std.Io.Writer.Allocating = .init(alloc);
    defer text.deinit();
    var map: formatter.PinMap.Map = .empty;
    defer map.deinit(alloc);
    var fmt: formatter.ScreenFormatter = .init(terminal.screens.active, .{
        .emit = .plain,
        .unwrap = true,
        .trim = false,
    });
    fmt.pin_map = .{ .alloc = alloc, .map = &map };
    try fmt.format(&text.writer);
    const source = text.writer.buffered();
    try std.testing.expectEqual(source.len, map.count());
    try std.testing.expect(std.mem.indexOfScalar(u8, source, 0x1b) == null);
    var it: math.Iterator = .init(source, .{});
    const first = it.next().?;
    try std.testing.expectEqualStrings("\\frac{1}{2}", first.body.slice(source));
    const first_pin = map.get(first.source.start).?;
    const last_pin = map.get(first.source.end - 1).?;
    try std.testing.expectEqual(@as(u21, '\\'), first_pin.rowAndCell().cell.codepoint());
    try std.testing.expectEqual(@as(u21, ')'), last_pin.rowAndCell().cell.codepoint());
    // The first formula crosses a soft wrap; the invalid second one crosses
    // a hard newline and must remain source. CJK does not corrupt byte mapping.
    try std.testing.expect(first_pin.node != last_pin.node or first_pin.y != last_pin.y);
    const last = it.next().?;
    try std.testing.expectEqualStrings("ok", last.body.slice(source));
    try std.testing.expectEqual(@as(u21, '\\'), map.get(last.source.start).?.rowAndCell().cell.codepoint());
    try std.testing.expectEqual(@as(usize, 5), map.get(last.source.start).?.x);
    try std.testing.expect(it.next() == null);
}

test "ghosttex math terminal overwrites and clears use current source" {
    const alloc = std.testing.allocator;
    var terminal = try Terminal.init(std.testing.io, alloc, .{ .cols = 80, .rows = 5 });
    defer terminal.deinit(alloc);
    var stream = terminal.vtStream();
    defer stream.deinit();
    stream.nextSlice("\\(old\\)\r\x1b[2K\\(new\\)");

    var text: std.Io.Writer.Allocating = .init(alloc);
    defer text.deinit();
    var fmt: formatter.ScreenFormatter = .init(terminal.screens.active, .{
        .emit = .plain,
        .unwrap = true,
        .trim = false,
    });
    try fmt.format(&text.writer);
    var it: math.Iterator = .init(text.writer.buffered(), .{});
    try std.testing.expectEqualStrings("new", it.next().?.body.slice(text.writer.buffered()));
    try std.testing.expect(it.next() == null);

    stream.nextSlice("\x1b[2J\x1b[H");
    text.clearRetainingCapacity();
    try fmt.format(&text.writer);
    it = .init(text.writer.buffered(), .{});
    try std.testing.expect(it.next() == null);
}

test "ghosttex math terminal code fence above viewport still excludes math" {
    const alloc = std.testing.allocator;
    var terminal = try Terminal.init(std.testing.io, alloc, .{ .cols = 40, .rows = 3 });
    defer terminal.deinit(alloc);
    var stream = terminal.vtStream();
    defer stream.deinit();
    stream.nextSlice("```tex\r\ncode\r\ncode\r\n\\(hidden\\)\r\n```\r\n\\(visible\\)");

    var text: std.Io.Writer.Allocating = .init(alloc);
    defer text.deinit();
    const fmt: formatter.ScreenFormatter = .init(terminal.screens.active, .{
        .emit = .plain,
        .unwrap = true,
        .trim = false,
    });
    try fmt.format(&text.writer);
    const source = text.writer.buffered();
    var it: math.Iterator = .init(source, .{});
    try std.testing.expectEqualStrings("visible", it.next().?.body.slice(source));
    try std.testing.expect(it.next() == null);
}
