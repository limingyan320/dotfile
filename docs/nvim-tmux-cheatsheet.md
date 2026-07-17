# Neovim & Tmux 个性化操作速查

> 基于本 dotfile 实际配置生成，随配置变更需同步更新。

---

# Neovim

> Leader 键 = `空格`
> 默认缩进 = 2 个空格（`expandtab` + `tabstop/shiftwidth/softtabstop = 2`）
> Swift 例外 = 跟随运行时 ftplugin 用 4 空格；普通可编辑 buffer 在 `{}` / `[]` / `()` 中间按 `Enter` 时会自动拆成三行，并让闭括号和起始缩进对齐
> 输入 `:` 不会再触发“当前行立即自动纠偏缩进”；只保留 `Enter` 续行时的正常缩进
> 顶部 `winbar` 会显示当前所在的文件 / 函数路径；折叠默认启用但保持全部展开
> 底部 `lualine` 状态栏使用 Powerline 三角分隔符；最左侧青色块显示当前 live session 名称，后面才是 `NORMAL` / `INSERT` / `TERMINAL` 等当前模式
> 滚动偏 IDE/网页手感：`Ctrl+D/U` 小步滚动视图，鼠标滚轮每格 2 行，光标附近保留 6 行上下文
> `/` 搜索默认增量定位 + 高亮全部匹配；小写模式默认忽略大小写，含大写时自动切回区分大小写

## IDE 风格辅助

| 功能 | 现在的行为 |
|------|------|
| 当前所在函数/方法 | 自动显示在顶部 `winbar`；支持 LSP symbol 的语言会显示类似 `Module > Class > Method` |
| 看模块全貌 | 用 `zc` / `zo` / `za` / `zM` / `zR` 折叠函数或整个文件 |

## 窗口（Split）管理

### 创建分屏

| 按键 | 操作 | 记忆 |
|------|------|------|
| `Ctrl+W v` | 垂直分屏（左右） | v = vertical |
| `Ctrl+W s` | 水平分屏（上下） | s = split |
| `:vs filename` | 垂直打开指定文件 | |
| `:sp filename` | 水平打开指定文件 | |

### 切换窗口

| 按键 | 操作 |
|------|------|
| `Ctrl+W h/j/k/l` | 按方向跳转窗口 |
| `Ctrl+W w` | 循环切换下一个窗口 |
| `Ctrl+W p` | 跳回上一个窗口 |

### 调整大小

| 按键 | 操作 |
|------|------|
| `Space z` | 像 tmux `prefix z` 一样临时放大当前窗口；再按一次恢复原分屏布局 |
| `Ctrl+W =` | 所有窗口等分 |
| `Ctrl+W >` / `<` | 宽度增/减 |
| `Ctrl+W +` / `-` | 高度增/减 |
| `10 Ctrl+W >` | 可加数字前缀批量调整 |
| `Ctrl+W _` | 当前窗口最大化高度 |
| `Ctrl+W \|` | 当前窗口最大化宽度 |

> `Space z` 的实现是把当前 window 暂时放到单独 tab 里，所以恢复时会回到原来的分屏布局；如果当前 tab 本来就只有一个 window，它会提示无需放大。

### 移动窗口

| 按键 | 操作 |
|------|------|
| `Ctrl+W H/J/K/L` | 把窗口移到最左/下/上/右 |
| `Ctrl+W r` | 顺时针轮换 |
| `Ctrl+W T` | 搬到新 tab |

### 关闭窗口

| 按键 | 操作 |
|------|------|
| `Ctrl+W c` | 关闭当前窗口（不退出 vim） |
| `Ctrl+W q` | 关闭当前窗口（最后一个则退出 vim） |
| `Ctrl+W o` | 只保留当前窗口，关掉其他所有 |

---

## Live Session（像 tmux detach / attach）

