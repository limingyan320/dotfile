---
name: nvim-quickref
description: Quick reference for the user's personal Neovim config at ~/.dotfiles/nvim/.config/nvim/init.lua. Use whenever the user asks about their nvim setup, custom keymaps, installed plugins, LSP, Telescope, Flash, Oil, Mason, blink.cmp, or any "how do I do X in my nvim" question. Also use when advising on changes to init.lua so you know the surrounding context. Only covers this user's customizations; fall back to generic vim knowledge for built-ins.
---

# Neovim 速查（个人 init.lua）

**Leader** = `Space` · **Plugin manager** = lazy.nvim · **Colorscheme** = tokyonight · **Completion** = blink.cmp · **LSP** = nvim-lspconfig + mason（手动装 server）

权威源：`~/.dotfiles/nvim/.config/nvim/init.lua`。init.lua 改动后需同步本文件、`~/.dotfiles/claude-skills/nvim-quickref/SKILL.md` 和 `~/.dotfiles/docs/nvim-tmux-cheatsheet.md`。

## 选项 & 行为

- `number` + `relativenumber` + `termguicolors`
- 默认缩进：`expandtab = true`，`tabstop = 2`，`shiftwidth = 2`，`softtabstop = 2`（2-space soft tabs）
- Swift 例外：运行时 `ftplugin/swift.vim` 会把 `shiftwidth` / `softtabstop` 设为 4；普通可编辑 buffer 在 `{}` / `[]` / `()` 中间按 `<CR>` 时会自动拆成三行，并让闭括号对齐回起始缩进
- 关闭了 `:` 触发的即时重缩进；像 Python / Lua / JavaScript 里在行尾 `A` 进入插入后输入 `:`，不会再把当前行“纠偏”到新的缩进列
- `foldmethod = expr` + `foldexpr = v:lua.vim.treesitter.foldexpr()`；默认 `foldlevel/foldlevelstart = 99`，可折叠但打开文件时保持全部展开
- 顶部 `winbar` 会显示当前 buffer 名或 `LSP symbol breadcrumb`（例如 `Module > Class > Method`）
- 滚动手感偏 IDE/网页：`scrolloff = 6` 保持光标上下文，`mousescroll = ver:2,hor:6` 降低鼠标滚轮跨度，`smoothscroll = true`；`<C-d>` / `<C-u>` 被改成视图下/上滚 6 行（可加数字前缀），光标尽量留在原位置
- 搜索默认启用 `hlsearch + ignorecase + smartcase`，关闭 `incsearch`；`/pattern` 只登记搜索词并高亮，不滚动当前窗口视野，按 `n` / `N` 才跳转；`*` / `#` 第一次只高亮当前词，同一个词再按才跳转；可用 `/\c...` / `/\C...` 强制切换大小写规则
- IDE 风格辅助：长函数时直接看顶部 `winbar` 知道自己在哪个函数里；想看模块骨架时用 `zc` / `zo` / `za` / `zM` / `zR`
- `clipboard = unnamedplus`；检测到 `$SSH_TTY` / `$SSH_CONNECTION` / `$XDG_SESSION_TYPE=tty` 时自动切到 **OSC 52**（走终端剪贴板，需要 iTerm2/WezTerm/kitty 等允许剪贴板访问，tmux 需 `set-clipboard on`）
- `autoread` + `updatetime = 500`（缩短 `CursorHold` 触发间隔让外部改动近实时可见）
- 外部改动侦测：`FocusGained` / `BufEnter` / `CursorHold{,I}` / `TermLeave` 主动 `checktime`；每个文件 buffer 还会跑一个 `uv.new_fs_event` watcher，被外部改动后弹 WARN `文件被外部修改，已重新加载`
- terminal mode 使用不闪烁的黄色实心块光标；`<leader>t` 打开完整 terminal buffer；macOS `Caps+N` 经 Karabiner 发送 `<C-S-Del>`，可从 terminal input / terminal-normal 返回同 tab 普通编辑窗口；完整 agent 独占当前窗口时会恢复它替换前的 buffer
- `<M-a>` 用 `j` / `k` 菜单选择 Codex 或 Grok，选择结果保存在本机 Neovim state；`<M-/>` 对两者都显示 / 隐藏当前普通窗口里的专属 full terminal buffer，再按回到原 buffer，若已显示在其他窗口则直接聚焦
- Codex 以 `codex --yolo --no-alt-screen`、Grok 以 `grok --yolo` 从首次打开时的 git 根启动；两者都是可移动、分屏、关闭并进入 buffer 管理器的普通 listed session buffer。terminal-normal 滚离最新输出后会锁定 cursor / topline，手动滚到底部、按 `G` 或进入 terminal-input 才解锁；Codex 还可用 `[a` / `]a` 跳回答、`gx` 打开路径，并在 full terminal 位于前台、当前窗口且最新输出可见时自动 check 完成未读及关闭 macOS popup
- 底部 drawer 只保留普通 shell：始终跟随当前 tab、全宽贴底，不参与上方窗口布局；`<C-/>` / `<C-_>` 切换，`<M-+>` / `<M-->`（含 `<M-=>`）调整 drawer 高度
- `<leader>fb` 和精确输入 `:ls<CR>` 打开同一个安全 Telescope session buffer 管理器；`<leader>t` 完整 terminal、Codex 和 Grok 都可列出、预览、切换，`dd` 确认后可结束进程；底部 shell drawer buffer 永不进入列表或删除范围
- Neovim 0.12 live session：交互式 shell 的 `nvim` / `nvim .` / `vim` 由独立的 `dotfiles-nvim-host` tmux server 托管，host 需通过 RPC 探活才会接入 UI；nvim 端在环境变量缺失时会补与 `.shared_rc` 相同的默认 session 目录 / tmux server，新建失败会清理本次刚拉起的空 host；terminal 意外关闭后进程仍存活；`<leader>d` 主动脱离；`<leader>fs` 打开原生 Session Dashboard，聚焦 session 时自动展开 tag，`<leader>fS` 直接进入当前 session 的 Tag 模式；Dashboard 支持连接、新建、重命名、Session / Tag 回收站、Codex 状态动画和人工进度日志；live Session Trash 保留 24 小时且到期时跳过 attached UI / working Codex，Tag Trash 保留 30 天；已结束 Session 的 Tag 以 `ENDED` / `Past Session Notes` 保留且可手动整组删除；日志约 400ms debounce 自动保存；跨 session RPC 总超时 700ms；普通 `tmux ls` 不显示隐藏 host
- netrw 禁用（`vim.g.loaded_netrw = 1`），文件浏览全走 oil

