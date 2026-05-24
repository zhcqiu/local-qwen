# Qwen3.6-35B-A3B 本地部署 — 完成报告

**日期**: 2026-05-23
**主机**: i7-13700KF / 64GB DDR / RTX 3080 10GB / Win11 26200

## 1. 状态
✅ **成功**。Server 已启动并通过中文 chat completion 验证。

## 2. 关键决策（偏离原始 prompt 的部分）
| 项 | 原始 prompt | 实际选择 | 理由 |
| --- | --- | --- | --- |
| 后端 | winget Vulkan | **GitHub Release CUDA 12.4** | RTX 3080 (sm_86) CUDA 内核比 Vulkan 快 1.5–2x；ggml-cuda.dll 538 MB |
| KV cache | q4_0 / q4_0 | **q8_0 / q8_0** | 长上下文质量损失明显小，VRAM 充裕 |
| MoE offload | `--n-cpu-moe 38` | **`--cpu-moe`**（全部 expert → CPU） | 起点更安全；后续可逐步把 expert 拉回 GPU |
| 线程绑定 | 默认 | **`-t 8 -tb 8`** | 13700KF 只用 8 个 P-core，E-core 影响 MoE 数值精度 |
| 模板 | 未指定 | **`--jinja`** | 启用 Qwen 原生 chat template |

## 3. 最终启动命令
```powershell
& "<repo-root>\bin\llama-server.exe" `
  -hf "unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_M" `
  --alias "qwen3.6-35b-a3b" `
  --host 127.0.0.1 --port 8080 `
  -c 8192 `
  -ngl 999 --cpu-moe `
  --flash-attn auto `
  --cache-type-k q8_0 --cache-type-v q8_0 `
  -t 8 -tb 8 `
  --jinja --parallel 1
```
可复现脚本: `<repo-root>\scripts\run-qwen36-35b-a3b.ps1`

## 4. 版本与后端
- llama.cpp **b9294** (Clang 19.1.5, Windows x86_64)
- 后端: **CUDA 12.4** (`ggml-cuda.dll`)
- ARCHS: 500, 610, 700, 750, 800, **860**, 890, 900 → 包含 RTX 3080 的 sm_86
- 模型: `unsloth/Qwen3.6-35B-A3B-GGUF :: UD-Q4_K_M` (22.1 GB)

## 5. GPU 使用确认
- `CUDA0 : NVIDIA GeForce RTX 3080 (10239 MiB, 9095 MiB free)` — 模型加载后 GPU 已绑定
- 推理期间 GPU util 峰值 40%（受 CPU MoE 路径限制，正常）
- GPU 温度峰值 50°C

## 6. 性能数据
| 指标 | 数值 |
| --- | --- |
| **Generation tok/s** | **25.40 – 25.73** |
| Prompt eval tok/s | 37.38 |
| 首 token 延迟 (28 prompt tokens) | ~0.75 s |
| Context size | 8192 (模型 native 262144) |
| 首次启动耗时 (含 22GB 下载) | 157 s |

> ✅ 远超原始判断标准的「可接受 ≥ 5 tok/s」，达到「成功」档位。

## 7. 内存峰值
| 资源 | 峰值 | 总量 | 余量 |
| --- | --- | --- | --- |
| **VRAM** | **6191 MiB** | 10240 MiB | 4049 MiB |
| **System RAM** | **55947 MB** | 63848 MB | ~7.9 GB |

⚠️ **RAM 边际**: 系统 RAM 用到 87.6%，主要因为 22GB 模型 + 大量桌面应用。如果再开重型应用可能触发 swap。

## 8. 路径
| 项 | 路径 |
| --- | --- |
| 工作根目录 | `<repo-root>\` |
| 二进制 | `<repo-root>\bin\llama-server.exe` |
| 模型缓存 | `<repo-root>\models\models--unsloth--Qwen3.6-35B-A3B-GGUF\blobs\` |
| 启动脚本 | `<repo-root>\scripts\run-qwen36-35b-a3b.ps1` |
| 健康检查 | `<repo-root>\scripts\healthcheck.ps1` |
| 性能监控 | `<repo-root>\scripts\perf-monitor.ps1` |
| 日志 | `<repo-root>\logs\` |

## 9. 异常
- 已识别且已处理: 第一次 health check `max_tokens=256` 时被 Qwen 的 thinking 模式占满，全部成为 `reasoning_content`、`content` 为空。需求方需注意：
  - **方案 A**: 设置 `max_tokens >= 1024` 留出 thinking 预算
  - **方案 B**: 请求体加 `"chat_template_kwargs": {"enable_thinking": false}` 关闭 thinking（实测 3.9s 内出完三句话）
- 启动时已清理 Ollama 进程（PID 17900 + 48792），释放 ~420 MB RAM。其它桌面应用未动。

## 10. 后续可调优方向
1. **Context 8192 → 16384**：q8_0 KV 下每翻倍约多用 700 MB VRAM，当前余量 4 GB，可以放心抬到 16384，必要时直接 32768。
2. **`--cpu-moe` → `--n-cpu-moe N`**：当前所有 expert 在 CPU。VRAM 还剩 4 GB，可以尝试 `--n-cpu-moe 50`（保留约 12 层 expert 在 GPU），generation 可能再涨 2–5 tok/s。需配合 nvidia-smi 实时盯 VRAM。
3. **接入本地 Agent**：endpoint `http://127.0.0.1:8080/v1`，OpenAI 兼容，可以直接接入：
   - Claude Code 的 `ANTHROPIC_BASE_URL` 兼容方案
   - OpenAI Python SDK：`OpenAI(base_url='http://127.0.0.1:8080/v1', api_key='not-needed')`
   - Continue / Aider / Cline 等 IDE 插件

## 11. 已知限制
- Windows 上 `--mlock` 默认 enabled 但需要 SeLockMemoryPrivilege，若没配则降级到普通 mmap（不影响功能，可能影响首 token 延迟）。
- 仅监听 127.0.0.1，未开防火墙端口，符合要求。
- 未启用 vision / mmproj / speculative decoding。