Neovim 0.12 可以把当前 TUI 脱离，但让原来的 Nvim 进程继续在后台运行；窗口布局、buffer、未保存修改以及普通 shell / Codex terminal 都会原样保留。交互式 shell 里的普通 `nvim` / `nvim .` / `vim` 会由独立的隐藏 tmux server 托管，因此即使承载 TUI 的 terminal 窗口被意外关闭，Nvim 进程和视图也仍会存活。

| 按键 | 操作 |
|------|------|
| `Space d` | detach 当前 UI，回到外层 shell；不退出 Nvim 进程 |
| `Space fs` | 打开 Mason 风格的原生 Session Dashboard；即使只有当前 session 也会显示，默认 normal mode |
| `Space fS` | 打开同一个 Dashboard，自动展开当前 session 的进度时间轴并定位到最新记录 |
| Dashboard 内 `j` / `k`、`gg` / `G` | 在 session 与进度记录之间移动、跳到首项 / 末项 |
| Dashboard 内 `Enter` | session 行：连接目标 session；进度行：打开 Markdown 编辑器；`CURRENT` 行：关闭面板返回当前视图 |
| Dashboard 内 `t` | 展开 / 折叠选中 session 的进度时间轴 |
| Dashboard 内 `a` | 给选中 session 新增带当前时间戳的进度记录，并直接进入 insert mode |
| Dashboard 内 `e` | 编辑选中的记录；在 session 行使用时打开最新记录，无记录则新建 |
| Dashboard 内 `x` | 删除选中的进度记录；实际移动到该 session 的 `trash/`，可手工恢复 |
| Dashboard 内 `c` | 浮窗输入名称，在当前 cwd 创建新 session、保留旧 session 并立即切换 |
| Dashboard 内 `r` / `Ctrl+R` | 浮窗重命名选中的 live session |
| Dashboard 内 `dd` | 删除选中的非当前 live session；浮窗默认停在 `Cancel`，确认前显示未保存 buffer、terminal 和已连接 UI 风险；进度日志保留为归档 |
| Dashboard 内 `A` / `R` | 切换显示归档日志 / 重新扫描 live sessions |
| Dashboard 内 `/`、`n` / `N` | 使用 Vim 原生搜索查找当前已展开内容、跳到下 / 上一个匹配 |
| Dashboard 内 `?` | 显示 Dashboard 快捷键帮助 |

Session 列表最左侧有固定 3 格 Codex 状态：流动的 `●·· → ·●· → ··●` 表示 agent 正在工作；闪烁的红色 `!` 表示该 session 已完成但还没有查看。动画只在 Dashboard 打开且至少有一个 UI 接入时刷新；UI 全部脱离后暂停、重连后继续。状态会一直保留到 check；动画刷新不会把 `j` / `k` 的当前选择拉回默认项。

每个 session 行用高亮 `◆ 数量 · 更新时间` 标出已有进度；无记录时显示灰色 `◇ 0`。展开后按 `Today` / `Yesterday` / 日期分组，时间来自创建记录时保存的 Unix timestamp，再按本机时区换算显示。记录正文是普通 Markdown 文件，编辑窗口支持完整 Vim normal / insert 操作；修改停止约 400ms 后自动保存，离开 insert、关闭窗口或离开 buffer 时也会强制保存。normal mode 下按 `q` 保存并回到 Dashboard，`Ctrl+S` 可立即写盘。

日志保存在 `${DOTFILES_NVIM_SESSION_DIR}/notes/<session-id>/`，默认即 `~/.local/state/nvim/sessions/notes/`；一条记录对应一个 Markdown 文件，session 名称和项目等元数据单独原子写入 JSON。退出或删除 live session 不会删除工作进度，之后可在 Dashboard 按 `A` 查看、编辑归档；`x` 删除的记录会移入对应 `trash/`，不会直接 unlink。

推荐恢复流程仍沿用原来的入口：

```text
nvim        或 nvim .
Space f s
选择 session 后按 Enter；或按 t 展开、a 记录进度
```

