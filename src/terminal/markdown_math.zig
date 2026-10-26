//! Conservative math recognition over an immutable, decoded Markdown snapshot.
//!
//! This is deliberately separate from the VT byte stream. Feed terminal output
//! through Terminal first; use a plain formatter with unwrap=true and trim=false
//! to preserve hard breaks and TeX whitespace. Offsets are UTF-8 byte offsets,
//! suitable for formatter.PinMap. A snapshot must include preceding code fences;
//! starting at an arbitrary viewport row does not provide enough context.
//!
//! No allocations, source rewriting, TeX parsing, or terminal mutations occur.
//! This is a conservative Markdown subset, not a CommonMark parser. Unclosed
//! code spans hide subsequent math; ambiguous dollar runs remain source text.

const std = @import("std");

pub const Range = struct {
    start: usize,
    end: usize,

    pub fn slice(self: Range, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

pub const Delimiter = enum {
    dollar,
    double_dollar,
    paren,
    bracket,

    pub fn display(self: Delimiter) bool {
        return switch (self) {
            .dollar, .paren => false,
            .double_dollar, .bracket => true,
        };
    }
};

pub const Formula = struct {
    /// Half-open byte ranges, including and excluding delimiters respectively.
    source: Range,
    body: Range,
    delimiter: Delimiter,
};

pub const Options = struct {
    /// Dollar delimiters are ambiguous in shell output. Explicit delimiters
    /// work by default; dollar recognition is an opt-in heuristic.
    single_dollar: bool = false,
    /// The host may join explicitly delimited inline math across physical
    /// output rows. Dollar math remains restricted to one hard line.
    multiline_paren: bool = false,
    /// Maximum body length. Oversized candidates stay readable as source.
    max_source_bytes: usize = 16 * 1024,
};

pub const Checkpoint = struct {
    offset: usize = 0,
    code_ticks: usize = 0,
    fence_char: u8 = 0,
    fence_len: usize = 0,

    pub fn restore(self: Checkpoint, iterator: *Iterator) void {
        iterator.code_ticks = self.code_ticks;
        iterator.fence_char = self.fence_char;
        iterator.fence_len = self.fence_len;
    }
};

pub const Iterator = struct {
    source: []const u8,
    options: Options,
    pos: usize = 0,
    code_ticks: usize = 0,
    fence_char: u8 = 0,
    fence_len: usize = 0,
    /// Optional caller-owned storage. Only hard-line starts outside formulas
    /// become checkpoints; no allocation or history scan is needed here.
    checkpoints: []Checkpoint = &.{},
    checkpoint_count: usize = 0,
    /// Hard-line message/prompt boundaries supplied by the host. Code and
    /// incomplete formula context cannot leak into the next message.
    boundaries: []const usize = &.{},
    boundary_index: usize = 0,
    /// Sorted, nonoverlapping source ranges already identified by the host.
    /// Do not reinterpret their delimiters or consume across these ranges.
    exclusions: []const Range = &.{},
    exclusion_index: usize = 0,

    pub fn init(source: []const u8, options: Options) Iterator {
        return .{ .source = source, .options = options };
    }

    pub fn next(self: *Iterator) ?Formula {
        while (self.pos < self.source.len) {
            while (self.exclusion_index < self.exclusions.len and self.exclusions[self.exclusion_index].end <= self.pos)
                self.exclusion_index += 1;
            if (self.exclusion_index < self.exclusions.len and self.exclusions[self.exclusion_index].start <= self.pos) {
                self.pos = self.exclusions[self.exclusion_index].end;
                continue;
            }
            while (self.boundary_index < self.boundaries.len and self.boundaries[self.boundary_index] <= self.pos) {
                self.code_ticks = 0;
                self.fence_char = 0;
                self.fence_len = 0;
                self.boundary_index += 1;
            }
            const start = self.pos;
            if (start == 0 or self.source[start - 1] == '\n') {
                if (self.checkpoint_count < self.checkpoints.len) {
                    self.checkpoints[self.checkpoint_count] = .{ .offset = start, .code_ticks = self.code_ticks, .fence_char = self.fence_char, .fence_len = self.fence_len };
                    self.checkpoint_count += 1;
                }
                const end = lineEnd(self.source, start);
                const line = self.source[start..end];
                if (self.code_ticks == 0 and self.skipLine(line)) {
                    self.pos = end + @intFromBool(end < self.source.len);
                    continue;
                }
            }

            const c = self.source[start];
            if (c == '`') {
                const n = run(self.source, start, '`');
                if (self.code_ticks == 0) {
                    self.code_ticks = n;
                } else if (self.code_ticks == n) {
                    self.code_ticks = 0;
                }
                self.pos += n;
                continue;
            }
            if (self.code_ticks > 0) {
                self.pos += 1;
                continue;
            }

            const delimiter: Delimiter = switch (c) {
                '\\' => blk: {
                    if (start + 1 == self.source.len) {
                        self.pos += 1;
                        continue;
                    }
                    switch (self.source[start + 1]) {
                        '(' => break :blk .paren,
                        '[' => break :blk .bracket,
                        else => {
                            // Consume escapes in pairs, preserving backslash parity.
                            self.pos += 2;
                            continue;
                        },
                    }
                },
                '$' => blk: {
                    const n = run(self.source, start, '$');
                    if (n == 2) break :blk .double_dollar;
                    if (n == 1 and self.options.single_dollar and self.dollarOpen(start))
                        break :blk .dollar;
                    self.pos += n;
                    continue;
                },
                else => {
                    self.pos += 1;
                    continue;
                },
            };

            const width: usize = if (delimiter == .dollar) 1 else 2;
            const body_start = start + width;
            const result = self.findClose(body_start, delimiter);
            if (delimiter == .dollar and expansionOpen(self.source, start) != null) {
                if (self.expansionEnd(start)) |end| {
                    // A closing dollar inside a substitution, another shell
                    // expansion, or the next quoted word is not its math end.
                    // Keep real $(x)^2$ and ${x_i}$ formulas: a balanced shell
                    // prefix alone cannot disqualify mathematical parentheses.
                    const close = result.close;
                    if (close == null or close.? < end or (close.? != end and
                        (expansionOpen(self.source, close.?) != null or self.crossesQuote(start, end, close.?))))
                    {
                        self.pos = end;
                        continue;
                    }
                } else {
                    // Incomplete snapshots must not expose dollars inside an
                    // unfinished substitution as independent inline formulas.
                    self.pos = self.expansionLimit(start);
                    continue;
                }
            }
            self.pos = result.advance;
            if (result.close) |close| {
                if (close - body_start > self.options.max_source_bytes) continue;
                if (std.mem.trim(u8, self.source[body_start..close], " \t\r\n").len == 0)
                    continue;
                return .{
                    .source = .{ .start = start, .end = self.pos },
                    .body = .{ .start = body_start, .end = close },
                    .delimiter = delimiter,
                };
            }
        }
        return null;
    }

    /// Container prefixes are inspected only for code context; original TeX
    /// bytes and offsets remain untouched.
    fn skipLine(self: *Iterator, raw_line: []const u8) bool {
        const line = codeLine(raw_line);
        var indent: usize = 0;
        while (indent < line.len and line[indent] == ' ') : (indent += 1) {}
        const is_indented = indent >= 4 or (indent < line.len and line[indent] == '\t');
        if (indent < line.len and indent <= 3) {
            const c = line[indent];
            if (c == '`' or c == '~') {
                const n = run(line, indent, c);
                const tail = line[indent + n ..];
                if (self.fence_len > 0) {
                    if (c == self.fence_char and n >= self.fence_len and
                        std.mem.trim(u8, tail, " \t\r").len == 0)
                    {
                        self.fence_len = 0;
                    }
                    return true;
                }
                if (n >= 3 and (c != '`' or std.mem.indexOfScalar(u8, tail, '`') == null)) {
                    self.fence_char = c;
                    self.fence_len = n;
                    return true;
                }
            }
        }
        return self.fence_len > 0 or is_indented;
    }

    fn dollarOpen(self: *const Iterator, at: usize) bool {
        if (at + 1 == self.source.len or whitespace(self.source[at + 1])) return false;
        if (at > 0 and (word(self.source[at - 1]) or self.source[at - 1] == '/')) return false;
        return true;
    }

    /// Bound shell-like expansion scanning to this immutable source region.
    /// This is lexical exclusion, never command or application detection.
    fn expansionEnd(self: *const Iterator, start: usize) ?usize {
        const close = expansionOpen(self.source, start) orelse return null;
        const limit = self.expansionLimit(start);
        const Frame = struct { close: u8, quote: u8 = 0 };
        var stack: [64]Frame = undefined;
        stack[0] = .{ .close = close };
        var depth: usize = 1;
        var i = start + 2;
        while (i < limit) {
            const frame = &stack[depth - 1];
            const c = self.source[i];
            if (c == '\\' and frame.quote != '\'') {
                i += @min(@as(usize, 2), limit - i);
                continue;
            }
            if (frame.quote == '\'' or frame.quote == '`') {
                if (c == frame.quote) frame.quote = 0;
                i += 1;
                continue;
            }
            if (expansionOpen(self.source[0..limit], i)) |nested| {
                if (depth == stack.len) return null;
                stack[depth] = .{ .close = nested };
                depth += 1;
                i += 2;
                continue;
            }
            if (frame.quote != 0) {
                if (c == frame.quote) frame.quote = 0;
            } else if (c == '"' or c == '\'' or c == '`') {
                frame.quote = c;
            } else if (c == '(' or c == '{') {
                if (depth == stack.len) return null;
                stack[depth] = .{ .close = if (c == '(') ')' else '}' };
                depth += 1;
            } else if (c == frame.close) {
                depth -= 1;
                if (depth == 0) return i + 1;
            }
            i += 1;
        }
        return null;
    }

    fn expansionLimit(self: *const Iterator, start: usize) usize {
        var limit = @min(lineEnd(self.source, start), start + @min(self.options.max_source_bytes, self.source.len - start));
        if (self.boundary_index < self.boundaries.len) limit = @min(limit, self.boundaries[self.boundary_index]);
        if (self.exclusion_index < self.exclusions.len) limit = @min(limit, self.exclusions[self.exclusion_index].start);
        // Even a zero source budget must advance beyond the opening dollar.
        return @max(start + 1, limit);
    }

    fn crossesQuote(self: *const Iterator, start: usize, end: usize, close: usize) bool {
        var line_start = start;
        while (line_start > 0 and self.source[line_start - 1] != '\n') : (line_start -= 1) {}
        if (self.boundary_index > 0) line_start = @max(line_start, self.boundaries[self.boundary_index - 1]);
        var quote: u8 = 0;
        var i = line_start;
        while (i < start) : (i += 1) {
            const c = self.source[i];
            if (c == '\\' and quote != '\'') {
                i += 1;
            } else if (quote != 0) {
                if (c == quote) quote = 0;
            } else if (c == '"' or c == '\'') {
                quote = c;
            }
        }
        if (quote == 0) return false;
        i = end;
        while (i < close) : (i += 1) {
            if (self.source[i] == '\\') {
                i += 1;
            } else if (self.source[i] == quote) {
                return true;
            }
        }
        return false;
    }

    const Close = struct { close: ?usize = null, advance: usize };

    fn findClose(self: *const Iterator, begin: usize, delimiter: Delimiter) Close {
        var i = begin;
        var limit = if (self.boundary_index < self.boundaries.len) self.boundaries[self.boundary_index] else self.source.len;
        if (self.exclusion_index < self.exclusions.len) limit = @min(limit, self.exclusions[self.exclusion_index].start);
        while (i < limit) {
            const c = self.source[i];
            if (c == '\n') {
                if (!delimiter.display() and !(delimiter == .paren and self.options.multiline_paren))
                    return .{ .advance = i };
                // Do not let unfinished block math consume a Markdown fence or
                // a new paragraph. Resume there so code context remains intact.
                const end = lineEnd(self.source, i + 1);
                const line = std.mem.trim(u8, codeLine(self.source[i + 1 .. end]), " \t\r");
                if (line.len == 0 or std.mem.startsWith(u8, line, "```") or
                    std.mem.startsWith(u8, line, "~~~")) return .{ .advance = i + 1 };
            }
            if (c == '\\') {
                if (i + 1 < limit) {
                    // A TeX backslash cannot erase a terminal hard newline.
                    if (self.source[i + 1] == '\n') {
                        i += 1;
                        continue;
                    }
                    if ((delimiter == .dollar or delimiter == .paren) and
                        (self.source[i + 1] == '(' or self.source[i + 1] == '['))
                        return .{ .advance = i };
                    const expected: u8 = if (delimiter == .paren) ')' else ']';
                    if ((delimiter == .paren or delimiter == .bracket) and
                        self.source[i + 1] == expected)
                    {
                        return .{ .close = i, .advance = i + 2 };
                    }
                    i += 2;
                    continue;
                }
            }
            if (c == '$' and (delimiter == .dollar or delimiter == .double_dollar)) {
                const n = run(self.source, i, '$');
                const width: usize = if (delimiter == .dollar) 1 else 2;
                if (n == width and (delimiter != .dollar or
                    (i > begin and !whitespace(self.source[i - 1]) and
                        (i + 1 == self.source.len or !word(self.source[i + 1])))))
                    return .{ .close = i, .advance = i + width };
                // Do not carry an unmatched opener across the next dollar
                // token and swallow a later, independently valid formula.
                if (delimiter == .dollar) return .{ .advance = i };
                i += n;
                continue;
            }
            // Incomplete inline math must not swallow a following code span.
            if (!delimiter.display() and c == '`') return .{ .advance = i };
            i += 1;
        }
        return .{ .advance = i };
    }
};

fn expansionOpen(source: []const u8, at: usize) ?u8 {
    if (at + 1 >= source.len or source[at] != '$') return null;
    return switch (source[at + 1]) {
        '(' => ')',
        '{' => '}',
        else => null,
    };
}

fn lineEnd(source: []const u8, start: usize) usize {
    return if (std.mem.indexOfScalarPos(u8, source, start, '\n')) |n| n else source.len;
}

test "ghosttex known clipped source cannot consume following delimiters" {
    const source = "tail\n$$\nheading\n$$\nx=1\n$$\n";
    var iterator: Iterator = .init(source, .{});
    iterator.exclusions = &.{.{ .start = 0, .end = "tail\n$$\n".len }};
    const formula = iterator.next().?;
    try std.testing.expectEqualStrings("\nx=1\n", formula.body.slice(source));
    try std.testing.expect(iterator.next() == null);

    const interrupted = "$$\nunfinished\nknown\n\\(next\\)";
    iterator = .init(interrupted, .{});
    const at = std.mem.indexOf(u8, interrupted, "known").?;
    iterator.exclusions = &.{.{ .start = at, .end = at + "known\n".len }};
    try std.testing.expectEqualStrings("next", iterator.next().?.body.slice(interrupted));
    try std.testing.expect(iterator.next() == null);
}

fn run(source: []const u8, start: usize, c: u8) usize {
    var end = start;
    while (end < source.len and source[end] == c) : (end += 1) {}
    return end - start;
}

fn whitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn word(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn codeLine(line: []const u8) []const u8 {
    var at: usize = 0;
    while (true) {
        var indent: usize = 0;
        while (at + indent < line.len and line[at + indent] == ' ' and indent < 3) : (indent += 1) {}
        const start = at + indent;
        if (start >= line.len) return line[at..];
        if (line[start] == '>' and (start + 1 == line.len or line[start + 1] == ' ')) {
            at = @min(start + 2, line.len);
            continue;
        }
        if ((line[start] == '-' or line[start] == '*' or line[start] == '+') and
            start + 1 < line.len and line[start + 1] == ' ')
        {
            at = start + 2;
            continue;
        }
        var end = start;
        while (end < line.len and std.ascii.isDigit(line[end]) and end - start < 9) : (end += 1) {}
        if (end > start and end + 1 < line.len and
            (line[end] == '.' or line[end] == ')') and line[end + 1] == ' ')
        {
            at = end + 2;
            continue;
        }
        return line[at..];
    }
}

test "ghosttex math excludes fenced code in Markdown containers" {
    const source = "> ```tex\n> \\(hidden\\)\n> ```\n- ~~~\n  \\(hidden\\)\n  ~~~\n1. ```\n   \\(hidden\\)\n   ```\n\\(visible\\)";
    var iterator: Iterator = .init(source, .{});
    try std.testing.expectEqualStrings("visible", iterator.next().?.body.slice(source));
    try std.testing.expect(iterator.next() == null);
}

test "ghosttex math explicit delimiters and source ranges" {
    const source = "中文 \\(x_1^2\\)；\\(y\\)\n$$\\frac{a}{b}\n+ c$$\n\\[\\sqrt{x}\\]";
    var it: Iterator = .init(source, .{});
    const first = it.next().?;
    try std.testing.expectEqualStrings("\\(x_1^2\\)", first.source.slice(source));
    try std.testing.expectEqualStrings("x_1^2", first.body.slice(source));
    try std.testing.expect(!first.delimiter.display());
    try std.testing.expectEqualStrings("y", it.next().?.body.slice(source));
    const block = it.next().?;
    try std.testing.expect(block.delimiter.display());
    try std.testing.expectEqualStrings("\\frac{a}{b}\n+ c", block.body.slice(source));
    try std.testing.expectEqualStrings("\\sqrt{x}", it.next().?.body.slice(source));
    try std.testing.expect(it.next() == null);
}

test "ghosttex math excludes code escapes prices and shell variables" {
    const source =
        "`\\(code\\)` `` ` $$code$$ ` ``\n" ++
        "```sh\n\\[code\\]\n~~~\n$$code$$\n````\n" ++
        "  ~~~tex\n\\(code\\)\n  ~~~\n" ++
        "    \\(indented\\)\n\t$$indented$$\n" ++
        "\\\\(escaped\\\\) \\$5 $10 $HOME ${PATH} $HOME/$PATH\n" ++
        "prices $5 and $10; \\(ok\\)";
    var it: Iterator = .init(source, .{ .single_dollar = true });
    try std.testing.expectEqualStrings("ok", it.next().?.body.slice(source));
    try std.testing.expect(it.next() == null);
}

test "ghosttex math single dollars opt in and boundary rules" {
    const source = "$x$ and $2^2$，$y$ $ a $ $$$ambiguous$$$ $z $\n\\(ok\\)";
    var defaults: Iterator = .init(source, .{});
    try std.testing.expectEqualStrings("ok", defaults.next().?.body.slice(source));
    try std.testing.expect(defaults.next() == null);
    var it: Iterator = .init(source, .{ .single_dollar = true });
    for ([_][]const u8{ "x", "2^2", "y", "ok" }) |expected|
        try std.testing.expectEqualStrings(expected, it.next().?.body.slice(source));
    try std.testing.expect(it.next() == null);
}

test "ghosttex dollar math preserves shell expansions without disabling inline formulas" {
    const cases = [_][]const u8{
        "DB_URL=\"$(cat /tmp/cache/local-dsn)\" RELAY=\"http://127.0.0.1:$(cat /tmp/cache/port)\"",
        "DB_URL=$(cat /tmp/dsn) RELAY=$(cat /tmp/port)",
        "echo $(printf '%s' '$not_math$')",
        "echo $(cat \"${NAME:-$(cat /tmp/name)}\")",
        "echo $((1 + $(cat /tmp/number)))",
        "echo ${ROOT:-/tmp} ${NAME:-default}",
        "echo $(pwd)/${NAME}",
        "echo \"$HOME\" \"$PATH\"",
    };
    for (cases) |command| {
        for (0..command.len + 1) |length| {
            // A trailing '$' alone can be a valid math end. The following
            // byte is needed to distinguish an unquoted expansion opener.
            if (length > 0 and length < command.len and command[length - 1] == '$') continue;
            var partial: Iterator = .init(command[0..length], .{ .single_dollar = true });
            errdefer std.debug.print("partial shell source: {s}\n", .{command[0..length]});
            try std.testing.expect(partial.next() == null);
        }
        var buffer: [1024]u8 = undefined;
        const source = try std.fmt.bufPrint(&buffer, "{s} $x^2$ \\(y\\) $$z$$", .{command});
        var it: Iterator = .init(source, .{ .single_dollar = true });
        for ([_][]const u8{ "x^2", "y", "z" }) |expected| {
            const formula = it.next() orelse return error.MissingInlineFormula;
            try std.testing.expectEqualStrings(expected, formula.body.slice(source));
        }
        try std.testing.expect(it.next() == null);
    }
}

test "ghosttex dollar math retains parenthesized grouped quoted and adjacent formulas" {
    const source = "$x$ $(a+b)$ $(a+b)^2$ $(x) + y$ ${x_i}$ $((x+y)/2)$ \"$(x)^2$\" '$(x)^2$' $(x)'$ $x$(y) $(x)$(y) ${x}$(y)";
    var it: Iterator = .init(source, .{ .single_dollar = true });
    for ([_][]const u8{ "x", "(a+b)", "(a+b)^2", "(x) + y", "{x_i}", "((x+y)/2)", "(x)^2", "(x)^2", "(x)'", "x", "(x)", "{x}" }) |expected| {
        const formula = it.next() orelse return error.MissingInlineFormula;
        try std.testing.expectEqualStrings(expected, formula.body.slice(source));
    }
    try std.testing.expect(it.next() == null);
}

test "ghosttex math unclosed source code context and bounded candidates" {
    const source = "\\(unfinished\n\\[unfinished\n```\n\\(code\\)\n```\n\\(12345\\) \\(ok\\)";
    var it: Iterator = .init(source, .{ .max_source_bytes = 4 });
    try std.testing.expectEqualStrings("ok", it.next().?.body.slice(source));
    try std.testing.expect(it.next() == null);
    var code: Iterator = .init("`unclosed\n\\(hidden\\)", .{});
    try std.testing.expect(code.next() == null);
}

test "ghosttex math incomplete snapshots only emit closed formulas" {
    const source = "中文 \\(\\frac{a}{b}\\)\n\\[x^2\\]";
    // Every byte prefix includes cuts through UTF-8, TeX commands, and both
    // delimiter bytes. An immutable snapshot may be rescanned after an update;
    // this test does not claim to implement incremental terminal invalidation.
    const first_end = std.mem.indexOf(u8, source, "\\)").? + 2;
    for (0..source.len + 1) |end| {
        var it: Iterator = .init(source[0..end], .{});
        if (end >= first_end) {
            try std.testing.expectEqualStrings("\\frac{a}{b}", it.next().?.body.slice(source));
        }
        if (end == source.len) try std.testing.expectEqualStrings("x^2", it.next().?.body.slice(source));
        try std.testing.expect(it.next() == null);
    }
}

test "ghosttex math empty bodies and backslash before hard newline" {
    const source = "\\(\\) $$ \t$$ \\[\n\\]\n\\(a\\\nb\\)\n\\(ok\\)";
    var it: Iterator = .init(source, .{});
    try std.testing.expectEqualStrings("ok", it.next().?.body.slice(source));
    try std.testing.expect(it.next() == null);
}

test "ghosttex math checkpoint carries code context between snapshots" {
    const source = "```tex\n\\(hidden\\)\n```\n\\(visible\\)";
    var checkpoints: [8]Checkpoint = undefined;
    var iterator: Iterator = .init(source, .{});
    iterator.checkpoints = &checkpoints;
    try std.testing.expectEqualStrings("visible", iterator.next().?.body.slice(source));
    try std.testing.expect(iterator.next() == null);
    try std.testing.expect(iterator.checkpoint_count >= 4);
    var resumed: Iterator = .init(source[checkpoints[1].offset..], .{});
    checkpoints[1].restore(&resumed);
    try std.testing.expectEqualStrings("visible", resumed.next().?.body.slice(resumed.source));
    try std.testing.expect(resumed.next() == null);
}

test "ghosttex math marked messages stop unfinished code and formulas" {
    const first = "```unclosed\n\\(hidden\\)\n";
    const source = first ++ "\\(visible\\)\n\\[unfinished\n" ++ "\\(next\\)";
    const second = first.len + "\\(visible\\)\n\\[unfinished\n".len;
    var iterator: Iterator = .init(source, .{});
    iterator.boundaries = &.{ first.len, second };
    try std.testing.expectEqualStrings("visible", iterator.next().?.body.slice(source));
    try std.testing.expectEqualStrings("next", iterator.next().?.body.slice(source));
    try std.testing.expect(iterator.next() == null);
}

test "ghosttex explicit inline output may wrap without consuming new formulas or code" {
    const source = "before \\(\\frac{a}{b}\n+c\\) after \\(unfinished\n\\(next\\)\n" ++
        "\\(unfinished\n```\n\\(code\\)\n```\n\\(last\\)";
    var it: Iterator = .init(source, .{ .multiline_paren = true });
    for ([_][]const u8{ "\\frac{a}{b}\n+c", "next", "last" }) |expected|
        try std.testing.expectEqualStrings(expected, it.next().?.body.slice(source));
    try std.testing.expect(it.next() == null);
    const bounded = "\\(unfinished\n\\(next\\)";
    var messages: Iterator = .init(bounded, .{ .multiline_paren = true });
    messages.boundaries = &.{"\\(unfinished\n".len};
    try std.testing.expectEqualStrings("next", messages.next().?.body.slice(bounded));
    try std.testing.expect(messages.next() == null);
}
