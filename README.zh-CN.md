<p align="center">
  <img src="images/ghosttex-icon.png" width="160" alt="Ghosttex 图标：终端幽灵与求和符号">
</p>

<h1 align="center">Ghosttex</h1>
<p align="center">A native terminal with native TeX rendering.</p>
<p align="center"><a href="README.md">English</a> · 简体中文</p>

Ghosttex 基于 [Ghostty](https://github.com/ghostty-org/ghostty)，在终端内部识别、排版和缓存 TeX 公式。公式与普通文字共用终端绘制路径，无需为 shell 中的程序添加专用适配器。

**当前发布版本：0.1.2。** 从 [GitHub Releases](https://github.com/mgisr/ghosttex/releases/latest) 下载 macOS Apple Silicon 安装包及 SHA-256 校验文件。动态公式布局仍在持续改进；发布包通过的自动检查及已知限制见下文，真实程序中的快速滚动、选择、输入和局部刷新仍需持续验证。

解压 ZIP 后，将 `Ghosttex.app` 拖入 `/Applications`，再从应用程序目录打开。安装包使用本地 ad hoc 签名，未进行 Developer ID 签名或公证，macOS 可能要求在“系统设置 → 隐私与安全性”中允许首次打开。当前仅提供 arm64 安装包，并在本机 macOS 27.0.1 上验证；更早系统尚未验收。

## 能做什么

- **原生公式排版**：使用 RaTeX 和透明图像缓存，支持 `\(...\)`、`\[...\]`、`$$...$$`，可选启用 `$...$`。
- **行内动态布局**：按公式实际宽度排正文，只增高需要空间的视觉行；公式与相邻正文底部对齐，普通文字行不全局增高。
- **行间公式居中**：独立公式块在其区域内居中，已验证的跨视口片段复用完整图像并裁剪。
- **保留逻辑网格**：源码、PTY 尺寸和 VT 坐标保持原样，视觉位置映射回原始字符，供鼠标、选择、光标及 IME 使用。
- **与程序无关**：不识别程序名称、版本或界面特征。程序已请求鼠标报告或备用屏幕滚轮转按键时，完整转交滚轮事件。

当前验证重点是 **macOS / Metal**。Linux / OpenGL 共用布局代码，但本轮未完成 Linux GUI 验证；Windows 图标资源已同步，不表示已有可用的 Windows 版本。

## 构建 macOS Release 包

需要仓库指定的 **Zig 0.17.0**、**Rust 1.90.0**、Xcode 26+、macOS 26 SDK 和 Metal Toolchain。先完成 Xcode 首次启动及所需组件安装。

```sh
rustup toolchain install 1.90.0 --profile minimal
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  bash scripts/build-macos.sh "$PWD/dist/ghosttex-macos-local"
```

输出目录包含 `Ghosttex.app`、ZIP 和 SHA-256。每次构建需使用新的输出目录。脚本以 **ReleaseFast** 构建核心、以优化的 **ReleaseLocal** 配置构建 macOS 界面，不覆盖已安装的应用，也不修改用户配置。

```sh
"$PWD/dist/ghosttex-macos-local/Ghosttex.app/Contents/MacOS/ghosttex"
```

应用使用本地 ad hoc 签名，未进行 Developer ID 签名或公证。Ghosttex 不连接上游 Ghostty 的自动更新源；更新请从本仓库的 Releases 页面下载。

## 配置

macOS 配置文件位于：

```text
~/Library/Application Support/org.ghosttex.terminal/config.ghosttex
```

也支持 `~/.config/ghosttex/config.ghosttex`。数学构建默认启用公式渲染，可显式设置：

```ini
math-rendering = true
math-single-dollar = false
keybind = ctrl+shift+m=toggle_math_rendering
```

单美元符号与价格、shell 变量可能存在歧义，因此默认关闭。未闭合、上下文未知、正在编辑或排版失败的公式保留源码。程序如果已经把 TeX 转换成其他字符，终端无法恢复未收到的源码。

开启单美元识别后，配对若会跨入另一处 Shell 展开或引号外的词，已闭合的命令替换和参数展开保留源码；普通 `$x$`、`$(x+y)^2$`、`${x_i}$` 公式继续支持。这是与输出程序无关的词法识别，单美元语法仍存在固有歧义。

## 验证与当前边界

```sh
zig test src/math/Viewport.zig
zig build test -Dmath=true -Doptimize=ReleaseFast \
  -Dxcframework-target=native -Demit-macos-app=false -Dtest-filter=ghosttex
cargo test --locked --manifest-path native/ghosttex-math/Cargo.toml
```

回归覆盖行高、底部对齐、横向间距、宽字符、命中映射、IME、帧提交回退，以及主/备用屏幕下的双向滚动、源码、光标和 VT 模式。macOS 包还可检查签名、默认配置、启动和原生 VT 回复：

```sh
python3 test/ghosttex/verify_macos_release.py /path/to/Ghosttex.app
```

程序通过 VT 协议声明的滚动边界会限制视觉投影范围；没有声明边界时，终端不会猜测固定输入栏。未曾完整观察过或匹配有歧义的公式片段继续显示源码。通用动态布局尚未完成真实程序交互验收，不能承诺兼容任意 TUI 的固定区域及刷新方式。

架构、缓存限制、依赖和验证细节见 [GHOSTTEX.md](GHOSTTEX.md)。

## 项目归属

Ghosttex 是独立维护的 Ghostty 分支。保留 Ghostty 的许可证、版权与上游归属；原上游介绍存档于 [docs/upstream/README.md](docs/upstream/README.md)。

为保留兼容性，`xterm-ghostty` terminfo、`ghostty_*` C ABI、部分库/模块和资源文件名继续使用上游标识。应用名称、配置目录、菜单和命令行品牌为 Ghosttex。

新图标基于上游 Ghostty 图标衍生，使用内置图像生成工具制作；[图标源图](images/ghosttex-icon.png)与[生成提示及来源记录](images/ghosttex-icon-prompt.txt)随仓库保存。