live 列表按 `CURRENT`、`DETACHED`、`ATTACHED` 排序，并显示 Codex 状态、逻辑名称（未命名时回退为项目名）、进度数量/新鲜度、当前 buffer 和 `窗口数w 标签数t 修改数* terminal数term`，不会要求记 socket 路径。列宽随 Dashboard 实际宽度伸缩，窄屏会依次压缩 buffer / 统计内容。跨 session 状态读取仍使用并行外部 RPC，总等待上限 700ms；日志和时间轴只读本机 state 文件，不会增加远端 RPC。单个无响应实例会被跳过，不会卡住当前 UI，也不会被自动杀掉。名称保存在 Nvim server 内，terminal 关闭或 detach 后仍在，`:qa` 后 live 名称随 session 消失，但已有日志元数据和正文保留。headless / embed 辅助进程不会出现；只有受隐藏 host 管理的入口会在启动时检查 detached 会话并轻量提示数量，不会打断 `nvim .` 的 Oil 视图；`command nvim` 不做这次启动扫描，可作为紧急旁路。

当前 session 的逻辑名称也会显示在底部状态栏最左侧，使用独立的青色背景与后面的 Vim 模式区分；未显式命名时同样回退为项目目录名，过长名称会截断。通过 Dashboard 重命名后状态栏会立即更新；不受 live session 系统管理的特殊 Nvim 实例不显示该组件。

`dd` 会强制结束目标 live session，因此未保存修改和其中的 terminal 进程都会关闭；目标仍有其他 UI 连接时也会明确提示。确认框默认选中 `Cancel`，`Esc` 也会取消。`CURRENT` 不允许从 Dashboard 删除，需明确使用 `:qa` / `:qa!` 退出当前 Nvim；无论哪种退出方式，已有进度日志都保留为 archive。

从刚启动的未命名空白 `nvim` / `nvim .` 连接时，这个入口实例会自动回收；如果当前实例已命名、已有分屏、多个 buffer、未保存修改、terminal，或它本身曾被 detach，则切换后仍留在后台，可以再通过 `Space fs` 切回来。

隐藏 host 使用单独的 tmux socket `dotfiles-nvim-host`，前台仍是直接的 Neovim remote UI，不会出现 tmux 状态栏、copy mode 或滚动拦截；普通 `tmux ls` 也看不到它。host 创建 socket 后还必须在 2 秒内通过真实 RPC 探活，失败时只回收本次新建的空 session。排查时可运行 `tmux -L dotfiles-nvim-host ls`。`:qa` / `:qa!` 会正常结束对应 Nvim session、socket；最后一个 session 退出后隐藏 tmux server 也自动结束。`nvim --headless`、`--server`、`--listen`、管道输入等工具调用会自动绕过托管；临时需要完全直启时可用 `command nvim ...`。

---

## 文件浏览器

已禁用内置 netrw，改用 **oil.nvim**（浏览 + 批量文件操作）和
**telescope-file-browser**（带模糊搜索的目录钻取 + 分屏打开）。

### oil.nvim — 把目录当 buffer 编辑

`nvim .` / `nvim <dir>` 进入，或在已打开的文件里按 `-`。

| 按键 | 操作 |
|------|------|
| `-` | **任意普通 buffer**：跳到当前文件所在目录的 oil 视图；**terminal buffer 的 normal 模式**下按当前 shell cwd 打开 |
| `-` | **在 oil 里**：回到上一级目录 |
| `_` | 跳回 cwd |
| `Enter` | 进入子目录 / 打开文件 |
| `<C-s>` | 左右分屏打开 |
| `<C-h>` | 上下分屏打开 |
| `<C-t>` | 新标签打开 |
| `<C-p>` | 用 Telescope 搜索当前 oil 目录里的文件 |
| `gy` | 复制光标下条目的**绝对路径**到系统剪贴板（自定义） |
| `g?` | 查看全部快捷键 |
| `:w` | 提交编辑（弹确认框） |

**编辑即操作**：oil buffer 就是普通 buffer，文件系统操作 = 编辑文本：

