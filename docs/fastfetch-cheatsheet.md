# Fastfetch 速查

## 默认行为

- `ff` 是 `shell/.shared_rc` 里的 shell function，不再是简单 alias
- 新开交互式 shell 时会自动执行 `ff`（tmux 内不自动刷）
- `ff` 跑完会补发一次显示光标控制码，兜住 raw logo / preset 隐藏 cursor 后未恢复的情况
- 默认主题按系统自动分流：
  - macOS -> `macos-rei31`
  - Ubuntu -> `ubuntu-sharingan`
  - 其他系统 -> `plain`

## 可切换主题

| Profile | 效果 | 资源 |
| --- | --- | --- |
| `macos-rei31` | 凌波丽 / EVA 风格 | `fastfetch/presets/macos-rei31.jsonc` |
| `ubuntu-sharingan` | 三勾玉写轮眼像素风 | `fastfetch/presets/ubuntu-sharingan.jsonc` + `fastfetch/logos/ubuntu_sharingan_eye.ffraw.txt` |
| `obito-kamui` | 带土神威万花筒写轮眼高密度像素风 | `fastfetch/presets/ubuntu-obito-kamui.jsonc` + `fastfetch/logos/ubuntu_obito_kamui_eye.ffraw.txt` |
| `finger` | 自定义图片字符画 | `fastfetch/logos/ss_finger.ffraw.txt` |
| `plain` | 原生 fastfetch | 无额外资源 |

查看内置 profile：

```bash
ffprofiles
```

## 常用命令

```bash
# 按系统默认主题显示
ff

# 临时切到某个 profile
DOTFILES_FASTFETCH_PROFILE=finger ff
DOTFILES_FASTFETCH_PROFILE=plain ff
DOTFILES_FASTFETCH_PROFILE=obito-kamui ff

# 直接显示 finger 主题
fffinger

# 直接显示带土神威主题
ffobito
```

## `~/.secrets` 覆盖

优先级从高到低：

1. `DOTFILES_FASTFETCH_CONFIG` / `DOTFILES_FASTFETCH_LOGO`
2. `DOTFILES_FASTFETCH_PROFILE`
3. 系统默认分流

### 用 profile 覆盖

```bash
export DOTFILES_FASTFETCH_PROFILE="finger"
```

### 用指定 preset 覆盖

```bash
export DOTFILES_FASTFETCH_CONFIG="$HOME/.config/fastfetch/presets/ubuntu-sharingan.jsonc"
```

### 用 preset + logo 一起覆盖

```bash
export DOTFILES_FASTFETCH_CONFIG="$HOME/.config/fastfetch/presets/ubuntu-sharingan.jsonc"
export DOTFILES_FASTFETCH_LOGO="$HOME/.config/fastfetch/logos/ss_finger.ffraw.txt"
export DOTFILES_FASTFETCH_LOGO_TYPE="file-raw"
export DOTFILES_FASTFETCH_LOGO_PADDING_RIGHT="2"
```

## 同步关系

- 仓库资源放在 `fastfetch/`
- `setup.sh` 会把这些内容链接到：
  - `~/.config/fastfetch/config.jsonc`
  - `~/.config/fastfetch/logos`
  - `~/.config/fastfetch/presets`

## 维护约定

- 新增或修改 fastfetch preset/logo/覆盖逻辑后，同步更新本文件
- 如果改了 profile 名称，也要同步更新 `shell/.shared_rc`
