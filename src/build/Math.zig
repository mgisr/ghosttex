//! Optional native Rust math dependency. Disabled builds require no Rust.
const std = @import("std");
const builtin = @import("builtin");
const Config = @import("Config.zig");

pub const Artifacts = struct { library: std.Build.LazyPath, worker: std.Build.LazyPath };

pub fn init(b: *std.Build, config: *const Config) !?Artifacts {
    if (!config.math or config.emit_lib_vt) return null;
    const target = config.target.result;
    if (target.os.tag != builtin.os.tag or target.cpu.arch != builtin.cpu.arch or
        (target.os.tag != .linux and target.os.tag != .macos))
        return error.MathRequiresNativeLinuxOrMacOS;
    const cargo = b.addSystemCommand(&.{ "cargo", "+1.90.0", "build", "--locked", "--release", "--manifest-path" });
    cargo.addFileArg(b.path("native/ghosttex-math/Cargo.toml"));
    cargo.addArg("--target-dir");
    const output = cargo.addOutputDirectoryArg("ghosttex-math");
    // Cargo tracks transitive, revision-pinned sources; these are our local
    // inputs. Side effects make Cargo itself handle incremental recompilation.
    cargo.has_side_effects = true;
    const worker = output.path(b, "release/ghosttex-math-worker");
    b.getInstallStep().dependOn(&b.addInstallFile(worker, "bin/ghosttex-math-worker").step);
    for ([_][]const u8{ "RaTeX.txt", "KaTeX-fonts.txt", "KaTeX-fonts-NOTICE.txt", "THIRD_PARTY.txt" }) |name| {
        b.getInstallStep().dependOn(&b.addInstallFile(
            b.path(b.fmt("native/ghosttex-math/licenses/{s}", .{name})),
            b.fmt("share/ghosttex/licenses/{s}", .{name}),
        ).step);
    }
    return .{ .library = output.path(b, "release/libghosttex_math.a"), .worker = worker };
}