| 编辑动作 | 实际效果 |
|----------|----------|
| 改某行文字 | 重命名该文件 |
| `dd` | 删除该文件 |
| `o` 新开一行写名字 | 新建文件（结尾加 `/` 就是新建目录） |
| `yy` + `p` | 复制文件 |
| 剪切粘贴到另一个 oil buffer | 移动文件 |
| `:%s/foo/bar/g` | 批量重命名 |
| `u` | **撤销文件系统改动** |

默认显示隐藏文件。

### telescope-file-browser — 钻目录 + 分屏打开

| 按键 | 操作 |
|------|------|
| `Space fe` | 从项目根打开 file browser |
| `Space fE` | 从当前文件所在目录打开 |

browser 内（telescope 默认键）：

| 按键 | 操作 |
|------|------|
| `Enter` | 当前窗口打开 / 进入子目录 |
| `<C-v>` | 左右分屏打开 |
| `<C-x>` | 上下分屏打开 |
| `<C-t>` | 新标签打开 |
| `h` / `<BS>`（输入为空时） | 返回上级目录 |
| 直接输入 | 在当前目录模糊过滤 |
| `<Esc>` 进 normal 后 `c` / `r` / `d` / `m` / `y` | 新建 / 重命名 / 删除 / 移动 / 复制 |
| `g?` | 查看全部快捷键 |

配置要点：目录显示在文件前（grouped）、显示隐藏文件、不劫持 netrw 的入口（交给 oil）。

### 其他

| 按键 | 操作 |
|------|------|
| `Space yp` | 任意 buffer 里复制当前文件的**绝对路径** |
| `Space t` | 在当前上下文目录开完整 terminal buffer 并直接进入输入；如果当前 buffer 就是 terminal，会沿用该 shell 的 cwd |
| `Ctrl+/` | 底部普通 shell 开关；首次按当前上下文目录启动，显示后自动进入输入，隐藏时保留进程（`Ctrl+_` 也兼容） |
| `Option + /` | 底部 Codex agent 开关；打开后若 Codex 最新输出实际可见会自动 check、清除红色完成未读并关闭对应 macOS popup，单纯隐藏未查看的 drawer 不会清未读；以 `codex --yolo` 从当前上下文的 Git 根启动，显示后停在 terminal-normal，隐藏时保留对话进程 |
| `gx`（Codex terminal normal/visual） | 打开光标下或 visual 选中的绝对/项目相对路径；支持 `:行:列` / `#L行C列`，忽略末尾或紧邻后续正文的中英文标点，在上一个非 terminal 编辑窗口跳转 |
| `Option + +` / `Option + -` / `Option + 0` | 增高 / 降低 / 重置当前底部通道高度 |

> 普通 shell 和 Codex 各自保留独立的 terminal buffer / 进程，但共用同一个底部 drawer，所以互相切换不会堆叠窗口或丢失 shell / 对话状态。普通 shell 显示后自动进入 terminal 输入；Codex 显示后保持 terminal-normal 和原来的阅读位置，需要回复时按 `i` / `a` / `A` 进入输入。普通 shell 默认高 12 行；Codex 默认至少 12 行，并尽量占屏幕高度的 45%。normal / insert / terminal 模式下都能直接切换。若把 drawer 窗口改作普通编辑 buffer，下次 toggle 会保留该编辑窗口并另开 drawer。`Option + +` 在部分终端里会发成 `<M-=>`，已一起兼容。

> Codex 通道在一次 Neovim 运行期间只维护一个会话，并默认使用 `--yolo` 权限；切换到其他项目后仍会回到原对话。Codex terminal 中按 `gx` 时，光标下或同一行内 visual 选中的相对路径始终按这个会话启动时的项目根解析，不会误用后来切换到的项目；反引号路径、Markdown 链接、`path:行:列` 和 `path#L行C列` 都可识别，引用末尾或定位后紧邻正文的中英文标点会自动忽略。目标文件会复用刚离开的非 terminal 编辑窗口，找不到时回退到打开 drawer 前的窗口，Codex 继续留在底部；网页 URL 仍交给系统浏览器。Codex 进程退出后，隐藏并重新打开会从当前项目启动新会话；若 `codex` 不在 `PATH` 中则会提示错误。