## 自定义键位（非插件）

| 模式 | 键 | 动作 |
|------|----|------|
| n/i | `<F2>` | toggle paste mode |
| n | `<leader>vp` | toggle paste mode |
| n | `<leader>z` | 临时放大当前普通 session window；drawer 保持在底部，再按一次恢复原分屏布局；drawer 内拒绝执行 |
| n | `<C-w>V` / `<C-w>S` | 在右侧 / 下方创建 split 并直接聚焦新窗口；原生小写 `<C-w>v/s` 继续在左侧 / 上方创建并聚焦 |
| n | `<C-w>c/q` | 关闭当前普通窗口；`<leader>t` 完整 terminal 同样可关闭，底部 drawer 内拒绝执行 |
| n | `<C-w>o` | 只保留当前普通 session window 和底部 drawer；可从完整 terminal 执行，drawer 内拒绝执行 |
| n | `<leader>d` | detach 当前 Nvim UI，完整保留窗口、buffer、terminal / agent 进程供稍后恢复 |
| n | `<leader>yp` | 复制当前 buffer 绝对路径到 `+` 和 `"` |
| n | `<leader>t` | 在当前上下文目录开完整 terminal buffer 并直接进入输入；若当前 buffer 是 terminal，则沿用该 shell cwd |
| n/t（terminal） | `Caps+N`（Karabiner → `<C-S-Del>`） | 退出 terminal input 并跳回同 tab 最近的普通编辑窗口；完整 agent 没有其他编辑窗口时恢复它替换前的 buffer |
| n/i/t | `<C-/>` / `<C-_>` | toggle 底部普通 shell；首次打开按当前上下文目录启动，显示后自动进入输入，隐藏时保留进程 |
| n/i/t | `<M-a>` | 打开 agent 选择菜单；`j` / `k` 移动、`Enter` 确认、`Esc` 取消，只显示当前 `PATH` 中可用的 Codex / Grok，选择结果跨 live session 和重启保留 |
| n/i/t | `<M-/>` | toggle 最近选择的 agent；Codex / Grok 都是当前普通窗口里的 listed full terminal，再按恢复原 buffer；显示后停在 terminal-normal |
| n（Codex terminal） | `[a` / `]a` | 跳到上 / 下一条 Codex 回答开头并置顶；连续按可逐轮翻阅，支持 `2[a` / `2]a` 数字前缀 |
| n/x（Codex terminal） | `gx` | 打开光标下或 visual 选中的绝对/项目相对路径；支持 `:行:列` / `#L行C列`，忽略末尾或紧邻后续正文的中英文标点，复用上一个非 terminal 编辑窗口并跳到定位 |
| n/i/t | `<M-+>` / `<M-->` | 增高 / 降低当前底部 shell drawer；`<M-=>` 也会增高，这是唯一允许的 drawer 高度调整入口 |
| n | `<C-d>` / `<C-u>` | 视图下/上滚 6 行，光标尽量留在原位置；可用 `10<C-d>` / `10<C-u>` 临时指定行数 |
| n | `<C-e>` / `<C-y>` | 原生微滚：视图下/上滚 1 行 |
| i | `<CR>` | 智能回车：已选中补全项时确认；否则正常换行；在 `{}` / `[]` / `()` 中间会自动拆行并对齐闭括号 |
| i | `<C-a>` / `<C-e>` | 跳到当前行第一个非空白字符 / 行尾，并保持 insert mode |
| n/x/i | `<M-h>` / `<M-l>` | 左移 / 右移当前行或选区缩进 |
| n/x/i | `<M-Left>` / `<M-Right>` | 按单词向左 / 向右跳；insert 模式下跳完继续停留在插入模式 |
| n/v | `H` | `^`（行首非空） |
| n/v | `L` | `$`（行尾） |
| n/x | `J` / `K` | 跳到下 / 上一个非空 block 的第一行；不写入 jumplist |
| v | `<` / `>` | 缩进并保持选区（`<gv` / `>gv`） |
| v | `(` `[` `{` `'` `"` `` ` `` | 包裹选区（走 mini.surround；圆/方/花括号不加内侧空格） |
| x | `#` | 切换行注释（调用 `Comment.api.toggle.linewise`） |

