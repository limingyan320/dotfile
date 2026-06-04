#!/usr/bin/env python3
"""
iclip_daemon.py — iTerm2 AutoLaunch 守护进程

按 Cmd+Shift+V 时:
  1. 解析【当前活动 session】最终连到的远端 ssh 别名
     (穿过本地 tmux 找 active pane,只认 ssh 命令行里的 alias —— 见 resolve_host.sh)
  2. 抓 Mac 剪贴板里的图片 → 临时 PNG(grab_clipboard.sh)
  3. scp 推到 远端 ~/.cache/iclip/(push_image.sh,鉴权全走 SSH 自己的 authorized_keys)
  4. 把远端绝对路径以 bracketed paste 注入当前 session
     → claude 当文件读图 / codex 变 [Image] 附件

无图 / 未连远端 / 传输失败 → 弹 macOS 通知,绝不往输入框乱注入。
日志:~/Library/Logs/iclip-daemon.log(调试看这里)。
触发键想改的话改下面 KEYCODE / REQUIRED。
"""

import asyncio
import logging
import os
import subprocess
import traceback

import iterm2

HERE = os.path.dirname(os.path.realpath(__file__))
GRAB = os.path.join(HERE, "grab_clipboard.sh")
PUSH = os.path.join(HERE, "push_image.sh")
RESOLVE = os.path.join(HERE, "resolve_host.sh")

# 日志(出问题可直接 tail)
_LOGDIR = os.path.expanduser("~/Library/Logs")
try:
    os.makedirs(_LOGDIR, exist_ok=True)
    LOGFILE = os.path.join(_LOGDIR, "iclip-daemon.log")
except OSError:
    LOGFILE = os.path.expanduser("~/iclip-daemon.log")
logging.basicConfig(
    filename=LOGFILE, level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("iclip")

# 触发键:Cmd+Shift+V(本机若把 左Cmd↔左Opt 对调,Command/Option 任一 + Shift + V 都认,见 _match)
KEYCODE = iterm2.Keycode.ANSI_V
# ICLIP_DEBUG=1 时,把每次按键的 keycode/修饰键记进日志(仅调试触发键用;默认关,且不记字符内容)
DEBUG = os.environ.get("ICLIP_DEBUG") == "1"


async def _run(cmd):
    """在线程池里跑子进程,不阻塞事件循环。"""
    loop = asyncio.get_event_loop()
    return await loop.run_in_executor(
        None, lambda: subprocess.run(cmd, capture_output=True, text=True)
    )


def _notify(msg):
    """弹 macOS 通知(不污染输入框)。"""
    try:
        subprocess.Popen(
            ["osascript", "-e", "on run a",
             "-e", 'display notification (item 1 of a) with title "iclip 贴图"',
             "-e", "end run", msg],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except OSError:
        pass


def _match(ks):
    # 注意:本机 Karabiner 把 左Cmd ↔ 左Option 全局对调,iTerm2 收到的"Cmd"可能是 COMMAND
    # 也可能是 OPTION,所以两者任一 + SHIFT + V 都算触发(Ctrl+Shift+V 不算)。
    if ks.keycode != KEYCODE:
        return False
    mods = set(ks.modifiers)
    if iterm2.Modifier.SHIFT not in mods:
        return False
    if iterm2.Modifier.CONTROL in mods:
        return False
    return (iterm2.Modifier.COMMAND in mods) or (iterm2.Modifier.OPTION in mods)


async def _handle(session):
    if session is None:
        _notify("拿不到当前 session")
        return
    tty = await session.async_get_variable("tty")
    log.info("hotkey: tty=%s", tty)
    host = (await _run([RESOLVE, tty or ""])).stdout.strip()
    if not host:
        log.info("no remote host resolved for tty=%s", tty)
        _notify("当前不是远端 ssh 会话(本地窗格/多跳?),已跳过")
        return
    img = (await _run([GRAB])).stdout.strip()
    if not img:
        log.info("no image in clipboard")
        _notify("剪贴板里没有图片")
        return
    res = await _run([PUSH, host, img])
    remote = res.stdout.strip()
    if res.returncode != 0 or not remote:
        tail = (res.stderr or "").strip().splitlines()
        log.error("push failed host=%s rc=%s err=%s", host, res.returncode, res.stderr)
        _notify("传到 %s 失败: %s" % (host, tail[-1] if tail else "?"))
        return
    log.info("inject host=%s remote=%s", host, remote)
    await session.async_send_text("\x1b[200~" + remote + "\x1b[201~")
    try:
        os.remove(img)
    except OSError:
        pass


async def main(connection):
    log.info("iclip daemon starting")
    app = await iterm2.async_get_app(connection)

    # 对调后那一下可能以 Command 也可能以 Option 出现 → 两种 pattern 都吞,避免漏掉默认行为
    def _pat(mod):
        p = iterm2.KeystrokePattern()
        p.keycodes = [KEYCODE]
        p.required_modifiers = [mod, iterm2.Modifier.SHIFT]
        p.forbidden_modifiers = [iterm2.Modifier.CONTROL]
        return p
    patterns = [_pat(iterm2.Modifier.COMMAND), _pat(iterm2.Modifier.OPTION)]

    # 持续吞掉触发键的默认处理,避免同时触发 iTerm2 默认行为
    async def swallow():
        try:
            async with iterm2.KeystrokeFilter(connection, patterns):
                await asyncio.Future()
        except Exception:
            log.error("swallow task crashed:\n%s", traceback.format_exc())

    asyncio.create_task(swallow())

    async with iterm2.KeystrokeMonitor(connection) as mon:
        log.info("keystroke monitor active (Cmd+Shift+V)")
        while True:
            ks = await mon.async_get()
            if DEBUG:
                log.info("key keycode=%s mods=%s",
                         getattr(ks.keycode, "name", ks.keycode),
                         [getattr(m, "name", m) for m in ks.modifiers])
            if not _match(ks):
                continue
            try:
                win = app.current_terminal_window
                session = win.current_tab.current_session if (win and win.current_tab) else None
                await _handle(session)
            except Exception:
                log.error("handle crashed:\n%s", traceback.format_exc())
                _notify("内部错误,详见 ~/Library/Logs/iclip-daemon.log")


iterm2.run_forever(main)
