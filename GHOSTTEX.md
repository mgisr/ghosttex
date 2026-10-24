# Ghosttex：目标、边界与首轮验证

目标是在 Ghostty 中识别 agent 输出里的 Markdown 行内、块级公式，通过
RaTeX 原生排版，支持动态高度，同时保持输入和滚动流畅。首个验收对象为
**Linux + Codex CLI**；macOS/Metal 在共享布局模型稳定后验证。

已实现默认关闭的原生渲染原型；完整目标尚未验收完成。遇到不能证明兼容的输出区域时，
保留源码是必要的降级行为，不能用遮挡正文的图片代替动态布局。

## 当前基线与进度

| 项目           | 当前状态                                                                               |
| -------------- | -------------------------------------------------------------------------------------- |
| Ghostty 基线   | `08a951834`，`1.3.2-dev`                                                               |
| Zig            | 仓库要求 `0.17.0`                                                                      |
| 首轮平台       | Linux x86_64，GTK/OpenGL                                                               |
| 首轮 CLI       | Codex CLI；真实窗口验收前记录准确版本和启动参数                                        |
| RaTeX 候选基线 | `28fa5a7c800172af00043270c0acc85bd0c60155`，工作区版本 `0.1.15`                        |
| RaTeX 依赖     | Rust 1.90.0 + 固定提交；已接入 Zig 构建、字体、SVG 轮廓与透明 RGBA                     |
| 已实现         | 公式识别、上下文检查点、异步队列、共享缓存、块级/行内投影、GPU 纹理与源码切换          |
| 已加入测试     | VT 边界、原生 ABI、布局、缓存、隔离进程超时；GTK/OpenGL 窗口、输入、DSR 和固定底部区域 |
| 尚未实现       | 逐脏行增量扫描、跨视口部分公式的连续布局、阅读锚点、复杂 TUI 适配及完整发布/性能验收   |

已有的应用名称、配置目录、应用 ID、`TERM`、终端协议和 libghostty ABI 暂沿用
Ghostty。独立安装包需要另立重命名清单，保留上游版权与许可，避免全局文本替换。

## 识别与输入约定

`src/terminal/markdown_math.zig` 提供 `Iterator`，输入为不可变的、已解码的
UTF-8 文本快照，输出包括分隔符的 `source` 范围、不包括分隔符的 `body` 范围，
以及行内/块级类型。范围均为字节偏移，不是终端列号。解析器不修改原文。

| 语法                                           | 首轮规则                                               |
| ---------------------------------------------- | ------------------------------------------------------ |
| `\(...\)`                                      | 默认开启，只跨软换行，不跨硬换行                       |
| `\[...\]`                                      | 默认开启，可跨硬换行；空行或新的代码围栏中止未闭合候选 |
| `$$...$$`                                      | 默认开启，同上；三个及以上连续美元符号作为普通文本     |
| `$...$`                                        | `Options.single_dollar` 显式开启，默认关闭             |
| 空公式、未闭合公式                             | 显示源码，不提交排版                                   |
| 自定义宏、完整文档、宏包、外部文件、跨文档引用 | 首轮不支持；不建立跨公式宏环境                         |

单美元规则仅为启发式：开始后、结束前不得为空白；开始前不得为 ASCII 字母、
数字、下划线或 `/`；结束后不得为 ASCII 字母、数字或下划线。
`$x$`、`$2^2$` 可识别，常见价格与 `$HOME/$PATH` 保留源码。它无法区分所有
货币文本和数学表达式，因此不能据此默认启用任意 shell 输出里的单美元识别。
相邻公式优先写成 `\(x\)\(y\)`；`$x$$y$` 不承诺拆成两个公式。

跳过反引号/波浪线围栏、缩进代码和匹配长度的代码段，并检查列表/引用的围栏前缀。
支持转义反斜杠的奇偶性；未闭合代码保守隐藏后续公式。它仍是 Markdown 子集，
不是完整 CommonMark 实现。OSC 133 的输入/输出边界会重置解析上下文，
已标记的输入内容不参与公式渲染。

每个公式正文默认最多 16 KiB；超长候选保留源码。识别器只顺序扫描，不回溯，
不为公式复制字符串。长度上限不等于整个快照或后台任务的内存上限。

### 源码来源

