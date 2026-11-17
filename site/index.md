<!-- https://waitlight.cassianflorin.com/ as Markdown, generated from the page by scripts/build-site.py -->

Waitlight 是一个原生 macOS 应用，用来并排运行多个 AI 编程 Agent（Claude Code、Codex、Gemini 等），本地和 SSH 服务器上的都行，一条侧边栏告诉你哪个 Agent 在等你。基于 Ghostty，免费开源。

给编程 Agent 的原生 macOS 工作台

# 一个窗口， 看住所有 Agent。

**谁在运行，谁在等你，一眼看清。** 多个编程 Agent、本地目录和 SSH 会话，都在同一个窗口。

macOS 14 及以上 · Apple 芯片 · 免费，MIT

内置支持

- Claude Code
- Codex
- Gemini
- Grok
- opencode
- Qwen Code
- Cursor CLI
- Copilot CLI
- Droid
- Amp
- Crush
- Aider
- + 任意命令行工具

自动检测你装了哪些，菜单里只列这些；没装的在 App 里点「安装」就行。

## 不用切过去，也知道该看谁。

每个 Agent 旁边都有一盏状态灯。四种颜色，四个意思。

- **运行中**: 这一轮还没结束。你可以先去忙别的。
- **等你**: 它停下来等一次确认或回答。`⌘⇧J` 跳到下一个。
- **本轮完成**: 这一轮结束了，会话还在。点进去看结果，或接着说。
- **已退出**: Agent 已退出，回到 shell。支持的 Agent 可恢复之前的对话。
- Claude Code 用它自己的 hooks 报告状态。Waitlight 只在启动时加上参数，不改你的设置文件。
- Grok 和 Codex 也能这样报告，在「管理 Agent」里打开就行。它们只从自己的配置目录读 hooks，所以会各新建一个 Waitlight 自己的文件：~/.grok/hooks/waitlight.json 和 ~/.codex/waitlight.config.toml。你已有的配置不动，关掉开关就删除，在 Waitlight 之外它们什么也不做。两个 Agent 都会先让你信任新 hook。
- 没有 hooks 的 Agent 靠通用信号判断：回车、响铃、通知和进度。
- 刚启动、还在等第一次输入时，显示「就绪」。普通 Shell 没有这些状态。
- 响铃和通知也会在 Dock 上标出来。SSH 断了以后提示为「已断开」，旁边有重连按钮，`⌘⇧R` 也会重连。
- 动效也有含义：运行中，文字上有一道光扫过；等你，圆点外面的圈会扩出去。系统打开「减弱动态效果」后，这些动画会停。

## 所有 Agent，列在一屏里。

`⇧⌘A` 把终端换成一张列表，每个 Agent 一行。会话都还在后台跑着。

- 先处理在等你的: 等你的 Agent 排在最前面，那一行直接写着它在等什么、等了多久。
- 留在总览里直接回复: 选中一行，下面是它终端的最后几行。打字回车，或按它提示里的选项键，回复就发过去了。
- 在列表里继续派任务: 在派发栏选 Agent 和文件夹，写下任务，回车。新的 Agent 在后台开工，你还留在列表里。
- **筛选**：顶部输入框按名称、Agent 或文件夹筛选；也可以改成按文件夹分组。
- **置顶**：右键把一个 Agent 置顶，它不管在干什么都排最上面，重启 App 后还在。
- **停止**：运行中的 Agent 可以直接停止这一轮。
- **快捷选择**：它等你选的时候，回复框旁边有 `1 2 3 ↩ esc`，对应提示里的选项。
- **进出**：`↩` 或双击进到它的会话，光标落在它的窗格里；`esc` 或点侧边栏任一会话回到终端。

## 本地和远程，排在同一条侧边栏。

~/.ssh/config 里的主机直接出现在「服务器」里，服务器上什么都不用装。断线重连后，跑在 tmux 或 zellij 里的会话会挂回原处。