## 插件（按 init.lua 顺序）

### `stevearc/oil.nvim` — 文件浏览（替代 netrw）
- `lazy = false`（启动时要接管 `nvim <dir>` / `nvim .`）
- `-`：普通 buffer 打开当前文件所在目录；terminal buffer 的 normal 模式下打开当前 shell cwd；oil buffer 内返回上一级
- `<C-p>`（oil buffer 内自定义）：用 Telescope 搜索当前 oil 目录里的文件
- `gy`（oil buffer 内自定义）：复制光标下 entry 的绝对路径到 `+` / `"`
- `show_hidden = true`, `watch_for_changes = true`, `default_file_explorer = true`

### `folke/tokyonight.nvim` — 配色
- `priority = 1000`，启动即 `colorscheme tokyonight`

### `folke/flash.nvim` — 跳转
- `event = VeryLazy`
- `s`（n/x/o）= `flash.jump()`
- `S`（n/x/o）= `flash.treesitter()`

### `nvim-treesitter/nvim-treesitter` — 语法
- `event = BufReadPost`, `build = :TSUpdate`
- `treesitter_languages` 清单启动后用新版 `require("nvim-treesitter").install(...)` 自动补齐缺失 parser / query
- language 清单：lua, python, ecma, javascript, jsx, typescript, tsx, html, css, json, yaml, bash, markdown, markdown_inline, vim, vimdoc, go, gomod, gosum, gowork
- React filetype 映射：`javascriptreact` 使用 `javascript` parser；`typescriptreact` 使用 `tsx` parser