1. 缓冲区路径：PTY 字节 → Ghostty VT 解析 → 有版本的快照 → 公式识别。
   使用 `ScreenFormatter` 的 `.plain`、`unwrap=true`、`trim=false` 和 `PinMap`
   可验证软换行拼接、硬换行保留与字节到单元格的映射。
2. 可选标记路径：未来由 agent 提供原始 Markdown、消息身份和输出范围。
   具体终端控制协议尚未选择，必须限制大小、校验生命周期并允许用户关闭。

不能绕过 VT 解析去旁路匹配 PTY 字节，也不能声称从缓冲区恢复了 CLI 已删除的
反斜杠、美元符号或原始换行。未保留分隔符的 Codex 输出需要经过实测后选择
标记接口或降级，不能靠猜测补回 TeX。

原型在终端内容变化时重建有界快照，并保存硬换行处的代码上下文检查点。
最多向上捕获 128 行、快照 256 KiB、每 surface 保存 4096 个上下文检查点。
围栏已离开视口时仍可继承上下文；上下文无法证明正确时保留源码。
它不在每一帧或每个 token 上扫描全部历史，但尚未完成逐脏行的增量提取。
已加入跨视口块公式的纹理裁剪原型，按可见源码行比例裁剪，复用完整公式缓存；
跨视口行内公式仍回退源码。这还不是连续的视觉滚动布局，缓存滚动验收仍未完成。

## 架构约定

### 逻辑网格与视觉布局

PTY 行列、光标移动、保存/恢复、插入删除、擦除、滚动区域、原点模式、待换行
状态和 DSR 查询均继续作用于 Ghostty 的逻辑字符网格。公式高度不改变 PTY
窗口尺寸，避免 agent 因视觉展开反复重排。

另建视觉布局层，维护正文片段、公式片段、空白与受保护区域，并提供：

- 逻辑单元格/源码范围 → 一个或多个视觉矩形；
- 视觉位置 → 逻辑单元格、公式范围或额外留白；
- 阅读锚点 → 高度变化、窗口重排后的新滚动位置。

块级公式先验证独占逻辑行的情形：左对齐、上下各半行留白，最大宽度为正文
宽度；过宽时等比缩小，低于可读字号则回退源码。行内公式随后加入段落排版，
同一视觉行按最大 ascent/descent 计算高度，保留中文、标点、基线和软换行语义。
不能把所有坐标转换简化为统一行号偏移。

Codex 的底部输入区、顶部栏和弹窗不能从普通字符网格可靠推断。需要在固定
Codex 版本上验证可识别的正文区域，必要时使用可选标记或适配器。区域不明确、
备用屏幕、鼠标抓取和不支持的局部刷新组合先显示源码。主屏幕也可能运行 TUI，
不能把“主屏幕”等同于“追加输出”。输入区公式首轮不渲染。

### 内容身份与失效

区域身份包含 surface/screen 生命周期、单调 ID、源码版本和逻辑范围。
`PageList.trackPin` 可跟随重排，但 pin 被回收后可能移到屏幕左上并标记
`garbage`；必须显式撤销。有效 pin 也不能证明单元格内容未被覆盖。

每次覆盖、局部清屏、行列插入删除、重排、历史回收和屏幕切换，需要重新验证
受影响的源码与版本。相同 TeX 可共享排版和纹理，显示位置各自持有独立身份。
全屏重绘不能通过“发现相同源码”继承已经无效的区域身份。

后台任务只读有界快照，提交前校验区域身份、源码版本、字号、宽度、DPI、字体
和主题版本。标签页关闭、关闭功能和屏幕销毁必须撤销任务及引用。过期结果
被丢弃并不表示计算已中止：仍需限制计算规模和占用时间。

### RaTeX、字体与原生绘制

已固定 RaTeX 提交和 Rust 1.90.0。`-Dmath=true` 构建静态桥接库及独立
`ghosttex-math-worker`；关闭该构建选项不需要 Rust。当前只接受本机 Linux/macOS
目标，禁止把本机 Rust 库误用于另一架构。macOS 的实际构建和窗口尚未验证。