- 「服务器」里有你添加的主机，也有 ~/.ssh/config 里的别名，Include 进来的文件也算。可以填地址、用户、端口、密钥或 ssh-agent，也支持 ProxyJump。密码放在钥匙串里。
- 默认是自动：机器上已经有 tmux 或 zellij 就用它，没有就开一个普通登录 shell，不会催你去装。
- 重连时，如果当时跑在 tmux 或 zellij 里，会挂回原来的会话，里面的 Agent 还在。没有多路复用器的话，就按你配置的目录重新登录，之前的进程不会回来。
- 性能面板跟着当前会话。看 SSH 会话时采样的是那台服务器：只开一条 SSH，用一小段 POSIX shell 去读 /proc，仍然不用装东西。远程采样目前只支持 Linux。

## 重新打开，接着之前的工作。

重启 App，或者重新启动一个已经退出的 Agent，Claude Code、Grok 和 Codex 会回到同一段对话。分屏、分组和 SSH 连接也按退出前的样子回来。

- 回到同一段对话靠的是对话 id。Claude Code 和 Grok 在启动时就带上 Waitlight 分配的 id。Codex 不能预先指定，要等它收到第一条提问、写出会话文件后，Waitlight 才从 ~/.codex/sessions 里对上。
- 没有 id 的时候（Gemini，或者还没提过问的 Codex）：重启 App 会接上这个文件夹里最近的一段对话；在 App 里重新启动一个已退出的 Agent，则是开一段新对话。
- `⇧⌘O` 按文件夹列出过去的对话，选一段恢复。支持 Claude Code、Codex 和 Grok。
- 自定义 Agent：「新对话参数」和「恢复对话参数」里都写了 {id}，Waitlight 才会自己生成 id 并回到同一段对话。只填了「继续最近对话参数」的，重启 App 时接最近一段。两样都没填，每次都是新对话。
- 从 Docker 容器打开的会话，下次启动 App 时不会恢复。第一次打开、没有可恢复的内容时，会在家目录开一个 shell。

### 每一格都是真正的 Ghostty 终端

~/.config/ghostty/config

字体、主题和快捷键直接沿用你的 Ghostty 配置。在 Waitlight 的设置里改过的项只叠在上面，不会写回这份文件。

## 手不用离开键盘。

- `⌘⇧J` — 跳到下一个等你的会话
- `⇧⌘A` — 打开 Agent 总览
- `⌥⌘[ ⌥⌘]` — 上一个 / 下一个 Agent，跨会话
- `⌘D ⌘⇧D` — 向右分屏 / 向下分屏
- `⇧⌘O` — 恢复这个文件夹里以前的对话
- `⌘⇧R` — 重新连接 SSH
- `⌘⇧[ ⌘⇧]` — 上一个 / 下一个会话
- `⌘1 ⌘9` — 跳到对应的会话
- `⌘⇧↩` — 放大 / 还原当前窗格
- `⌘F` — 在回滚里查找
- `⌘V` — 把截图或文件贴成路径
- `⌥⌘P` — 打开性能监视器
- `⌘⇧W` — 关闭当前会话
- `⌘,` — 设置
- 内置主流的 Agent 命令行工具：Claude Code、Codex、Gemini、Grok、opencode、Qwen Code、Cursor CLI、Copilot CLI、Droid、Amp、Crush、Aider，外加 Shell。装了哪些，新建会话的菜单里就只列哪些。没装的在「管理 Agent」里点「安装」，会新开一个终端跑安装命令，装完自动出现在菜单里。其他命令行工具可以自己加。
- Agent 的命令是打进登录 shell 的，Agent 退出以后，你还在那个 shell 里。
- 状态跟着窗格走，不跟着会话。在分屏里自己敲 claude 或 codex，Waitlight 也认得出来，它会有自己的状态，也会出现在总览里。
- 剪贴板里如果是截图，⌘V 会先存成 PNG，再贴上路径，这样就能把图交给 Agent。拷进来或拖进来的文件，会变成 shell 转义后的路径。
- 中文、日文、韩文输入法可以用，候选窗贴着光标。
- 会话可以重命名，也可以放进分组。分组是侧边栏里可折叠的一段。
- 性能面板里还有 Docker。可以看容器日志、进容器开一个 shell，也可以启动、停止或重启。从容器打开的会话，下次启动 App 时不会恢复。
- 每天会查一次更新，菜单里也可以自己检查。更新来自 GitHub Releases，要有 EdDSA 签名，并且 Developer ID 得和当前这个 App 一致。如果有 Agent 正处在这一轮里，重启前会先问你。

