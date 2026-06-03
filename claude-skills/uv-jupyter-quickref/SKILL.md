---
name: uv-jupyter-quickref
description: Quick reference for this machine's uv-managed Jupyter setup. Use when the user asks about local JupyterLab, uv tool installation, Jupytext pairing, Neovim-friendly notebook workflows, ipykernel registration, notebook kernels, or how to sync .py files to browser notebooks in ~/notes/python.
---

# UV Jupyter 速查

本机原则：`JupyterLab` 作为全局工具由 `uv tool` 管，具体项目的 Python 依赖和 kernel 由项目 `.venv` 管。不要把 notebook 工作流需要的库混装进 JupyterLab tool 环境。

## 当前事实

- 工作目录：`/Users/lumynous/notes/python`
- JupyterLab：`4.5.7`
- JupyterLab 命令：`/Users/lumynous/.local/bin/jupyter-lab`
- JupyterLab tool 环境：`/Users/lumynous/.local/share/uv/tools/jupyterlab`
- Jupytext：`1.19.3`
- Jupytext 命令：`/Users/lumynous/.local/bin/jupytext`
- 当前项目 Python：`uv run python`，Python `3.13.11`
- 当前项目 dev 依赖包含：`ipython>=9.13.0`, `ipykernel>=7.2.0`
- 当前常用 kernel 名：`notes`
- 现有 kernels：`python3`, `asr`, `notes`, `receipt`

检查命令：

```bash
uv tool list --show-paths
jupyter-lab --version
jupytext --version
/Users/lumynous/.local/share/uv/tools/jupyterlab/bin/python -m jupyter server extension list
/Users/lumynous/.local/share/uv/tools/jupyterlab/bin/python -m jupyter kernelspec list
uv run python -V
```

## 安装与更新

安装或重装 JupyterLab 时优先固定版本，并带上 `jupytext`：

```bash
uv tool install 'jupyterlab==4.5.7' --with jupytext --force --system-certs
```

本机曾遇到不加 `--system-certs` 时 PyPI/TUNA TLS 握手中断；后续安装 Jupyter 相关 tool 时默认加 `--system-certs`。

单独安装全局 `jupytext` 命令：

```bash
uv tool install jupytext --system-certs
```

不要用：

```bash
uv tool upgrade jupyterlab --with jupytext
```

当前 `uv` 的 `tool upgrade` 不接受 `--with`。`--with` 可用于 `uv tool install` 或 `uv tool run`。

## 启动 JupyterLab

在项目目录启动，确保 Jupyter 能读到项目 `pyproject.toml` 里的 Jupytext 配置：

```bash
cd /Users/lumynous/notes/python
jupyter-lab
```

如果需要用 tool 环境里的 Python 调 Jupyter 子命令：

```bash
/Users/lumynous/.local/share/uv/tools/jupyterlab/bin/python -m jupyter <subcommand>
```

## 项目配置

`/Users/lumynous/notes/python/pyproject.toml` 应保留：

```toml
[dependency-groups]
dev = [
    "ipykernel>=7.2.0",
    "ipython>=9.13.0",
]

[tool.jupytext]
formats = "ipynb,py:percent"
```

`py:percent` 使用 `# %%` 作为 cell marker，适合 Neovim 编辑，也兼容 VS Code/PyCharm 风格。

## Jupytext 工作流

长期推荐主线：

```text
Neovim 编辑 .py
Jupytext 同步 .py <-> .ipynb
JupyterLab 浏览器运行、看图、保存 rich output
```

`.py` cell 示例：

```python
# %%
import numpy as np

# %%
x = np.arange(10)
x
```

将已有 notebook 配对成 `.py`：

```bash
jupytext --set-formats ipynb,py:percent draft.ipynb
```

从 `.py` 新建配对 notebook：

```bash
jupytext --set-formats ipynb,py:percent experiment.py
```

日常同步：

```bash
jupytext --sync draft.py
```

同步规则：Jupytext 用最近修改的配对文件作为输入；输入 cell 从较新的 `.py` 或 `.ipynb` 来，输出一般保留在 `.ipynb`。如果浏览器已经打开 `.ipynb`，同步后刷新或重新打开 notebook。

查看配对目标：

```bash
jupytext --paired-paths draft.ipynb
jupytext --paired-paths draft.py
```

## Kernel

JupyterLab tool 环境只负责 UI/server；项目 kernel 应来自项目 `.venv`。

在项目里安装/确认 kernel 依赖：

```bash
cd /Users/lumynous/notes/python
uv add --dev ipykernel ipython
```

注册当前项目 kernel：

```bash
uv run python -m ipykernel install --user --name notes --display-name notes
```

查看 kernel：

```bash
/Users/lumynous/.local/share/uv/tools/jupyterlab/bin/python -m jupyter kernelspec list
```

Notebook metadata 中常见 kernel：

```json
{
  "display_name": "notes",
  "language": "python",
  "name": "notes"
}
```

## 验证

确认 Jupytext 扩展启用：

```bash
/Users/lumynous/.local/share/uv/tools/jupyterlab/bin/python -m jupyter server extension list | rg 'jupyterlab_jupytext|OK'
```

确认命令入口：

```bash
command -v jupyter-lab
command -v jupytext
```

确认配对 metadata：

```bash
python - <<'PY'
import json
from pathlib import Path
path = Path("draft.ipynb")
data = json.loads(path.read_text())
print(json.dumps(data.get("metadata", {}).get("jupytext", {}), indent=2))
print(json.dumps(data.get("metadata", {}).get("kernelspec", {}), indent=2))
PY
```

## 常见判断

- 想统一浏览器 cell 内编辑手感：考虑 `jupyterlab-vim`，但这是浏览器编辑体验，不是当前主线。
- 想长期保存、进 Git、用 Neovim 编辑：用 `Jupytext + .py:percent`。
- 只是快速交互 Python：`ipython` CLI 更简单。
- 需要图片和 rich output：让 JupyterLab 浏览器负责渲染；不要优先折腾 Neovim 内联图片插件。
- 如果 `jupyter` 或 `jupytext` 命令找不到，先区分是 `uv tool` 没暴露 executable，还是 tool 环境里 Python 可用。可用 tool 环境 Python 调模块。

## 维护

这个 skill 的 Codex 版在：

```text
~/.dotfiles/codex-skills/uv-jupyter-quickref/SKILL.md
```

Claude 版在：

```text
~/.dotfiles/claude-skills/uv-jupyter-quickref/SKILL.md
```

更新本机 Jupyter/Jupytext/kernel 事实后，同步更新两份文件。