桥接使用自有的 C ABI 1，见 `native/ghosttex-math/ghosttex_math.h`。
Rust 缓冲区仅由配套 free 函数释放，错误信息存放在独立结果中。
Zig 不跨语言解码 DisplayList JSON：解析、类型化布局、字体轮廓转换均留在 Rust；
生产路径返回经检查的 RGBA、尺寸和基线。

RaTeX 原有 C ABI 返回 DisplayList JSON，不返回 RGBA。原型通过 RaTeX 的嵌入字体
与 SVG 轮廓输出，再由 resvg 栅格化。未找到字体轮廓、超过尺寸预算或不能解析时，
整式回退源码；没有 PNG 编解码、终端图片协议或外部 TeX 进程。
数学字体及 Rust 依赖的许可记录随构建安装到 `share/ghosttex/licenses/`。

宽度、ascent `height` 和 descent `depth` 单位均为 em；总像素高度为
`(height + depth) × font_px`，基线为 `height × font_px`。DisplayList 的
`GlyphPath` 不自带字形轮廓，宿主须提供匹配的数学字体资源。中文/Unicode
回退需同时提供匹配的字体度量，字体缺失保留源码。

后台返回紧密排列、straight alpha、sRGB RGBA8，复用图片模块上传/裁剪/释放，
使用独立 math 图片 ID 命名空间。来源字形缓冲区始终保留；上传失败即回退完整源码视图。
共享绘制路径覆盖 OpenGL/Metal，当前只验证了 GTK/OpenGL 软件渲染窗口。

### 调度、缓存与限额

当前原型的限额如下；峰值与长期稳定性仍需验收：

| 资源                    | 初始限制                                                  |
| ----------------------- | --------------------------------------------------------- |
| 公式正文                | 16 KiB；固定 RaTeX 版本的解析深度上限 32                  |
| 后台队列 / 并发         | 32 个排队请求 / 每应用 1 个调度线程和隔离排版进程         |
| 单张纹理                | 边长不超过 4096 px，总像素不超过 4 Mi，RGBA 不超过 16 MiB |
| CPU 像素 / GPU 纹理缓存 | 每个应用分别 64 MiB / 128 MiB；多标签页共享总预算         |
| 持久区域                | 每个视口最多 512 个公式；共享 CPU 缓存最多 512 条         |

布局、CPU 像素和 GPU 纹理分层缓存。键包含源码、显示模式、RaTeX/协议版本、
字体版本、字号、DPI、宽度约束及颜色策略；滚动位置不入键。去重不复用区域
身份，滚动复用结果只更新位置与裁剪。初版不做磁盘缓存。

可见请求优先，相同请求合并，过期请求在执行前跳过。解析失败按源码和引擎
版本缓存；字体、宽度、GPU 失败在对应条件改变后允许重试。实际排版已放入独立 helper：
每请求最多 2 秒；Linux 进程地址空间上限 768 MiB，macOS 暂无对应的硬内存上限，
仍受输入、输出、队列与超时限制。超时、取消或异常退出会终止
进程组并允许之后的请求重启。退出/关闭最后一个 context 时最多每 5 ms 检查取消，
不等待一个已经过时的排版请求用满超时。进程预算包含字体与布局，
不等于 64 MiB 的父进程像素缓存预算。

### 交互、配置与回退

选择、复制与搜索基于逻辑源码，默认复制带原分隔符的 Markdown，不插入视觉
展开产生的空行。跨正文和公式保持原顺序；搜索结果通过视觉映射高亮。
额外留白的点击落到公式范围，公式内部选择按原始范围处理，之后再评估局部
TeX 选择。拖选、链接、鼠标报告、滚轮和 IME 坐标均须统一经过视觉映射。

已提供默认关闭的 `math-rendering`、可选 `math-single-dollar`、
`math-protected-bottom-rows` 和 `toggle_math_rendering` 动作。输入/鼠标通过已呈现帧的
逆映射回到逻辑网格，IME 使用前向位置；复制/搜索继续使用原始终端源码。
关闭会撤销视觉投影与后台引用，CPU/GPU 资源按生命周期释放。复杂选择、
任意位置源码切换后的阅读锚点及快速跨视口滚动仍需进一步验证。

## 构建与使用原型

```sh
zig build -Dmath=true
./zig-out/bin/ghostty --math-rendering=true
```