> 外部工具（如 Claude）改了文件，nvim 会在光标停 0.5 秒内自动重新加载并提示。

---

## Buffer 管理

| 按键 / 命令 | 操作 |
|-------------|------|
| `Space fb` | Telescope 搜索 buffer 列表 |
| `:bn` / `:bp` | 下一个 / 上一个 buffer |
| `:bd` | 关闭当前 buffer |
| `:e filename` | 打开/新建文件 |

---

## 搜索和跳转

### Telescope（自定义配置）

| 按键 | 操作 |
|------|------|
| `Ctrl+P` | 搜文件名（普通文件里基于当前文件的 git 根目录；oil 目录视图里基于当前目录） |
| `Space fg` | 全局内容搜索（同样以 git 根为范围） |
| `Space fb` | 搜已打开 buffer |
| Telescope 内 `Alt+V` / `Alt+S` | 把选中的文件左右 / 上下分屏打开 |
| Telescope 内 `Ctrl+H` | 切换：显示隐藏文件 + 忽略 .gitignore（保留已输入内容） |
| Telescope 内 `Ctrl+J/K` | 上下移动 |
| Telescope 内 `Ctrl+U/D` | 预览窗口翻页 |

### Flash 快速跳转（自定义配置）

| 按键 | 操作 |
|------|------|
| `s` | 输入字符后按标签跳转 |
| `S` | 按代码结构（treesitter）跳转 |

### Vim 原生搜索

| 按键 | 操作 |
|------|------|
| `/pattern` → `n`/`N` | 登记搜索词并高亮全部匹配；输入完成时不滚动视野，按 `n` / `N` 才跳转 |
| `*` / `#` | 搜索光标下的词；第一次只高亮不滚动，同一个词再按才向下 / 向上跳 |
| `/\\cpattern` | 强制忽略大小写搜索 |
| `/\\Cpattern` | 强制区分大小写搜索 |
| `:%s/old/new/gc` | 全文替换（逐个确认） |
| `:noh` | 清除搜索高亮 |

> 当前默认启用了 `hlsearch + ignorecase + smartcase`，但关闭了 `incsearch`：搜完会高亮全部匹配，小写默认忽略大小写，带大写时自动区分大小写；搜索输入过程中不会自动滚动视野。

### LSP 跳转（自定义配置）

| 按键 | 操作 |
|------|------|
| `gd` | 跳到定义 |
| `gD` | 在右侧分屏打开定义，方便同屏对照 |
| `gr` | 查找所有引用 |
| `Space k` | 悬浮文档 |
| `Space rn` | 重命名符号 |
| `Space ca` | 代码操作 |
| `[d` / `]d` | 上/下一个诊断 |
| `:lua vim.diagnostic.open_float()` | 弹出当前光标位置的报错详情 |
| `:lua vim.diagnostic.setloclist()` + `:lopen` | 打开当前文件的诊断列表 |

> 当前配置没有单独绑定“显示当前诊断详情”的快捷键，所以看错误原因时用上面的命令最直接。

### 跳转历史（重要）