### `nvim-lualine/lualine.nvim` — 状态栏
- `event = VeryLazy`
- Powerline 三角分隔符：`section_separators = { left = "", right = "" }`, `component_separators = { left = "", right = "" }`
- 最左侧用固定青色组件显示当前 live session 的逻辑名称，后面才是动态着色的 Vim mode；未命名时回退为项目目录名，最长 20 显示列，非 session 实例隐藏
- Session Dashboard 重命名会主动刷新 lualine，名称立即更新

### `SmiteshP/nvim-navic` — 当前代码位置 breadcrumb
- 作为 `nvim-lspconfig` 依赖加载
- 在 `LspAttach` 时对支持 `documentSymbolProvider` 的 LSP 自动 attach
- `winbar` 动态显示当前位置；无 LSP symbol 时回退显示当前文件名

### 原生 Live Session Dashboard

`<leader>fs` 打开 normal-first 的 Mason 风格 Dashboard 并进入 `Nvim Sessions` 模式；live session 按 `CURRENT` → `DETACHED` → `ATTACHED` 排列。最左侧固定 3 格 agent 列中，流动 `●··` 表示 Codex working，闪烁红色 `!` 表示 ready/unread；`◆ 数量 · 新鲜度` 表示已有人工进度，`◇ 0` 表示无记录。默认打开和按 `R` 都不加载统计模块、不采样或预留内存列；只有 Session 模式按 `M` 才现场加载并显示每个 session 的 `MEM` 总量、`N / L / C / O`（Nvim / LSP / Codex / Other）、全局汇总与未归属 Nvim 的 `U`，再次按 `M` 更新快照，关闭 Dashboard 后丢弃。macOS 统计 physical footprint，Linux 统计 PSS + swap，失败时回退 RSS。聚焦的 session 有 tag 时会自动 cascade 展开，移动到其他 session 后旧 cascade 自动收起。跨 session RPC 仍并行且总超时 700ms，日志只从本机 `${DOTFILES_NVIM_SESSION_DIR}/notes/` 读取。

Session 模式中 `j` / `k`、`gg` / `G` 只移动 session，`Enter` 连接，`t` 进入 `Session Tags · 名称`；`c` 新建，`r` / `<C-r>` 重命名；`dd` 把 live session 移入保留 24 小时的回收站，目标为 `CURRENT` 时只 detach UI；`T` 显示 `TRASHED`，`u` 恢复，回收站内再次 `dd` 才确认永久结束；行内显示 `expires` 倒计时，attached UI / working Codex 时显示 `expiry paused`。`P` 显示 `Past Session Notes`，`ENDED` 行 `dd` 永久删除其全部 Tag、metadata 和 Tag Trash。Tag 模式的 `dd` / `x` 移入保留 30 天的 `Tag Trash`，`T` 切换、`u` 恢复，回收站内 `dd` / `x` 永久删除。`R` 刷新并执行到期检查；`?` 显示帮助；Session 模式的 `q` / `Esc` 关闭 Dashboard。

Tag 操作层只是 Dashboard 的 UI 子模式，两层都仍处于 Vim normal mode。进度编辑器是真实 Markdown buffer，完整支持 normal / insert；TextChanged 停止约 400ms 后自动写盘，`InsertLeave` / `BufLeave` 也强制保存，normal mode `q` 保存并返回 Tag 模式，`Ctrl+S` 立即保存。记录按原始 epoch 和本机时区显示；Session 结束后 Tag 仍可按 `P` 作为 Past Notes 查看和编辑，Past Notes 不自动过期。到期检查在新交互式 Nvim 启动、Dashboard 打开或 `R` 时运行。`<leader>fS` 直接进入当前 Session 的 Tag 模式。

### `stevearc/dressing.nvim` — 选择浮窗

- `lazy = false`，确保首次按 `<M-a>` 时 agent 菜单已经接管 `vim.ui.select`
- agent 菜单固定使用 builtin backend，不显示数字，支持 normal mode 的 `j` / `k`、`Enter`、`Esc`
- modified buffer 和完整 terminal 删除确认固定使用 builtin backend、相对安全目标窗口显示，第一项为 `Cancel`；modified buffer 支持保存后删除和丢弃后删除，terminal 确认后结束进程
- 其他 `vim.ui.select` 默认不接管；仅保留既有 Session / Tag 删除确认浮窗