需要 Zig 0.17.0、rustup/Cargo、Rust 1.90.0 和原有 Ghostty GUI 依赖。第一次构建
会按 Cargo.lock 拉取固定依赖。保持 helper 与应用可执行文件相邻。
Unicode 使用系统字体；可在启动前用 `RATEX_UNICODE_FONT` 指定匹配的 TTF/TTC。

```ini
math-rendering = true
math-single-dollar = false
math-protected-bottom-rows = 0
keybind = ctrl+shift+m=toggle_math_rendering
```

保护行数为 0 时，普通输入随正文流动；已知固定输入区的 CLI 可显式配置保护行数。
这不是对任意全屏 CLI 输入区的自动检测。

### macOS 本机测试构建

需要 Xcode 26+、macOS 26 SDK、Metal Toolchain、Zig 0.17.0 和 Rust 1.90.0。
在 Apple Silicon 或 Intel Mac 上按本机架构构建：

```sh
rustup toolchain install 1.90.0 --profile minimal
bash scripts/build-macos.sh
```

脚本使用 `-Dxcframework-target=native`，避免将本机 Rust 库链接进另一架构。
输出在 `dist/ghosttex-macos-$(uname -m)/`：`Ghosttex.app`、ZIP 与 SHA-256。
helper 放在 `Contents/MacOS/`，依赖许可放在 Resources 中；只做本地 ad hoc
签名，没有 Developer ID 签名或公证。不会覆盖已安装的 Ghostty 或修改用户配置，
应用 ID、配置目录和界面名称仍沿用 Ghostty。此路径尚未经 macOS 实际编译或窗口验收。

```sh
"dist/ghosttex-macos-$(uname -m)/Ghosttex.app/Contents/MacOS/ghostty" \
  --math-rendering=true --math-single-dollar=true
```

再次构建可用 `bash scripts/build-macos.sh /path/to/new-output` 指定新输出目录；
已有的 app 或 ZIP 不会被覆盖。

### Codex 的版本/配置差异

已验证 Linux Codex CLI 0.163.0 默认会把部分 TeX 转成 Unicode 字符。
源码入口是 `markdown_render/math.rs`；`tui.rendering.math` 默认开启，支持：

```sh
codex -c tui.rendering.math=false
```

它不是 Linux 专属代码。用户提供的 macOS 环境仍保留 TeX，支持直接缓冲区接入；
尚未取得该环境的版本与窗口验收数据，不能把本机行为外推为 macOS 的结论。

关闭 Codex 公式转换后，代码区的 Markdown 标记仍可能被其 TUI 移除。因此
Linux 0.163.0 的已知 TUI 输出默认保守回退，避免把代码里的 TeX 渲染成公式。
该保护仅针对已验证的 Linux 版本；其他环境需要单独核实源码与代码语义是否保留。

可选适配器通过 Codex 官方 `exec --json` 接口输出原始 Markdown，保留代码围栏，
使用 OSC 133 标记输入/输出，并在后续提示中 resume session：

```sh
./zig-out/bin/ghostty --math-rendering=true --math-raw-output=true \
  -e python3 scripts/ghosttex-codex.py
```

这是普通行编辑输入界面，不替换原版 Codex TUI 的全部功能；按完成的 agent 消息输出，
不提供 token 级预览。`--` 后可传 Codex 参数，认证、模型、沙箱和审批沿用 Codex 设置。
适配器不会编辑用户全局配置，也不会把模型输出的终端控制字符直接执行。
`math-raw-output` 仅用于用户确认保留原始 Markdown 的输出源，不会恢复已丢失的内容。

## 实施阶段与完成条件

| 阶段          | 可审查成果                                            | 完成条件                                                                     |
| ------------- | ----------------------------------------------------- | ---------------------------------------------------------------------------- |
| M0 识别基础   | 本轮识别器、终端边界测试与目标文档                    | 明确支持子集；验证源码范围和 ANSI 执行顺序；不启用自动绘制                   |
| M1 RaTeX 桥接 | 固定 Rust/RaTeX/字体，C ABI、栅格化、错误与所有权测试 | 分数、上下标、根式、矩阵、cases、aligned、text、中文、过宽和失败样例逐项实测 |
| M2 块级布局   | 稳定身份、后台队列、有界缓存、视觉映射、纹理路径      | 正文展开、输入区固定、光标和 DSR 坐标正确；覆盖和清屏撤销结果                |
| M3 行内与交互 | 段落高度、基线、选择、复制、搜索、鼠标、源码切换      | 中文混排、多公式、缩放和命中测试通过，无正文遮挡                             |
| M4 发布验证   | Codex 兼容规则、配置、性能仪表、生命周期和平台矩阵    | 五项首轮指标在真实窗口通过，依赖许可和安装身份完成审查                       |

