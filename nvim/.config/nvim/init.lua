local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
local uv = vim.uv or vim.loop
if not uv.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable", -- 最新稳定版
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)
vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.clipboard = "unnamedplus"
vim.g.mapleader = " "
-- 统一用 2-space soft tabs，避免新行缩进看起来像硬 Tab 那样过宽
vim.opt.expandtab = true
vim.opt.tabstop = 2
vim.opt.shiftwidth = 2
vim.opt.softtabstop = 2

local function indent_step(bufnr)
  local sw = vim.bo[bufnr].shiftwidth
  if sw == 0 then
    return vim.bo[bufnr].tabstop
  end
  return sw
end

local function indent_text(width, bufnr)
  if width <= 0 then
    return ""
  end

  if vim.bo[bufnr].expandtab then
    return string.rep(" ", width)
  end

  local ts = vim.bo[bufnr].tabstop
  local tabs = math.floor(width / ts)
  local spaces = width % ts
  return string.rep("\t", tabs) .. string.rep(" ", spaces)
end

local function shift_current_line(delta)
  local bufnr = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_get_current_line()
  local leading = line:match("^%s*") or ""
  local content = line:sub(#leading + 1)
  local current_width = vim.fn.indent(row)
  local new_width = math.max(0, current_width + delta * indent_step(bufnr))
  local new_indent = indent_text(new_width, bufnr)

  vim.api.nvim_set_current_line(new_indent .. content)
  local new_col = math.max(0, col + (#new_indent - #leading))
  vim.api.nvim_win_set_cursor(0, { row, new_col })
end

local function paired_block_enter()
  local bufnr = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_get_current_line()
  local left = col > 0 and line:sub(col, col) or ""
  local right = line:sub(col + 1, col + 1)
  local pairs = { ["{"] = "}", ["["] = "]", ["("] = ")" }

  if pairs[left] ~= right then
    return nil
  end

  local before = line:sub(1, col)
  local after = line:sub(col + 1)
  local base_width = vim.fn.indent(row)
  local base_indent = indent_text(base_width, bufnr)
  local inner_indent = indent_text(base_width + indent_step(bufnr), bufnr)

  vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, {
    before,
    inner_indent,
    base_indent .. after,
  })
  vim.api.nvim_win_set_cursor(0, { row + 1, #inner_indent })
  vim.schedule(function()
    vim.cmd("startinsert")
  end)

  return true
end

local function smart_enter()
  local ok, cmp = pcall(require, "blink.cmp")
  if ok then
    local visible_ok, visible = pcall(cmp.is_visible)
    if visible_ok and visible then
      local accepted = cmp.accept()
      if accepted then
        return
      end
    end
  end

  if paired_block_enter() then
    return
  end

  local cr = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
  vim.api.nvim_feedkeys(cr, "n", false)
end

local function attach_smart_enter(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  if vim.bo[bufnr].buftype ~= "" or not vim.bo[bufnr].modifiable then
    return
  end

  if vim.b[bufnr].smart_enter_attached then
    return
  end

  vim.b[bufnr].smart_enter_attached = true
  vim.keymap.set("i", "<CR>", smart_enter, {
    buffer = bufnr,
    desc = "Smart enter",
  })
end

-- SSH / 纯 tty 环境下没有 $DISPLAY，xclip/wl-copy 都失效，
-- 改用 OSC 52 让终端（iTerm2/WezTerm/kitty 等）把内容写到本地剪贴板。
-- 需要外层 tmux 开启 set-clipboard on、iTerm2 允许剪贴板访问。
if vim.env.SSH_TTY or vim.env.SSH_CONNECTION or vim.env.XDG_SESSION_TYPE == "tty" then
  vim.g.clipboard = {
    name = "OSC 52",
    copy = {
      ["+"] = require("vim.ui.clipboard.osc52").copy("+"),
      ["*"] = require("vim.ui.clipboard.osc52").copy("*"),
    },
    paste = {
      ["+"] = require("vim.ui.clipboard.osc52").paste("+"),
      ["*"] = require("vim.ui.clipboard.osc52").paste("*"),
    },
  }
end
vim.opt.autoread = true -- 文件被外部修改时自动重新读取

local function toggle_paste_mode()
  vim.opt.paste = not vim.opt.paste:get()
  vim.notify("paste mode: " .. (vim.opt.paste:get() and "on" or "off"))
end

local function toggle_window_zoom()
  if vim.t.dotfiles_zoomed then
    if #vim.api.nvim_list_tabpages() > 1 then
      vim.cmd("tabclose")
    else
      vim.notify("没有可恢复的原始布局", vim.log.levels.WARN)
    end
    return
  end

  if #vim.api.nvim_tabpage_list_wins(0) <= 1 then
    vim.notify("当前 tab 只有一个窗口", vim.log.levels.INFO)
    return
  end

  vim.cmd("tab split")
  vim.t.dotfiles_zoomed = true
end

vim.keymap.set({ "n", "i" }, "<F2>", toggle_paste_mode, { desc = "Toggle paste mode" })
vim.keymap.set("n", "<leader>vp", toggle_paste_mode, { desc = "Toggle paste mode" })
vim.keymap.set("n", "<leader>z", toggle_window_zoom, { desc = "Toggle window zoom" })

local external_change_group = vim.api.nvim_create_augroup("DotfilesExternalChanges", { clear = true })
local file_watchers = {}

local function stop_file_watcher(bufnr)
  local watcher = file_watchers[bufnr]
  if watcher then
    watcher:stop()
    watcher:close()
    file_watchers[bufnr] = nil
  end
end

local function start_file_watcher(bufnr)
  stop_file_watcher(bufnr)

  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" or vim.bo[bufnr].buftype ~= "" or vim.fn.isdirectory(path) == 1 then
    return
  end

  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return
  end

  local watcher = vim.uv.new_fs_event()
  if not watcher then
    return
  end

  local ok, err = watcher:start(path, {}, vim.schedule_wrap(function(fs_err)
    if fs_err or not vim.api.nvim_buf_is_valid(bufnr) then
      stop_file_watcher(bufnr)
      return
    end
    if vim.bo[bufnr].modified then
      return
    end
    vim.cmd(("silent! checktime %d"):format(bufnr))
  end))
  if not ok then
    watcher:close()
    vim.schedule(function()
      vim.notify("文件监听启动失败: " .. tostring(err), vim.log.levels.DEBUG)
    end)
    return
  end

  file_watchers[bufnr] = watcher
end

-- 用 oil.nvim 替代 netrw 做文件浏览，禁用内置 netrw 以免冲突
vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1

-- 任意已打开的文件里，<leader>yp 复制当前 buffer 的绝对路径
vim.keymap.set("n", "<leader>yp", function()
  local path = vim.fn.expand("%:p")
  if path == "" then
    vim.notify("当前 buffer 没有文件名", vim.log.levels.WARN)
    return
  end
  vim.fn.setreg("+", path)
  vim.fn.setreg('"', path)
  vim.notify("已复制: " .. path)
end, { desc = "Yank current buffer abs path" })

-- autoread 本身只在 nvim 有机会检查时才生效。终端里没有 FocusGained 事件，
-- Claude/外部工具改文件后 nvim 不会自动发现。这里在光标停顿、进入 buffer、
-- 终端获得焦点时主动调用 checktime，并在文件被外部改动后给出提示。
vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold", "CursorHoldI", "TermLeave" }, {
  group = external_change_group,
  callback = function()
    if vim.fn.mode() ~= "c" and vim.fn.getcmdwintype() == "" then
      vim.cmd("silent! checktime")
    end
  end,
})
vim.api.nvim_create_autocmd("FileChangedShellPost", {
  group = external_change_group,
  callback = function()
    vim.notify("文件被外部修改，已重新加载", vim.log.levels.WARN)
  end,
})
vim.api.nvim_create_autocmd({ "BufReadPost", "BufFilePost", "BufWritePost" }, {
  group = external_change_group,
  callback = function(args)
    start_file_watcher(args.buf)
  end,
})
vim.api.nvim_create_autocmd({ "BufDelete", "BufUnload", "BufWipeout" }, {
  group = external_change_group,
  callback = function(args)
    stop_file_watcher(args.buf)
  end,
})
-- 缩短 CursorHold 触发间隔（默认 4000ms），让外部改动几乎即时可见
vim.opt.updatetime = 500

vim.keymap.set("n", "<leader>t", function()
  local buf_name = vim.api.nvim_buf_get_name(0)
  local dir

  if buf_name:match("^oil://") then
    dir = buf_name:gsub("^oil://", "")
  elseif buf_name ~= "" then
    dir = vim.fn.fnamemodify(buf_name,":p:h")
  end
  
  if not dir or vim.fn.isdirectory(dir) == 0 then
    dir = vim.fn.getcwd()
  end
  vim.cmd("enew")
  vim.fn.termopen(vim.o.shell,{ cwd = dir })
end, { desc = "Terminal in current file dir"})


vim.opt.termguicolors = true

-- 缩进后保持选中
vim.keymap.set("v", "<", "<gv")
vim.keymap.set("v", ">", ">gv")
vim.keymap.set("n", "<M-h>", "<<", { desc = "Indent left" })
vim.keymap.set("n", "<M-l>", ">>", { desc = "Indent right" })
vim.keymap.set("x", "<M-h>", "<gv", { desc = "Indent left" })
vim.keymap.set("x", "<M-l>", ">gv", { desc = "Indent right" })
vim.keymap.set("i", "<M-h>", function()
  shift_current_line(-1)
  vim.schedule(function()
    vim.cmd("startinsert")
  end)
end, { desc = "Indent left" })
vim.keymap.set("i", "<M-l>", function()
  shift_current_line(1)
  vim.schedule(function()
    vim.cmd("startinsert")
  end)
end, { desc = "Indent right" })

-- H/L 快速跳转行首行尾（原始 0/$ 仍可用）
vim.keymap.set({ "n", "v" }, "H", "^")
vim.keymap.set({ "n", "v" }, "L", "$")

vim.keymap.set("v", "(", "sa(", { remap = true })
vim.keymap.set("v", "[", "sa[", { remap = true })
vim.keymap.set("v", "{", "sa{", { remap = true })
vim.keymap.set("v", "'", "sa'", { remap = true })
vim.keymap.set("v", '"', 'sa"', { remap = true })
vim.keymap.set("v", "`", "sa`", { remap = true })
vim.keymap.set("x", "#", "gc", {
  desc = "Toggle comment for selection",
  remap = true,
})
vim.api.nvim_create_autocmd("BufEnter", {
  callback = function(args)
    attach_smart_enter(args.buf)
  end,
})
attach_smart_enter(0)

require("lazy").setup({
  -- 文件浏览（替代 netrw）：把目录当 buffer 编辑，按 - 回到父目录
  {
    "stevearc/oil.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    lazy = false, -- 需要在启动时接管目录打开（nvim .）
    keys = {
      { "-", "<cmd>Oil<cr>", desc = "Open parent directory (oil)" },
    },
    opts = {
      default_file_explorer = true,
      watch_for_changes = true,
      view_options = {
        show_hidden = true,
      },
      keymaps = {
        ["gy"] = {
          desc = "Yank abs path of entry under cursor",
          callback = function()
            local oil = require("oil")
            local entry = oil.get_cursor_entry()
            local dir = oil.get_current_dir()
            if not entry or not dir then return end
            local full = dir .. entry.name
            vim.fn.setreg("+", full)
            vim.fn.setreg('"', full)
            vim.notify("已复制: " .. full)
          end,
        },
      },
    },
  },
  {
    "folke/tokyonight.nvim",
    lazy = false,
    priority = 1000,
    config = function()
      vim.cmd.colorscheme("tokyonight")
    end,
  },
  {
    "folke/flash.nvim",
    event = "VeryLazy",
    opts = {},
    keys = {
      -- 绑定 s 键为向下/全局闪现
      { "s", mode = { "n", "x", "o" }, function() require("flash").jump() end, desc = "Flash Jump" },
      -- 绑定 S 键为基于代码结构的闪现
      { "S", mode = { "n", "x", "o" }, function() require("flash").treesitter() end, desc = "Flash Treesitter" },
    },
  },
  {
    "nvim-treesitter/nvim-treesitter",
    build = ":TSUpdate",
    event = "BufReadPost",
    opts = {
      ensure_installed = {
        "lua", "python", "javascript", "typescript", "html", "css",
        "json", "yaml", "bash", "markdown", "markdown_inline", "vim", "vimdoc",
      },
    },
  },
  -- 底部状态栏（箭头分隔符，显示模式/文件/路径/git 分支等）
  {
    "nvim-lualine/lualine.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    event = "VeryLazy",
    opts = {
      options = {
        section_separators = { left = "", right = "" },
        component_separators = { left = "", right = "" },
      },
    },
  },
  -- 文件搜索（Ctrl+P 搜文件，<leader>fg 全局搜内容）
  {
    "nvim-telescope/telescope.nvim",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "nvim-telescope/telescope-file-browser.nvim",
    },
    config = function()
      local telescope = require("telescope")
      local actions = require("telescope.actions")
      local action_state = require("telescope.actions.state")
      local builtin = require("telescope.builtin")

      -- 找当前文件所在的项目根目录（git 根，没有则用文件目录）
      local function project_root()
        local file = vim.api.nvim_buf_get_name(0)
        local dir = (file ~= "" and vim.fn.fnamemodify(file, ":p:h")) or vim.fn.getcwd()
        local git = vim.fn.systemlist({ "git", "-C", dir, "rev-parse", "--show-toplevel" })[1]
        if vim.v.shell_error == 0 and git and git ~= "" then return git end
        return dir
      end

      -- 切换显示隐藏文件 / 忽略 .gitignore，保留当前输入
      local function toggle_hidden(prompt_bufnr)
        local line = action_state.get_current_line()
        local picker = action_state.get_current_picker(prompt_bufnr)
        local cwd = picker.cwd or project_root()
        actions.close(prompt_bufnr)
        builtin.find_files({
          cwd = cwd,
          hidden = true,
          no_ignore = true,
          default_text = line,
        })
      end

      telescope.setup({
        defaults = {
          file_ignore_patterns = {
            "%.git/", "node_modules/", "%.DS_Store", "target/", "dist/", "build/",
          },
          mappings = {
            i = {
              ["<M-v>"] = "select_vertical",
              ["<M-s>"] = "select_horizontal",
              ["<C-h>"] = toggle_hidden,
            },
          },
        },
        extensions = {
          file_browser = {
            hijack_netrw = false, -- 交给 oil 处理
            hidden = true,
            grouped = true, -- 目录排在文件前
            respect_gitignore = false,
          },
        },
      })
      telescope.load_extension("file_browser")

      -- 目录浏览 picker：可钻进子目录，用 telescope 默认分屏键打开
      --   <CR>  当前窗口, <C-v> 左右分屏, <C-x> 上下分屏, <C-t> 新标签
      vim.keymap.set("n", "<leader>fe", function()
        telescope.extensions.file_browser.file_browser({
          path = project_root(),
          select_buffer = true,
        })
      end, { desc = "File browser (project root)" })

      vim.keymap.set("n", "<leader>fE", function()
        telescope.extensions.file_browser.file_browser({
          path = "%:p:h",
          select_buffer = true,
        })
      end, { desc = "File browser (current file dir)" })

      vim.keymap.set("n", "<C-p>", function()
        builtin.find_files({ cwd = project_root() })
      end, { desc = "Find files (project root)" })

      vim.keymap.set("n", "<leader>fg", function()
        builtin.live_grep({ cwd = project_root() })
      end, { desc = "Live grep (project root)" })

      vim.keymap.set("n", "<leader>fb", builtin.buffers, { desc = "Buffers" })
    end,
  },
  -- Git 侧边栏标记（增删改彩色竖条）
  {
    "lewis6991/gitsigns.nvim",
    event = { "BufReadPre", "BufNewFile" },
    opts = {},
  },
  -- Git diff 可视化（:DiffviewOpen 打开 side-by-side diff）
  {
    "sindrets/diffview.nvim",
    cmd = { "DiffviewOpen", "DiffviewFileHistory" },
    keys = {
      { "<leader>gd", "<cmd>DiffviewOpen<cr>", desc = "Git diff" },
      { "<leader>gh", "<cmd>DiffviewFileHistory %<cr>", desc = "File history" },
      { "<leader>gq", "<cmd>DiffviewClose<cr>", desc = "Close diff" },
    },
    opts = {},
  },
  -- 注释：可视模式选中多行后按 # 切换对应语言的行注释
  {
    "numToStr/Comment.nvim",
    event = { "BufReadPre", "BufNewFile" },
    opts = {},
  },
  -- 光标残影动画
  {
    "sphamba/smear-cursor.nvim",
    event = "VeryLazy",
    opts = {},
  },
  -- LSP 配置
  {
    "williamboman/mason.nvim",
    opts = {},
  },
  {
    "williamboman/mason-lspconfig.nvim",
    dependencies = { "williamboman/mason.nvim", "neovim/nvim-lspconfig" },
    opts = {
      -- 不自动安装，避免在无网络/代理异常的机器上启动时报错
      -- 需要 LSP 时在对应机器上手动运行 :MasonInstall <server>
      -- 推荐安装：lua_ls, pyright, ts_ls
    },
  },
  {
    "neovim/nvim-lspconfig",
    event = { "BufReadPre", "BufNewFile" },
    dependencies = { "saghen/blink.cmp" },
    config = function()
      vim.lsp.config("*", {
        capabilities = require("blink.cmp").get_lsp_capabilities(),
      })
      vim.lsp.config("lua_ls", {
        settings = {
          Lua = {
            workspace = { checkThirdParty = false },
            telemetry = { enable = false },
            diagnostics = { globals = { "vim" } },
          },
        },
      })
    end,
    keys = {
      { "gd", vim.lsp.buf.definition, desc = "Go to definition" },
      { "gr", vim.lsp.buf.references, desc = "References" },
      { "K", vim.lsp.buf.hover, desc = "Hover" },
      { "<leader>rn", vim.lsp.buf.rename, desc = "Rename" },
      { "<leader>ca", vim.lsp.buf.code_action, desc = "Code action" },
      { "[d", vim.diagnostic.goto_prev, desc = "Prev diagnostic" },
      { "]d", vim.diagnostic.goto_next, desc = "Next diagnostic" },
    },
  },
  -- 补全插件
  {
    'saghen/blink.cmp',
    dependencies = 'rafamadriz/friendly-snippets', -- 可选：提供基础的补全代码片段
    version = '*', -- 使用最新的发布版本
    opts = {
      -- IDE 风格补全：
      -- <C-space> 触发补全
      -- <Up>/<Down> 或 <C-n>/<C-p> 选择候选项
      -- <Enter> 只在你明确选中候选项后确认补全，否则正常换行
      -- <Tab> / <S-Tab> 仅用于 snippet 跳转
      keymap = { preset = 'enter' },
      completion = {
        list = {
          selection = {
            preselect = false,
            auto_insert = false,
          },
        },
      },
      appearance = {
        use_nvim_cmp_as_default = true, -- 让它的外观模仿经典的 nvim-cmp
        nerd_font_variant = 'mono'
      },
      sources = {
        default = { 'lsp', 'path', 'snippets', 'buffer' },
      },
    },
  },
  {
      "echasnovski/mini.pairs",
      event = "VeryLazy",
      opts = {},
  },
  {
      "echasnovski/mini.surround",
      event = "VeryLazy",
      opts = {},
  }
})
