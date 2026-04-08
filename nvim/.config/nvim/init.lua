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

vim.g.mapleader = " "
vim.opt.termguicolors = true

-- 缩进后保持选中
vim.keymap.set("v", "<", "<gv")
vim.keymap.set("v", ">", ">gv")

-- H/L 快速跳转行首行尾（原始 0/$ 仍可用）
vim.keymap.set({ "n", "v" }, "H", "^")
vim.keymap.set({ "n", "v" }, "L", "$")

vim.keymap.set("v", "(", "sa(", { remap = true })
vim.keymap.set("v", "[", "sa[", { remap = true })
vim.keymap.set("v", "{", "sa{", { remap = true })
vim.keymap.set("v", "'", "sa'", { remap = true })
vim.keymap.set("v", '"', 'sa"', { remap = true })
vim.keymap.set("v", "`", "sa`", { remap = true })


require("lazy").setup({
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
    dependencies = { "nvim-lua/plenary.nvim" },
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
      })

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
      -- 默认按键设置：
      -- <C-space> 触发补全
      -- <Enter> 确认选择
      -- <Tab> / <S-Tab> 上下切换
      keymap = { preset = 'default' },
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