M2 是方案是否成立的第一道关键门槛。固定输入区和全屏局部刷新不正确时，
该 CLI 不进入自动渲染支持列表。各阶段保留关闭功能的 Ghostty 对照。

## 五项首轮验收

| 验证项   | 必须观察到的结果                                               |
| -------- | -------------------------------------------------------------- |
| 识别     | 代码、价格和变量不误转；跨片段闭合正确；围栏滚出视口后仍正确   |
| 动态高度 | 公式展开后正文、固定输入区、光标、DSR 和点击位置一致           |
| 缓存滚动 | 命中内容只移动和裁剪，布局计数不随回滚增加；CLI 重绘也复用缓存 |
| 交互响应 | 冷启动复杂公式时仍能输入、滚动；队列和上传量有界               |
| 生命周期 | 缩放、局部清屏、备用屏幕、退出与历史回收后无残留或持续内存增长 |

性能目标先作为候选阈值，在固定硬件和 CLI 版本上校准：60 Hz 下滚动帧时间
p95 ≤ 16.7 ms、p99 ≤ 33.3 ms；无公式输出相对关闭功能的 p95 回归 ≤ 5%；
输入到可见帧的 p95 增量 ≤ 4 ms；闭合后首次显示简单公式 p95 ≤ 100 ms、
复杂样例 p95 ≤ 500 ms。缓存命中不得再次调用 RaTeX。

记录首次显示延迟、缓存命中耗时、输入延迟、实际呈现帧时间、队列深度、
布局次数、纹理上传字节和 CPU/GPU 峰值。分别测量冷缓存和热缓存、Ghostty
历史回滚与 Codex 内部滚动，不能用 PTY 转发速度代替呈现帧率。

生命周期压力测试至少循环 100 次缩放/清屏/标签页关闭，并运行一小时长会话。
资源应回到缓存预算和有效引用范围，不能仅检查进程没有崩溃。

## 运行现有测试

```sh
zig test src/terminal/markdown_math.zig
zig build test-lib-vt -Dtest-filter='ghosttex math'
zig build test -Dmath=true -Dtest-filter=ghosttex
cargo test --locked --manifest-path native/ghosttex-math/Cargo.toml
python3 test/ghosttex/adapter_test.py
```

云环境提供的工具链未在默认 PATH 时，先执行：

```sh
. /workspace/ghosttex-env/activate.sh
```

当前已验证 RaTeX 样例、ABI 所有权、隔离进程超时、原生布局及窗口正确性。
GUI 回归：`dbus-run-session -- xvfb-run -a python3 test/ghosttex/gui_smoke.py`。
`--codex`、`--codex-source` 和 `--codex-adapter` 使用本地 Responses API 固定响应，
测试真实 Codex CLI，无需账号或外部模型调用。中文窗口样例需要可用的系统中文字体。

Xvfb/软件 OpenGL 结果不代表真实 GPU 帧率。当前环境没有 `/dev/dri`，也没有
macOS SDK/Metal 运行环境。硬件性能、macOS 窗口、一小时长会话、SSH/tmux/分屏
以及完整发布身份仍未验收，不能将原型标记为全部目标完成。

## 参考

- [Ghostty 开发说明](HACKING.md)
- [RaTeX 固定基线](https://github.com/erweixin/RaTeX/tree/28fa5a7c800172af00043270c0acc85bd0c60155)
- [RaTeX C ABI](https://github.com/erweixin/RaTeX/blob/28fa5a7c800172af00043270c0acc85bd0c60155/crates/ratex-ffi/src/lib.rs)
- [DisplayList 协议](https://github.com/erweixin/RaTeX/blob/28fa5a7c800172af00043270c0acc85bd0c60155/docs/DISPLAYLIST_JSON_PROTOCOL.md)
- [XTerm 控制序列](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html)