### `nvim-telescope/telescope.nvim` (+ `telescope-file-browser.nvim`)

项目根逻辑（`project_root()`）：当前 buffer 文件所在目录的 git 根 → 非 git 时用该目录 → 没文件时用 `getcwd()`。

忽略：`.git/` · `node_modules/` · `.DS_Store` · `target/` · `dist/` · `build/`

picker 内自定义键位：

| 键 | 动作 |
|----|------|
| `<M-v>` | `select_vertical`（左右分屏打开） |
| `<M-s>` | `select_horizontal`（上下分屏打开） |
| `<C-h>` | `toggle_hidden`：重开 picker，打开 `hidden = true` + `no_ignore = true`，**保留当前输入** |

buffer 管理器是独立的 Telescope picker，默认 normal mode：`j` / `k` 移动并实时预览，`Enter` 在当前安全 session-buffer 窗口打开，`dd` 删除，`q` / `Esc` 取消并恢复发起窗口。`<leader>t` 的完整 terminal 也在列表中，选择后自动进入 terminal 输入；`dd` 会先确认再结束进程并关闭 buffer。clean 文件 buffer 直接删除；modified buffer 弹出默认停在 `Cancel` 的三项选择：`Cancel`、`Save and delete`、`Discard changes and delete`；未命名 buffer 选择保存时再询问文件路径。所有 select / split / tab 打开 action 都被收口到重新校验后的安全窗口，quickfix 批量导出在此 picker 内禁用。

picker 的 results / preview / prompt 始终限制在目标窗口矩形内；drawer 可见时不会改变其 buffer 或高度。从底部 shell drawer 发起会复用同 tab 的普通编辑窗口；没有安全目标时才在 drawer 上方创建 unlisted `nofile` 临时 split，取消时清掉，选中时保留。完整 terminal / agent 本身是安全目标，picker 直接复用其窗口，选择其他 buffer 时不产生额外 split；目标窗口中途变成 drawer 时会重新路由。

file_browser 扩展 opts：`hidden = true`, `grouped = true`（目录排前面）, `respect_gitignore = false`, `hijack_netrw = false`（交给 oil）

全局键位：

| 键 | 动作 |
|----|------|
| `<C-p>` | 普通文件里 `find_files({ cwd = project_root() })`；oil 目录视图里用当前 oil 目录 |
| `<leader>fg` | `live_grep({ cwd = project_root() })` |
| `<leader>fb` | 安全 session buffer 管理器（与精确 `:ls<CR>` 相同） |
| `<leader>fe` | file_browser（项目根，`select_buffer`） |
| `<leader>fE` | file_browser（`%:p:h`，当前文件目录） |

### `lewis6991/gitsigns.nvim` — Git 侧边栏
- `event = { BufReadPre, BufNewFile }`
- `]h` / `[h`：跳到下一个 / 上一个 git hunk（连续改动块）

### `sindrets/diffview.nvim` — Git diff 视图
- `cmd = { DiffviewOpen, DiffviewFileHistory }`（按命令懒加载）

| 键 | 动作 |
|----|------|
| `<leader>gd` | `:DiffviewOpen` |
| `<leader>gh` | `:DiffviewFileHistory %`（当前文件历史） |
| `<leader>gH` | `:DiffviewFileHistory`（整个仓库历史） |
| `<leader>gq` | `:DiffviewClose` |

- diff / file history 右侧比较窗口默认全部展开；仍可用 `zM` / `zR` 折叠 / 展开
- file history 面板中用 `j` / `k` 选择提交，`Enter` 查看该提交的父版本与提交后版本，`L` 查看完整提交信息，`y` 复制 commit hash，`g?` 查看上下文帮助

