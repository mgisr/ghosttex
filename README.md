<p align="center">
  <img src="images/ghosttex-icon.png" width="160" alt="Ghosttex icon: a terminal ghost with a summation symbol">
</p>

<h1 align="center">Ghosttex</h1>
<p align="center">A native terminal with native TeX rendering.</p>
<p align="center">English · <a href="README.zh-CN.md">简体中文</a></p>

Ghosttex is a [Ghostty](https://github.com/ghostty-org/ghostty) fork that detects, typesets, and caches TeX formulas inside the terminal. Formulas and ordinary text share the terminal rendering pipeline, without adapters for individual shell programs.

**Current release: 0.1.2.** Download the macOS Apple Silicon package and SHA-256 checksum from [GitHub Releases](https://github.com/mgisr/ghosttex/releases/latest). Dynamic formula layout is still being improved. Automated checks and known limits are described below; fast scrolling, selection, input, and partial redraws in real programs need continued validation.

## Install on macOS

Extract `ghosttex-macos-arm64.zip`, move `Ghosttex.app` to `/Applications`, and open it from there. Save your work and quit an older version before replacing the app. Your configuration stays in your user directory.

The package is ad hoc signed, without an Apple Developer ID signature or notarization. macOS may require allowing the first launch in **System Settings → Privacy & Security**. Only an arm64 package is provided, tested locally on macOS 27.0.1; earlier systems have not been validated.

Verify the downloaded archive from the directory containing both files:

```sh
shasum -a 256 -c ghosttex-macos-arm64.zip.sha256
```

Ghosttex does not use Ghostty's upstream automatic update feed. Download updates from this repository's Releases page.

## Features

- **Native formula typesetting:** RaTeX and transparent image caching support `\(...\)`, `\[...\]`, `$$...$$`, and optionally `$...$`.
- **Dynamic inline layout:** Text flows around formulas at their rendered width. Only visual lines that need space grow taller; formulas and adjacent text align to the bottom. Ordinary text keeps its normal line height.
- **Centered display math:** Standalone formula blocks are centered in their region. Verified fragments crossing viewport boundaries reuse the complete image with clipping.
- **Preserved logical grid:** Source text, PTY dimensions, and VT coordinates stay intact. Visual positions map back to original characters for mouse input, selection, the cursor, and IME.
- **Independent of programs:** No detection by program name, version, or interface. Programs that request mouse reporting or alternate-screen scroll-to-key events receive the complete wheel event.

The current validation focus is **macOS / Metal**. Linux / OpenGL shares the layout code, but Linux GUI validation was not completed for this release. Updated Windows icon assets do not imply an available Windows build.

## Configuration

The macOS configuration file is:

```text
~/Library/Application Support/org.ghosttex.terminal/config.ghosttex
```

`~/.config/ghosttex/config.ghosttex` is also supported. Builds with math support enable rendering by default. You can set it explicitly:

```ini
math-rendering = true
math-single-dollar = false
keybind = ctrl+shift+m=toggle_math_rendering
```

Single-dollar syntax can conflict with prices and shell variables, so it is off by default. Unclosed formulas, unknown context, active edits, and typesetting failures retain their source text. If a program has already converted TeX into other characters, the terminal cannot restore source it never received.

When single-dollar recognition is enabled, balanced shell substitutions and parameter expansions are kept as source when pairing dollars would cross into another expansion or quoted word. Ordinary `$x$`, `$(x+y)^2$`, and `${x_i}$` formulas remain supported. Recognition is lexical and independent of the program producing the text; single-dollar syntax remains a heuristic.

## Build a macOS Release package

Use the repository's **Zig 0.17.0**, **Rust 1.90.0**, Xcode 26+, the macOS 26 SDK or newer, and Metal Toolchain. Complete Xcode's first-launch setup and component installation first.

```sh
rustup toolchain install 1.90.0 --profile minimal
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  bash scripts/build-macos.sh "$PWD/dist/ghosttex-macos-local"
```

The output directory contains `Ghosttex.app`, a ZIP archive, and its SHA-256 checksum. Use a fresh output directory for each build. The script builds the core with **ReleaseFast** and the macOS interface with the optimized **ReleaseLocal** configuration. It does not replace an installed app or change user configuration.

```sh
"$PWD/dist/ghosttex-macos-local/Ghosttex.app/Contents/MacOS/ghosttex"
```

## Validation and current limits

```sh
zig test src/math/Viewport.zig
zig build test -Dmath=true -Doptimize=ReleaseFast \
  -Dxcframework-target=native -Demit-macos-app=false -Dtest-filter=ghosttex
cargo test --locked --manifest-path native/ghosttex-math/Cargo.toml
```

Regression tests cover line height, bottom alignment, horizontal spacing, wide characters, hit mapping, IME, frame-commit fallback, and bidirectional scrolling, source text, cursor state, and VT modes on the main and alternate screens. The macOS package can also be checked for its signature, icon, build mode, default configuration, startup, and native VT replies:

```sh
python3 test/ghosttex/verify_macos_release.py /path/to/Ghosttex.app
```

Scrolling regions declared through the VT protocol constrain the visual projection. Without declared boundaries, the terminal does not guess where a fixed input bar is. Formula fragments that were never fully observed or match ambiguously remain as source. Dynamic layout has not completed real-program interaction validation and does not promise compatibility with every TUI's fixed regions and partial redraws.

See [GHOSTTEX.md](GHOSTTEX.md) (Chinese) for architecture, cache limits, dependencies, and validation details.

## Attribution

Ghosttex is an independently maintained Ghostty fork. Ghostty's license, copyright, and upstream attribution are preserved. The original upstream introduction is archived in [docs/upstream/README.md](docs/upstream/README.md).

For compatibility, the `xterm-ghostty` terminfo entry, `ghostty_*` C ABI, and some internal library, module, and resource names retain their upstream identifiers. The app name, configuration directory, menus, and command-line branding use Ghosttex.

The new icon was derived from the upstream Ghostty icon using the built-in image generation tool. The [source image](images/ghosttex-icon.png) and [generation prompt and provenance](images/ghosttex-icon-prompt.txt) are included in the repository.
