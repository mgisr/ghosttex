#!/bin/bash
# Build a native-architecture test app on a Mac; never replaces an installed app.
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Run this script on macOS with Xcode 26+, the macOS 26 SDK, and Metal Toolchain.' >&2
  exit 1
fi

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"
for tool in zig cargo rustup xcodebuild xcrun codesign ditto; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
if [[ "$(zig version)" != 0.17.0 ]]; then
  echo 'This source tree requires Zig 0.17.0.' >&2
  exit 1
fi
xcode_version="$(xcodebuild -version | awk '/^Xcode / { print $2; exit }')"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
if [[ "${xcode_version%%.*}" -lt 26 || "${sdk_version%%.*}" -lt 26 ]]; then
  echo 'Select Xcode 26+ with the macOS 26 SDK before building.' >&2
  exit 1
fi
if ! rustup run 1.90.0 rustc --version >/dev/null 2>&1; then
  echo 'Install the pinned Rust toolchain: rustup toolchain install 1.90.0 --profile minimal' >&2
  exit 1
fi

arch="$(uname -m)"
output_dir="${1:-$repo_dir/dist/ghosttex-macos-$arch}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
app_path="$output_dir/Ghosttex.app"
zip_path="$output_dir/ghosttex-macos-$arch.zip"
if [[ -e "$app_path" || -e "$zip_path" ]]; then
  echo "Output already exists; choose a fresh directory: $output_dir" >&2
  exit 1
fi

stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/ghosttex-macos.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
# The Rust library is built for this Mac. A universal XCFramework would also
# need a separate Rust build for the other architecture.
zig build -Doptimize=ReleaseSafe -Dmath=true -Dxcframework-target=native \
  -Demit-macos-app=true -Demit-xcframework=true -Demit-docs=false \
  --prefix "$stage_dir/install"

cp -R "$stage_dir/install/Ghostty.app" "$app_path"
cp "$stage_dir/install/bin/ghosttex-math-worker" "$app_path/Contents/MacOS/"
mkdir -p "$app_path/Contents/Resources/ghosttex-licenses"
cp "$stage_dir/install/share/ghosttex/licenses/"* "$app_path/Contents/Resources/ghosttex-licenses/"
codesign --force --sign - --timestamp=none "$app_path/Contents/MacOS/ghosttex-math-worker"
codesign --force --deep --sign - --timestamp=none "$app_path"
codesign --verify --deep --strict "$app_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"
shasum -a 256 "$zip_path" > "$zip_path.sha256"
printf 'Test app: %s\nArchive: %s\n' "$app_path" "$zip_path"
printf 'Launch with math enabled:\n  "%s/Contents/MacOS/ghostty" --math-rendering=true --math-single-dollar=true\n' "$app_path"