### `numToStr/Comment.nvim` — 注释
- `event = { BufReadPre, BufNewFile }`
- 默认 `gcc` / `gc{motion}` / visual `gc` 保留；外加自定义 visual `#`
- 通过 `pre_hook` 优先使用当前 buffer 的原生 `commentstring`，避免内置 treesitter 注释推导在某些文件里报错；所以 Python 会走 `# %s`，Lua 会走 `-- %s`

### `sphamba/smear-cursor.nvim` — 光标拖影动画
- `event = VeryLazy`

### `williamboman/mason.nvim` + `mason-lspconfig.nvim` + `neovim/nvim-lspconfig` — LSP
- mason-lspconfig **不自动安装** server（`ensure_installed` 为空）—— 无网 / 代理异常机器能正常启动
- 需要时手动 `:MasonInstall <server>`；推荐 `lua_ls`, `pyright`, `ts_ls`
- `lua_ls` 预配置：`Lua.diagnostics.globals = { "vim" }`, `workspace.checkThirdParty = false`, `telemetry.enable = false`
- 所有 server 的 capabilities 通过 `vim.lsp.config("*", { capabilities = require("blink.cmp").get_lsp_capabilities() })` 注入
- `event = { BufReadPre, BufNewFile }`

LSP 键位：

| 键 | 动作 |
|----|------|
| `gd` | `vim.lsp.buf.definition` |
| `gD` | 在右侧 vertical split 打开定义；多个定义时同时写入当前窗口 location list |
| `gr` | `vim.lsp.buf.references` |
| `<leader>k` | `vim.lsp.buf.hover` |
| `<leader>rn` | `vim.lsp.buf.rename` |
| `<leader>ca` | `vim.lsp.buf.code_action` |
| `[d` / `]d` | `diagnostic.goto_prev` / `goto_next` |

### `saghen/blink.cmp` — 补全
- `version = '*'`，依赖 `rafamadriz/friendly-snippets`
- `keymap = { preset = 'enter' }`（更接近 IDE）:
  - `<C-space>` 触发补全
  - `<Up>` / `<Down>` 或 `<C-p>` / `<C-n>` 上下选择
  - `<CR>` 只在**你已经选中候选项**时确认补全；否则正常换行；如果光标正在 `{}` / `[]` / `()` 中间，会智能拆行并让闭括号对齐
  - `<C-e>` 关闭补全菜单
  - `<Tab>` / `<S-Tab>` 只用于 snippet 前进 / 后退
- `completion.list.selection = { preselect = false, auto_insert = false }`：不默认预选第一项，避免回车误补全
- `sources.default = { lsp, path, snippets, buffer }`
- `appearance = { use_nvim_cmp_as_default = true, nerd_font_variant = 'mono' }`

### `echasnovski/mini.pairs` — 自动括号
- `event = VeryLazy`，默认 opts

### `echasnovski/mini.surround` — 包裹
- `event = VeryLazy`，默认 opts
- 默认键位：`sa` add · `sd` delete · `sr` replace · `sf` / `sF` find · `sh` highlight · `sn` update n_lines
- 注意：init.lua 里 visual 模式下 `(` `[` `{` `'` `"` `` ` `` 会走 mini.surround 包裹；圆/方/花括号使用无内侧空格的右括号规则，所以选中 `foo` 后按 `(` 得到 `(foo)`，不是 `( foo )`

## 使用说明

1. **先判断定制还是通用**：用户问 `<leader>fg` 做啥、flash 怎么跳、blink 按哪个键接受补全 → 这里查；用户问 `w` / `dd` / `:s/foo/bar` → vim 通识答。
2. **问到 nvim/tmux 常用操作**时，优先读 `~/.dotfiles/docs/nvim-tmux-cheatsheet.md`，再用本文件补充定制细节。
3. **精确到代码**时读 init.lua：`~/.dotfiles/nvim/.config/nvim/init.lua`。
4. **init.lua 改了之后**，提醒用户同步更新：
   - 本文件（`~/.dotfiles/codex-skills/nvim-quickref/SKILL.md`）
   - Claude skill（`~/.dotfiles/claude-skills/nvim-quickref/SKILL.md`）
   - `~/.dotfiles/docs/nvim-tmux-cheatsheet.md`（通用 vim/tmux 操作速查）
