---
name: voiceprint-ascend910b-deploy
description: Use when migrating, deploying, debugging, or extending the voiceprint-asr service on Huawei Ascend 910B machines, especially Qwen3-ASR self-hosted vLLM/gateway/bridge deployments, adding new ASR models or weights, rebuilding project-owned Ascend images from official bases, validating NPU/GPU memory attribution, proxy behavior, and end-to-end ASR on 910B. Do not use for unrelated generic Docker deployment.
metadata:
  short-description: Deploy voiceprint-asr on Huawei Ascend 910B
---

# Voiceprint Ascend 910B Deploy

## 核心标准

迁移到华为 910B 时，目标不是“在某台机器上借别人的容器跑起来”，而是做到可复现：

- 可以依赖本项目的 Dockerfile、部署脚本、patch、配置和代码。
- 可以依赖官方 Ascend/CANN/vLLM 基础镜像。
- 可以依赖宿主机 Docker、Ascend 驱动/CANN、NPU 设备和模型权重目录。
- 不应依赖其他用户已经 build 好的业务镜像、容器或私有工作目录。
- 只读参考别人镜像可以用于排查兼容点，但最终必须把必要变更沉淀到本项目。

验收标准是：用项目内流程重建 image，创建独立实例，跑通真实音频端到端 ASR，并确认显存归因来自我们自己的后端进程。

## 先读状态

优先只读检查，不要先重启服务或停别人的容器。

```bash
ssh -T -o ClearAllForwardings=yes 910b 'hostname; docker ps --format "{{.Names}} {{.Image}} {{.Status}}" | sed -n "1,120p"'
ssh -T -o ClearAllForwardings=yes 910b 'docker images --format "{{.Repository}}:{{.Tag}} {{.ID}} {{.Size}}" | grep -E "voiceprint|qwen|ascend|vllm" || true'
ssh -T -o ClearAllForwardings=yes 910b 'npu-smi info 2>/dev/null | sed -n "1,180p"'
```

如果 SSH 登录会向 stdout 打印杂质，例如 `sb`，不要用普通 `rsync` 传输项目；用 tar 管道并关闭 forward：

```bash
tar --exclude='__pycache__' --exclude='.pytest_cache' --exclude='*.pyc' -czf - \
  admin_service resources voiceprint_asr asr_gateway deploy/ascend910b pyproject.toml uv.lock README.md |
ssh -T -o ClearAllForwardings=yes 910b 'cd /home/limingyan/voiceprint-asr && tar xzf -'
```

## 代理原则

910B 上 Docker build/run 访问外网时，不要默认把宿主 `127.0.0.1:<port>` 当成容器可访问地址。容器里的 `127.0.0.1` 是容器自身。

在当前 910B 场景验证过的代理是：

```text
http://172.17.0.1:8080
```

正式 build 使用双大小写 build args：

```bash
DOCKER_BUILDKIT=1 docker build \
  --build-arg HTTP_PROXY=http://172.17.0.1:8080 \
  --build-arg HTTPS_PROXY=http://172.17.0.1:8080 \
  --build-arg NO_PROXY=localhost,127.0.0.1,172.17.0.0/16 \
  --build-arg http_proxy=http://172.17.0.1:8080 \
  --build-arg https_proxy=http://172.17.0.1:8080 \
  --build-arg no_proxy=localhost,127.0.0.1,172.17.0.0/16 \
  -f deploy/ascend910b/<Dockerfile> -t <image:tag> .
```

如果代理问题复杂，配合使用 `rootless-docker-ssh-proxy` skill。

## 自有镜像

Qwen3-ASR self-hosted 目标由三类自有镜像组成：

- `voiceprint-qwen3-vllm-ascend:<tag>`：Ascend vLLM 后端，内部端口 `2026`。
- `voiceprint-qwen3-gateway:<tag>`：CPU gateway，负责 VAD/切片，调用 vLLM `/v1/audio/transcriptions`，内部端口 `2100`。
- `voiceprint-admin:ascend910b`：admin，负责创建实例和编排容器。

bridge 镜像可继续使用项目已有的 Ascend bridge 镜像，例如 `voiceprint-asr-ascend-bridge:3.1.1`。它不是 Qwen3-ASR 后端本体，只负责实例入口和转发。