| 按键 | 操作 |
|------|------|
| `Ctrl+O` | 跳回上一个位置（gd 之后用这个回来） |
| `Ctrl+I` | 跳到下一个位置（和 Ctrl+O 配合 = 前进/后退） |
| `` `. `` | 跳到最后修改的位置 |
| `gi` | 跳到上次插入的位置并进入编辑 |
| `Opt+Left` / `Opt+Right` | 按单词向左 / 向右跳；在 insert 模式里跳完仍保持插入 |

---

## 补全

当前使用 `blink.cmp`，按键改成更接近 IDE：

| 按键 | 操作 |
|------|------|
| `Ctrl+Space` | 手动触发补全 |
| `Up` / `Down` | 上下选择补全项 |
| `Ctrl+P` / `Ctrl+N` | 上下选择补全项 |
| `Enter` | 只在已选中候选项时确认补全；否则正常换行；位于 `{}` / `[]` / `()` 中间时会智能拆行 |
| `Ctrl+E` | 关闭补全菜单 |
| `Tab` / `Shift+Tab` | 仅用于 snippet 前进 / 后退，不用来选补全项 |

> 当前配置不默认预选第一项，所以像输入 `str` 时，按 `Enter` 不会擅自补成 `start`；要先用方向键显式选中再回车确认。光标在 `{}` / `[]` / `()` 中间时，如果没有选中补全项，`Enter` 会直接拆成三行并把闭括号对齐回起始缩进。

---

## 文本编辑

### 核心动作

| 按键 | 操作 | 记忆 |
|------|------|------|
| `ciw` | 删词并编辑 | change in word |
| `ci"` / `ci(` / `ci{` | 删引号/括号内容并编辑 | change in ... |
| `d{motion}` | 删除到某个移动范围，不进入插入模式 | delete + motion |
| `diw` | 删词 | delete in word |
| `dw` / `d$` | 删到下一个词前 / 删到行尾 | |
| `viw` / `vi{` | 选词 / 选大括号内 | visual in ... |
| `yiw` | 复制词 | yank in word |
| `dd` / `yy` | 删整行 / 复制整行 | |
| `o` / `O` | 下方/上方新建行并编辑 | |
| `u` / `Ctrl+R` | 撤销 / 重做 | |
| `r字符` | 替换光标下单个字符，留在 Normal 模式 | replace |
| `r字符` (Visual) | 选中的每个字符都替换成同一个字符 | |
| `.` | **重复上一次操作** | |
| `<` / `>` (Visual) | 缩进并保持选中（自定义配置） | |
| `J` / `K` | 跳到下 / 上一个非空 block 的第一行，不写入跳转历史 | |
| `(` / `[` / `{` / `'` / `"` / `` ` `` (Visual) | 包裹选区；圆/方/花括号不加内侧空格 | |
| `#` (Visual) | 按当前文件类型切换所选多行注释（自定义配置） | |
| `gc` (Visual) | 按当前文件类型切换所选多行注释（Comment.nvim 默认） | |
| `gcc` | 切换当前行注释（Comment.nvim 默认） | |
| `gc{motion}` | 按 motion 范围切换注释，如 `gcj` / `gc}` | |

> `d` 本身不是一种模式。按下后 Vim 会等待后续动作，所以看起来像“进入了什么状态”，其实是在等你补一个 motion，比如 `w`、`$`、`d`。

> 普通可编辑 buffer 里，光标位于 `{}` / `[]` / `()` 中间时按 `Enter`，会拆成三行并让闭括号和起始缩进对齐；Python、Swift 这类代码都适用。

> 注释优先走当前文件类型自己的原生 `commentstring`；比如 Python 会用 `# %s`，Lua 会用 `-- %s`。

### 缩进调整

| 按键 | 操作 |
|------|------|
| `Alt+L` | 当前行 / 选区右移一级缩进（Normal / Visual / Insert 都可） |
| `Alt+H` | 当前行 / 选区左移一级缩进（Normal / Visual / Insert 都可） |
| `<` / `>` (Visual) | 原生左移 / 右移，并保持选区 |

### 粘贴代码不乱缩进

| 按键 | 操作 |
|------|------|
| `<F2>` | 切换 `paste mode`（Normal / Insert 都可） |
| `Space vp` | 切换 `paste mode` |

适用场景：通过终端 / tmux / SSH 把整段 Python 等代码直接粘进 nvim，结果缩进被自动打乱。

推荐流程：

1. 粘贴前按一次 `<F2>` 或 `Space vp` 打开 `paste mode`
2. 直接粘贴代码
3. 粘贴后再按一次关闭 `paste mode`

### 代码折叠