#### 窗格

- `⌘[ ⌘]` 或 `⌘⌥←↑↓→` 在窗格之间移动。
- `⌘⌃←↑↓→` 调整大小，`⌃⌘=` 均分，`⌘W` 关闭当前窗格。
- 新窗格沿用当前文件夹。布局在重启 App 后恢复。

#### 查找与回滚

- `↩ ⇧↩` 或 `⌘G ⇧⌘G` 在匹配之间前后跳，旁边有匹配计数。
- `⌘E` 用选中的文字查找。
- `⌘↑ ⌘↓` 在提示符之间跳。滚动指示条可以直接拖。

#### Agent

- 在会话里，工具栏显示当前是第几个 Agent（比如 2/5），两边的箭头去上一个和下一个。
- 派发的任务通过「带提示词启动参数」里的 {prompt} 交给 Agent。内置的大多已经配好（Amp、Crush、Aider 除外）；自定义 Agent 填了才会出现在派发栏里。
- `⌘⇧1`…`⌘⇧9` 按「管理 Agent」里的顺序新建会话，只算已经装好的。
- 自定义 Agent 可以分别填新对话、恢复对话、继续最近对话的参数。参数里的 {id} 会换成对话 id。
- Waitlight 在你登录 shell 的 PATH 里找这些命令，所以 nvm、~/.local/bin 里装的也能找到。切回 Waitlight 时会重新检测，在别处刚装的也会出现。

#### 服务器

- 编辑服务器时有命令预览和「测试连接」，会显示系统、有没有 tmux 或 zellij、已有哪些会话。
- 可以按服务器指定用 tmux 或 zellij，也可以附加到一个已有的会话。
- 右键 ~/.ssh/config 里的条目可以把它从列表里拿掉。只是在 Waitlight 里隐藏，文件不会被改，之后可以恢复。
- Ghostty 的 ssh 集成照常可用（ssh-terminfo、ssh-env）。

#### 性能面板

- CPU（每核，服务器上还有负载）、内存、GPU（Apple GPU，服务器上通过 nvidia-smi 读 NVIDIA）、网络、磁盘。
- 「会话占用」：在 Mac 上是每个会话的进程树，在服务器上是最忙的几个进程。
- 显示哪些、多久刷新一次（1、2 或 5 秒）可以在面板菜单里选。
- 面板默认关着。关着或窗口隐藏时不采样，也不保持连接。

#### 设置

- 终端：配色主题（Ghostty 自带的全部主题加你自己的，带色块和搜索）、字体、字号、行高、光标样式和闪烁、内边距。
- 还有 Option 当作 Alt、选中即复制、打字时隐藏鼠标。改动带实时预览，叠在你的 Ghostty 配置上面，立刻作用到所有终端，但不会写回文件。
- 中文默认统一用苹方显示，粗细和标点位置都一致，也可以换成别的字体。
- 外观：背景不透明度 30–100%，以及模糊程度，文字始终不透明。只在 Waitlight 里生效。Waitlight 本身只有深色。

## 你可能想问的。

### Waitlight 是什么？

