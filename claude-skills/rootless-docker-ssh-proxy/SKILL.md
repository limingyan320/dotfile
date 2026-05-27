---
name: rootless-docker-ssh-proxy
description: Use when rootless Docker on this machine cannot reach the internet — especially the classic trap where `docker pull` succeeds but `docker build` RUN steps (apt-get / pip) fail with 404 or timeouts. Covers the SSH-reverse-forwarded proxy bridge pattern and, above all, the daemon-vs-client proxy divergence that breaks builds. Records this host's known-good proxy values. The full from-scratch bridge setup lives in the parallel codex-skills/rootless-docker-ssh-proxy.
---

# Rootless Docker + SSH 反向代理

这台机器只能经**另一台机器的代理**上网，代理通过 SSH 反向隧道暴露在本机 loopback：

```
127.0.0.1:<UPSTREAM_PORT>（SSH 反向隧道）→ 上游代理（另一台机器）
```

rootless docker 的容器/BuildKit **够不到宿主的 `127.0.0.1`**，所以要建一个"容器可达 IP 上的桥"转发到 loopback 上游：

```
<HOST_IP>:<BRIDGE_PORT>  ──socat/python转发──►  127.0.0.1:<UPSTREAM_PORT>
```

## 这台机器的已知可用值（2026-05-27 实测，变了要更新）

| 角色 | 值 | 说明 |
|---|---|---|
| `HOST_IP` | `192.168.100.6`（ens20f0） | 容器/BuildKit 可达的本机 IP；**不是** 127.0.0.1 |
| `BRIDGE_PORT` | `32001` | 桥：`192.168.100.6:32001`，daemon 与 build 都该用它 |
| `UPSTREAM_PORT` | `32000` | SSH 反向隧道上游：`127.0.0.1:32000` |
| ⚠️ 坏代理 | `192.168.100.100:8080` | 局域网 HTTP 代理（带 basic-auth）。**对 ubuntu 源 404、只放行 NVIDIA `.cn`**，别用 |

桥/上游的转发服务与 daemon 代理通常已配好（详见 codex-skills 同名 skill 的「Create A Proxy Bridge / Configure Docker」）。本 skill 重点是**诊断**与那个最坑的分叉问题。

## 心智模型：两条互相独立的代理路径

| 动作 | 代理来自 | 配置位置 |
|---|---|---|
| `docker pull` / daemon 自身联网 | **daemon 代理** | `~/.config/systemd/user/docker.service.d/http-proxy.conf` 的 `Environment=HTTP(S)_PROXY` |
| `docker build` 里每个 `RUN`（apt-get / pip 等） | **client 注入的 build-arg** | `~/.docker/config.json` 的 `proxies.default` → docker CLI 自动注入 `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` 到构建 |

**两者各管各的、可以指向不同地址。** 这是下面这个坑的根源。

## 典型症状 → 根因（2026-05-27 本次踩的坑）

**症状**：基础镜像 `docker pull` 正常，但 `docker build` 卡在第一条 `RUN apt-get update`：

```
Err:6 http://archive.ubuntu.com/ubuntu jammy Release
  404  Not Found [IP: 192.168.100.100 8080]      ← 注意这个 IP，是坏代理
E: The repository '... jammy Release' does not have a Release file.
```

**根因**：daemon 代理早已指向能用的桥 `192.168.100.6:32001`（所以 pull 成功），但 client `~/.docker/config.json` 的 `proxies.default` 还停留在坏代理 `192.168.100.100:8080`，于是被注入进 build 的每个 `RUN`，apt 经坏代理拿 ubuntu 源 → 404。

**判别口诀**：`pull 成功 + build 的 apt/pip 失败` ≈ daemon 与 client 两条代理分叉了。报错里那个 `[IP: x.x.x.x port]` 就是 build 实际用的代理，拿它和 daemon 的代理对比。

## 诊断（按顺序）

```bash
# 1. daemon 用的什么代理（管 pull）
docker info | grep -i 'proxy\|rootless\|context'

# 2. client 注入 build 的什么代理（管 RUN）—— 重点看这里
cat ~/.docker/config.json          # 看 proxies.default.httpProxy / httpsProxy

# 3. 桥与上游是否在听
ss -ltn | grep -E ':32000|:32001'

# 4. 经桥能否到达「构建真正要访问的」公网目标（不要只测 docker registry）
curl -sI --max-time 10 --proxy http://192.168.100.6:32001 http://archive.ubuntu.com/ubuntu/dists/jammy/InRelease | head -1   # 期望 200 OK
curl -sI --max-time 10 --proxy http://192.168.100.6:32001 https://pypi.org/simple/ | head -1                                 # 期望 200
```

## 修复

让 client 的 build 代理和 daemon 对齐到桥。改 `~/.docker/config.json`（**先备份**）：

```jsonc
{
  "auths": {},
  "currentContext": "rootless",
  "proxies": {
    "default": {
      "httpProxy":  "http://192.168.100.6:32001",
      "httpsProxy": "http://192.168.100.6:32001",
      "noProxy":    "192.168.100.0/24,127.0.0.0/8"
    }
  }
}
```

- 改完**无需重启 daemon**：`proxies.default` 是 client 侧、每次 `docker build` 即时读取并注入。
- BuildKit（`DOCKER_BUILDKIT=1`）同样吃这套自动注入，不必在 Dockerfile 里声明 `ARG HTTP_PROXY`。
- `noProxy` 写本地网段即可；apt/pip 的公网目标不在其中，会正常走代理。

## 验证修好了

```bash
python3 -m json.tool ~/.docker/config.json >/dev/null && echo JSON_OK
# 直接重跑原构建命令；日志里 apt 应从 200 拉到 InRelease，torch 那类自带包出现 "Requirement already satisfied"
```

## 不要换镜像源来绕过

遇到 apt 404 时，换 aliyun/tuna 镜像源能"碰巧"绕过，但那是掩盖问题：根因是代理分叉，换源后下次别的域名照样炸。**首选修代理（本 skill），而不是 sed 改 sources.list。**

## Pitfalls

- 别把 build/容器代理设成 `127.0.0.1:<UPSTREAM_PORT>`——rootless 容器里的 127.0.0.1 是容器自己，必须用桥 `HOST_IP:BRIDGE_PORT`。
- `docker info` 看到的是 **daemon** 代理，**不代表** build 用的代理；build 看 `~/.docker/config.json`。
- 报错 `[IP: a.b.c.d port]` 是诊断金线索——它就是当前生效的代理地址。
- 坏代理 `192.168.100.100:8080` 会让 NVIDIA `.cn` 源能过、ubuntu 源 404，造成"看起来一半能用"的迷惑现象。
- `HOST_IP` / `BRIDGE_PORT` / `UPSTREAM_PORT` 任一变化，daemon drop-in 与 `~/.docker/config.json` 两处都要同步改。