| 按键 | 操作 |
|------|------|
| `zc` | 折叠当前代码块 |
| `zo` | 打开当前折叠 |
| `za` | 切换当前折叠开/关 |
| `zM` | 折叠当前文件所有可折叠代码 |
| `zR` | 展开当前文件所有折叠 |

> 当前配置使用 Treesitter 折叠，但默认 `foldlevel=99`，所以打开文件时不会自动全折起来；想看模块骨架时再手动用 `zM` / `zc`。
> 折叠依赖对应语言的 Treesitter parser/query；当前清单包含 Go 相关的 `go` / `gomod` / `gosum` / `gowork`，以及 JSX/TSX 相关的 `ecma` / `javascript` / `jsx` / `typescript` / `tsx`。

这样会临时关闭会干扰粘贴的自动缩进逻辑，避免整段代码被二次缩进。

### 多行操作

| 按键 | 操作 |
|------|------|
| `V` → `j/k` | 整行选择模式 |
| `Ctrl+V` | 列选择模式（块编辑） |
| 列选后 `I` / `A` | 在每行开头插入 / 末尾追加 |

---

## 光标移动

| 按键 | 操作 |
|------|------|
| `gg` / `G` | 文件开头 / 末尾 |
| `数字G` 或 `:数字` | 跳到第 N 行 |
| `{` / `}` | 上/下一个空行（段落跳转） |
| `%` | 跳到匹配的括号 |
| `w` / `b` | 下一个词首 / 上一个词首 |
| `e` / `ge` | 当前/下一个词尾 / 上一个词尾 |
| `0` / `$` / `^` | 行首 / 行尾 / 行首非空字符 |
| `Ctrl+A` / `Ctrl+E` (Insert) | 跳到当前行第一个非空白字符 / 行尾，并保持 insert mode |
| `f字符` / `F字符` | 行内跳到下/上一个该字符 |
| `zz` | 当前行居中 |

## 滚动视图

| 按键 | 操作 |
|------|------|
| `Ctrl+D` / `Ctrl+U` | 视图下/上滚 6 行；光标尽量留在原位置 |
| `10 Ctrl+D` / `10 Ctrl+U` | 临时按指定行数滚动视图 |
| `Ctrl+E` / `Ctrl+Y` | 原生微滚：视图下/上滚 1 行 |
| `Ctrl+F` / `Ctrl+B` | 整页下/上翻，适合真的想大跳 |
| `zz` | 把当前行重新放到窗口中间 |

> Vim 默认 `Ctrl+D/U` 是“移动光标半屏，然后窗口跟着变”，不像网页滚轮以视线为锚点。当前配置把它改成小步滚动窗口本身；配合 `scrolloff=6`，光标附近会持续保留上下文，不容易滚丢。

---

## Git 操作（自定义配置）

| 按键 | 操作 |
|------|------|
| `]h` / `[h` | 跳到下一个 / 上一个 Git 改动块（hunk） |
| `Space gd` | 打开当前未提交改动的 diff 视图 |
| `Space gh` | 当前文件 Git 历史；逐条比较每次提交前后的快照 |
| `Space gH` | 整个仓库 Git 历史；按提交浏览所有受影响文件 |
| `Space gq` | 关闭 diff 视图 |

> `hunk` 可以理解成一整块连续的改动，不管这块里是新增、删除还是修改。`[h` / `]h` 就是在这些改动块之间跳。
>
> 在 file history 面板里用 `j` / `k` 选择提交，按 `Enter` 后右侧左窗是提交前（父版本）、右窗是提交后；`L` 查看完整提交信息，`y` 复制 commit hash，`g?` 查看该面板全部快捷键。diff 比较窗口默认显示完整文件；需要只看改动附近时可按 `zM`，再按 `zR` 恢复全部展开。

---

## 插件管理

| 命令 | 操作 |
|------|------|
| `:Lazy` | lazy.nvim 管理面板 |
| `:Lazy sync` | 同步所有插件 |
| `:Mason` | LSP/工具安装面板 |