构建 vLLM 镜像：

```bash
ssh -T -o ClearAllForwardings=yes 910b '
cd /home/limingyan/voiceprint-asr &&
DOCKER_BUILDKIT=1 docker build \
  -f deploy/ascend910b/Dockerfile.qwen3-vllm-ascend \
  -t voiceprint-qwen3-vllm-ascend:0.1.0 \
  --build-arg HTTP_PROXY=http://172.17.0.1:8080 \
  --build-arg HTTPS_PROXY=http://172.17.0.1:8080 \
  --build-arg NO_PROXY=localhost,127.0.0.1,172.17.0.0/16 \
  --build-arg http_proxy=http://172.17.0.1:8080 \
  --build-arg https_proxy=http://172.17.0.1:8080 \
  --build-arg no_proxy=localhost,127.0.0.1,172.17.0.0/16 \
  .
'
```

构建 gateway 镜像同理使用 `deploy/ascend910b/Dockerfile.qwen3-gateway`。

## Qwen-ASR 兼容 patch

官方 Ascend vLLM 与 `qwen-asr` 的 Python API 可能不完全匹配。不要直接热改容器内 site-packages；把兼容点写入：

```text
deploy/ascend910b/patch_qwen_asr_vllm_ascend.py
```

已知 vLLM 0.18 兼容点：

- `MMEncoderAttention(..., multimodal_config=...)` 需要 TypeError fallback。
- `get_vit_attn_backend(..., attn_backend_override=...)` 需要 TypeError fallback。
- `_embed_text_input_ids(..., handle_oov_mm_token=...)` 需要 TypeError fallback。

每次新增模型或升级官方 base/qwen-asr 后，都要重新验证启动和真实 `/v1/audio/transcriptions` 请求。只通过 `/v1/models` 不够。

验证镜像内 patch：

```bash
docker run --rm --entrypoint bash voiceprint-qwen3-vllm-ascend:0.1.0 -lc '
p=/usr/local/python3.11.14/lib/python3.11/site-packages/qwen_asr/core/vllm_backend/qwen3_asr.py
grep -n "multimodal_config.*str(exc)" "$p"
grep -n "attn_backend_override.*str(exc)" "$p"
grep -n "handle_oov_mm_token.*str(exc)" "$p"
'
```

## 实例创建规则

实例创建不要在 `config` 里设置 `ASR_ACCELERATOR`；GPU/NPU 使用顶层 `gpu_ids`。

Qwen3 self-hosted 关键字段：

```json
{
  "name": "Qwen3-ASR self-hosted owned image test",
  "gpu_ids": [5],
  "model_version": "Qwen3-ASR-1.7B",
  "config": {
    "ASR_BACKEND": "qwen3_asr",
    "QWEN3_ASCEND_MODE": "self_hosted",
    "QWEN3_VLLM_MAX_NUM_SEQS": "32",
    "QWEN3_VLLM_MAX_MODEL_LEN": "8192",
    "QWEN3_VLLM_GPU_MEMORY_UTILIZATION": "0.3",
    "QWEN3_VLLM_ENFORCE_EAGER": "true",
    "QWEN3_GATEWAY_WORKERS": "2",
    "ENABLE_SORTFORMER_DIAR": "false",
    "ENABLE_CHANNEL_DIAR": "false",
    "ENABLE_PUNC_MODEL": "true",
    "ASR_BATCH_SIZE": "1",
    "ASR_NUM_WORKERS": "1"
  }
}
```

admin 会创建三容器：

```text
voiceprint-qwen-vllm-<id8>
voiceprint-qwen-gateway-<id8>
voiceprint-asr-inst-<id8>
```

只删除目标实例，不要误删别人容器：

```bash
curl -X DELETE -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:3200/admin/api/instances/<instance_id>
```

## 模型和权重

新增模型时先确认模型注册和路径映射，不要只把权重丢到机器上：

- 宿主权重目录应在 admin 配置的 models root 下。
- admin 的模型 registry 能解析 `model_version` 到宿主目录和容器目录。
- vLLM 容器通常把模型挂到 `/model`。
- gateway 的 `ASR_MODEL_NAME` 要与 vLLM `--served-model-name` 一致。
- VAD 模型目录必须能被 gateway 容器读取。

新增模型后至少验证：

