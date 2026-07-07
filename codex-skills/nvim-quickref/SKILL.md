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
- terminal mode 使用不闪烁的黄色实心块光标；`<leader>t` 打开完整 terminal buffer；`<C-/>` / `<C-_>` 切换底部 terminal 面板，隐藏时保留 shell 状态
- netrw 禁用（`vim.g.loaded_netrw = 1`），文件浏览全走 oil

## 自定义键位（非插件）

| 模式 | 键 | 动作 |
|------|----|------|
| n/i | `<F2>` | toggle paste mode |
| n | `<leader>vp` | toggle paste mode |
| n | `<leader>z` | 像 tmux `prefix z` 一样临时放大当前窗口；再按一次恢复原分屏布局 |
| n | `<leader>yp` | 复制当前 buffer 绝对路径到 `+` 和 `"` |
| n | `<leader>t` | 在当前上下文目录开完整 terminal buffer 并直接进入输入；若当前 buffer 是 terminal，则沿用该 shell cwd |
| n/i/t | `<C-/>` / `<C-_>` | toggle 底部 terminal 面板；首次打开按当前上下文目录启动 shell，隐藏时保留 shell 状态 |
| n/i/t | `<M-+>` / `<M-->` / `<M-0>` | 增高 / 降低 / 重置底部 terminal 面板高度；`<M-=>` 也会增高 |
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

### `SmiteshP/nvim-navic` — 当前代码位置 breadcrumb
- 作为 `nvim-lspconfig` 依赖加载
- 在 `LspAttach` 时对支持 `documentSymbolProvider` 的 LSP 自动 attach
- `winbar` 动态显示当前位置；无 LSP symbol 时回退显示当前文件名

### `nvim-telescope/telescope.nvim` (+ `telescope-file-browser.nvim`)

项目根逻辑（`project_root()`）：当前 buffer 文件所在目录的 git 根 → 非 git 时用该目录 → 没文件时用 `getcwd()`。

忽略：`.git/` · `node_modules/` · `.DS_Store` · `target/` · `dist/` · `build/`

picker 内自定义键位：

| 键 | 动作 |
|----|------|
| `<M-v>` | `select_vertical`（左右分屏打开） |
| `<M-s>` | `select_horizontal`（上下分屏打开） |
| `<C-h>` | `toggle_hidden`：重开 picker，打开 `hidden = true` + `no_ignore = true`，**保留当前输入** |

file_browser 扩展 opts：`hidden = true`, `grouped = true`（目录排前面）, `respect_gitignore = false`, `hijack_netrw = false`（交给 oil）

全局键位：

| 键 | 动作 |
|----|------|
| `<C-p>` | 普通文件里 `find_files({ cwd = project_root() })`；oil 目录视图里用当前 oil 目录 |
| `<leader>fg` | `live_grep({ cwd = project_root() })` |
| `<leader>fb` | `buffers` |
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
| `<leader>gq` | `:DiffviewClose` |

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