Waitlight 是一个原生 macOS 应用，用来并排运行多个 AI 编程 Agent（Claude Code、Codex、Gemini 等），本地和 SSH 服务器上的都行，一条侧边栏告诉你哪个 Agent 在等你。每一格都是真正的 Ghostty 终端。

### AgentDeck 呢？

就是它。Waitlight 0.10 之前叫 AgentDeck，因为同名的项目太多才改名。已经装了的直接在 App 里更新，会话、服务器和设置都会留着。

### 支持哪些 Agent？

内置 Claude Code、Codex、Gemini、Grok、opencode、Qwen Code、Cursor CLI、Copilot CLI、Droid、Amp、Crush 和 Aider，其他命令行工具也可以自己加。Waitlight 会检测你装了哪些，没装的可以在 App 里一键安装。

### 免费吗？开源吗？

免费，开源，MIT 许可。源码在 GitHub 上：github.com/CassianFlorin/Waitlight。

### 需要什么系统？怎么安装？

macOS 14 或更新版本，Apple 芯片。用 Homebrew 安装：`brew install --cask cassianflorin/tap/waitlight`，或者从 GitHub Releases 下载 DMG。安装包经过 Apple 签名和公证，装好后会自己更新。

### 服务器上要装东西吗？

不用。Waitlight 走普通的 SSH，`~/.ssh/config` 里的服务器直接能用。服务器上有 tmux 或 zellij 就会用上，断线重连后 Agent 还在原地跑。性能面板也是通过同一条 SSH 读取 Linux 的 /proc。

### 和在 iTerm 或 tmux 里多开几个标签有什么区别？

终端还是那个终端（Ghostty），多出来的是每个 Agent 的状态：谁在运行，谁卡在权限确认上等你，谁这一轮做完了。`⌘⇧J` 直接跳到下一个等你的，Agent 总览能在一屏里看全部、直接回复、派新任务，重启 App 后 Agent 回到同一段对话。

### 会改我的 Agent 配置吗？

不会。Claude Code 的 hooks 在启动时用 `--settings` 传进去，不碰你的设置文件。Codex 和 Grok 的状态 hook 要你自己打开，它只写一份 Waitlight 自己的文件，关掉就删除。

### 会收集我的数据吗？

不会。Waitlight 没有统计和遥测，唯一主动的联网是检查更新时读取 GitHub Releases。

## 合用就拿去。

这是照着一个人自己的工作流做的，开源出来。可以从 Releases 下载签过名的包，也可以自己构建。

- **Agent**: 内置 12 个主流 CLI，装了哪些列哪些
- **系统**: macOS 14 或更高
- **芯片**: 目前只有 Apple 芯片
- **远程采样**: 目前只支持 Linux
- **许可**: MIT。终端引擎是 Ghostty

需要 macOS 14 或更高、Xcode 16 或更高、XcodeGen，以及 Zig（版本看 vendor/ghostty/build.zig.zon 里的 minimum_zig_version）。

```
git clone --recursive https://github.com/CassianFlorin/Waitlight.git
cd Waitlight
scripts/build-ghosttykit.sh      # 构建 GhosttyKit，第一次约 5 分钟
scripts/fetch-sparkle.sh         # 下载 Sparkle 更新框架
xcodegen
open Waitlight.xcodeproj
```

Debug 配置是 ad-hoc 签名，不需要证书。Xcode 26 及以后，Metal 编译器是单独的组件，装一次就行：

```
xcodebuild -downloadComponent MetalToolchain
```

如果 Zig 自己下载依赖失败（走 HTTP 代理时报 400，或者报 hash mismatch、DirNotEmpty），先用 curl 把依赖取下来，再离线构建：

```
scripts/prefetch-zig-deps.sh
ZIG_SYSTEM_DIR=vendor/zig-deps/pkg scripts/build-ghosttykit.sh
```

构建被打断之后报 hash mismatch，用 CLEAN=1 scripts/build-ghosttykit.sh 重来。