---

# Tmux

> 前缀键 = `Ctrl+B`（写作 `prefix`）。已启用鼠标支持。

## Session

| 操作 | 命令/按键 |
|------|----------|
| 新建 | `tmux new -s name` |
| 附加 | `tmux a -t name` |
| 列出 | `tmux ls` |
| 脱离 | `prefix d` |
| 切换 | `prefix s` |
| 重命名 | `prefix $` |

## Window（标签页）

| 按键 | 操作 |
|------|------|
| `prefix c` | 新建；始终在 tmux 所在机器打开，并继承当前 pane 的本地路径，不复用当前 ssh 会话 |
| `prefix ,` | 重命名 |
| `prefix n` / `prefix p` | 下/上一个 |
| `prefix 数字` | 跳到第 N 个 |
| `prefix w` | 交互式选择 |
| `prefix &` | 关闭 |

## Pane（面板）— 自定义配置

### 创建

| 按键 | 操作 |
|------|------|
| `prefix %` | 向右分割；本地 shell 继承当前路径，ssh shell 复用远端登录并尝试回到远端当前目录 |
| `prefix "` | 向下分割；本地 shell 继承当前路径，ssh shell 复用远端登录并尝试回到远端当前目录 |
| `prefix v` | 向左分割（自定义）；本地 shell 继承当前路径，ssh shell 复用远端登录并尝试回到远端当前目录 |
| `prefix s` | 向上分割（自定义）；本地 shell 继承当前路径，ssh shell 复用远端登录并尝试回到远端当前目录 |

### 切换

| 按键 | 操作 |
|------|------|
| `prefix 方向键` | 按方向切换 |
| `prefix q` → 数字 | 显示编号后跳转（2 秒显示） |
| `prefix o` | 循环下一个 |
| `prefix ;` | 上一个活跃 pane |
| 鼠标点击 | 直接切换 |

### 调整

| 按键 | 操作 |
|------|------|
| `prefix z` | 全屏/还原当前 pane（zoom） |
| `prefix Space` | 切换布局 |
| `prefix {` / `}` | 和前/后 pane 交换 |
| 鼠标拖拽边框 | 调整大小 |

### 关闭

| 按键 | 操作 |
|------|------|
| `prefix x` | 关闭（会确认） |
| `Ctrl+D` | 退出 shell |

### 移动 Pane（自定义）

| 按键 | 操作 |
|------|------|
| `prefix J` | 从其他 window 拉 pane 过来 |
| `prefix S` | 把当前 pane 发到其他 window |

## Copy Mode（vi 风格，自定义配置）

进入：`prefix [`

| 按键 | 操作 |
|------|------|
| `v` | 开始选择 |
| `y` / `Enter` | 复制并退出 |
| 双击 / 三击 | 选词/选行并复制（不退出） |
| `Alt+Left` / `Alt+Right` | 跳词 |
| `q` | 退出 copy mode |

剪贴板自动检测优先级：macOS > Wayland > X11 > WSL

> 说明：ssh 复用只作用于 pane split，不作用于 `prefix c` 新建 window。`prefix c` 会回到 tmux 所在机器，并沿用当前 pane 的本地路径。
>
> ssh 复用依赖两端 shell 都加载本仓库里的 `shell/.shared_rc`。Linux/WSL 远端还需要 `shell/.bash_profile -> .bashrc` 这条登录链路存在，否则通过 SSH 进入的 login shell 不会加载 tmux 上下文 hook。
>
> 若当前 pane 是通过 `ssh <alias>` 连接的，tmux 会优先复用本地 ssh 进程里的 alias，因此 `~/.ssh/config` 中挂在该 alias 上的 ProxyJump、代理、端口、IdentityFile 等配置也会一并保留。
>
> 首次启用这套能力后，需要先执行一次 `bash ~/.dotfiles/setup.sh` 创建辅助脚本链接，再在 tmux 里 `tmux source-file ~/.tmux.conf` 重新加载配置。