```bash
docker exec voiceprint-qwen-gateway-<id8> \
  curl -sS http://voiceprint-qwen-vllm-<id8>:2026/v1/models
```

返回的 model id 必须是期望的 served model name。

## Readiness 和 E2E 验证

不要用 `docker exec voiceprint-qwen-vllm-... python ...` 做 readiness；在 Ascend 镜像里这可能额外触发 `torch`/Triton 初始化并干扰启动。

推荐从 gateway 容器用 curl 检查 vLLM：

```bash
docker exec voiceprint-qwen-gateway-<id8> \
  curl -sS -m 5 http://voiceprint-qwen-vllm-<id8>:2026/v1/models
```

E2E 以 bridge 暴露端口提交真实音频：

```bash
curl -sS -X POST "http://127.0.0.1:<host_port>/internal/tasks/submit" \
  -H "Content-Type: application/json" \
  -d '{"audio_path":"/app/admin_data/models/SenseVoiceSmall/example/zh.mp3","audio_name":"zh.mp3","options":{}}'

curl -sS "http://127.0.0.1:<host_port>/asr/result/<request_id>"
```

合格结果应满足：

- bridge 返回 `status: success`。
- `results` 非空且文本合理。
- gateway 日志有 `POST /asr/sync 200 OK`。
- vLLM 日志有 `POST /v1/audio/transcriptions 200 OK`。
- 没有 `EngineDeadError` 或新的 TypeError 签名错误。

## 显存归因

不要把整卡 HBM 占用当成某个实例的 runtime 占用。

admin 实例里优先看：

```text
gpu_mem_source: backend:npu-smi
per_gpu_mem_mb: {"<gpu_id>": <mb>}
```

含义：

- `backend:npu-smi`：按实例对应的 vLLM 后端进程 PID 归因，可信。
- `bridge:external`：只知道 bridge 或外部服务，不能准确归因后端进程。
- 空或估算：不要对用户声称是准确实例显存。

Qwen3-ASR 1.7B 在 910B 上，低并发配置下常驻约 18GB 属于已观察到的量级；仍需按当前模型、max len、memory utilization 和并发重新验证。

## 新模型适配流程

1. 只读确认机器状态、NPU 空闲度、模型权重目录、现有镜像和代理。
2. 在项目里新增或确认模型 registry、默认 env、compose/env.example、README 说明。
3. 如果新模型需要不同官方 base 或不同启动命令，新增独立 Dockerfile/tag，不要覆盖旧模型可用镜像。
4. 构建自有 vLLM/gateway 镜像；不要依赖其他用户 image。
5. 用镜像内 grep 或短命令确认 patch 和依赖存在。
6. 创建测试实例，等待 vLLM `/v1/models`。
7. 用真实音频跑 `/internal/tasks/submit` 到 `/asr/result`。
8. 记录实例 ID、端口、GPU、镜像 ID、显存归因、识别结果和测试命令。
9. 失败时优先把兼容修复沉淀到项目 Dockerfile/patch，再重建镜像；不要只在容器内热修。

## 常见故障

- `ASR_ACCELERATOR 不允许在实例创建中设置`：删除 config 里的该字段，改用顶层 `gpu_ids`。
- `/v1/models` 可用但 ASR 请求 500：继续看 vLLM `/v1/audio/transcriptions` 栈，常见是 qwen-asr 与 vLLM 签名不兼容。
- `EngineDeadError`：上翻日志找第一个 TypeError 或 NPU runtime error，根因通常在 EngineCore 之前。
- 显存显示像 35GB：先判断是不是整卡 HBM，只有 `backend:npu-smi` 才能当成实例后端归因。
- `rsync` 失败或协议异常：检查 SSH 登录是否向 stdout 打印内容；改用 tar 管道。
- Docker build 卡下载：先验证宿主、bridge 容器、BuildKit RUN 阶段是否都能访问代理。

## 收尾要求

完成迁移或新增模型后，最终说明必须包含：

- 是否重启过全局服务；如果没有，明确说明只做了实例级创建/删除。
- 自有镜像 tag 和 image id。
- 新实例 ID、端口、GPU、三容器名。
- E2E request id 和识别文本。
- 显存来源和归因值。
- 本地或远端测试结果。
- 哪些旧容器或外部服务没有动。
