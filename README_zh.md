# local-qwen

在 Windows 上用 llama.cpp CUDA 后端本地部署 Qwen MoE 模型，提供 OpenAI 兼容 API。包含 PowerShell 管理脚本、预调优 profile、VRAM 估算，以及 LAN/WSL 访问模式。

[English README](README.md)

---

## 功能

- **OpenAI 兼容 API** — 只需改 `base_url`，任何支持 OpenAI SDK 的客户端直接用
- **PowerShell 管理器** (`qwen.ps1`) — start / stop / restart / status / health / 参数预览
- **预调优 profile** — `balanced`、`safe`、`longctx`、`conserve`、`vision`
- **VRAM 估算** — 启动前预测 VRAM 占用，OOM 风险高时给出警告
- **多模态支持** — `vision` profile 支持图像输入
- **LAN / WSL 访问** — 绑定到 `0.0.0.0` 并自动生成 API key 鉴权
- **完全本地运行** — 对话内容不出机器

---

## 硬件要求

| 组件 | 最低 | 测试机 |
|---|---|---|
| 操作系统 | Windows 10/11 x64 | Windows 11 Pro 26200 |
| GPU | NVIDIA，8 GB+ VRAM | RTX 3080 10 GB |
| 系统内存 | 32 GB | 64 GB DDR |
| PowerShell | 7.0+ | 7.6.2 |
| NVIDIA 驱动 | 520+ | 595.97 |

> **注意：** Q4_K_M 量化（22.1 GB 模型）推荐 64 GB 内存。32 GB 内存建议改用 UD-IQ4_XS（17.7 GB），见[模型变体](#模型变体)。

---

## 快速上手

### 1. 安装 llama.cpp（CUDA 版）

从 [llama.cpp GitHub Releases](https://github.com/ggml-org/llama.cpp/releases) 下载以下两个压缩包，解压到 `bin\`：

```powershell
$ver = 'b9294'   # 或最新版本号
$base = "https://github.com/ggml-org/llama.cpp/releases/download/$ver"
New-Item -ItemType Directory -Force bin, dl | Out-Null
Invoke-WebRequest "$base/llama-$ver-bin-win-cuda-12.4-x64.zip" -OutFile "dl\llama-$ver-cuda.zip"
Invoke-WebRequest "$base/cudart-llama-bin-win-cuda-12.4-x64.zip" -OutFile "dl\cudart-$ver.zip"
Expand-Archive "dl\llama-$ver-cuda.zip" bin -Force
Expand-Archive "dl\cudart-$ver.zip"    bin -Force
```

> **为什么不用 `winget install ggml.llamacpp`？** winget 装的是 Vulkan 后端，在 RTX GPU 上比 CUDA 慢 1.5–2 倍。详见 [HANDBOOK.md §2.1](HANDBOOK.md#21-why-cuda-124-and-not-the-winget-vulkan-build)。

### 2. 克隆本仓库

```powershell
git clone https://github.com/zhcqiu/local-qwen.git
cd local-qwen
```

### 3. 配置 `qwen` 别名

在 PowerShell profile（`$PROFILE`）中加入：

```powershell
Set-Alias qwen '<仓库绝对路径>\scripts\qwen.ps1'
```

重新加载 profile：`. $PROFILE`

### 4. 启动服务

```powershell
qwen start
```

首次启动时 llama.cpp 会从 HuggingFace 下载模型（约 22 GB）。后续启动从本地缓存加载。

> **HuggingFace 访问慢？** 启动前设置镜像地址：
> ```powershell
> $env:HF_ENDPOINT = 'https://hf-mirror.com'
> qwen start
> ```
> 永久生效：在 PowerShell profile 的 alias 行之前加入上面这行 `$env:HF_ENDPOINT`。

```
Endpoint: http://127.0.0.1:8080/v1  (仅本机)
```

### 5. 测试

```powershell
qwen health
```

```python
from openai import OpenAI

client = OpenAI(base_url='http://127.0.0.1:8080/v1', api_key='dummy')
resp = client.chat.completions.create(
    model='qwen3.6-35b-a3b',
    messages=[{'role': 'user', 'content': '你好'}],
    extra_body={'chat_template_kwargs': {'enable_thinking': False}},
    max_tokens=512,
)
print(resp.choices[0].message.content)
```

---

## 性能基准

硬件：**i7-13700KF / 64 GB / RTX 3080 10 GB**，llama.cpp b9294 CUDA 12.4。

| 指标 | 数值 |
|---|---|
| 生成速度 | ~40 tok/s |
| Prompt 评估速度 | ~415 tok/s（7k token prompt） |
| 上下文窗口 | 24576 tokens |
| VRAM idle | 9834 / 10240 MiB |
| VRAM peak（7k prompt） | 9854 / 10240 MiB |

完整 sweep 数据与分析：[TUNING-REPORT_zh.md](TUNING-REPORT_zh.md)

---

## 不同 GPU 的参数建议

核心参数是 `--n-cpu-moe N`：编号 ≤ N 的 expert 层留在 CPU 内存，> N 的放 GPU。N 越小 = GPU 承担越多 = 生成越快，但 VRAM 占用越高。

模型有 40 层，每层 256 个 expert，每次激活 top-8。每把 1 层 expert 移到 GPU 大约多用 ~475 MiB VRAM。

| GPU | `--n-cpu-moe` | ctx | 说明 |
|---|---|---|---|
| RTX 3080 10 GB | 29 | 24576 | 测试机；VRAM 余量约 386 MiB |
| RTX 4070 Ti 12 GB | ~23 | 32768 | 估算；多约 5 层 expert 可上 GPU |
| RTX 4090 / RTX 5090 24 GB+ | 0 | 65536+ | 所有 expert 上 GPU，无 CPU 瓶颈 |
| RTX 3060 12 GB | ~24 | 16384 | VRAM 多但带宽窄 |
| RTX 3070 / 4060 Ti 8 GB | 32–33 | 16384 | VRAM 紧，保守起步 |

**建议用 `scripts/bench-config.ps1` 跑一遍 sweep 找到适合你硬件的最优点。** 上面的值只是起点估算，详见 [HANDBOOK_zh.md §6.2](HANDBOOK_zh.md)。

**CPU 线程：** 如果使用 Intel 混合架构（P+E core），设置 `-t <P-core 数> -tb <P-core 数>`，避开 E-core 对 MoE 计算的干扰。

---

## 模型变体

所有变体均来自 [unsloth/Qwen3.6-35B-A3B-GGUF](https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF)：

| 变体 | 大小 | 质量 | 适用场景 |
|---|---|---|---|
| UD-Q4_K_M | 22.1 GB | 良好 | 默认，64 GB 内存的甜点 |
| UD-IQ4_XS | 17.7 GB | 可接受 | 32 GB 内存或需要更长上下文 |
| UD-Q5_K_M | 26.5 GB | 更好 | 128 GB 内存 / 24 GB+ GPU |
| UD-Q6_K | 29.3 GB | 最好 | 128 GB 内存 / 24 GB+ GPU |

切换变体：修改 `scripts/qwen.ps1` 顶部的 `$ModelHf` 变量。

---

## 切换到新版模型

当新版 Qwen 模型发布时，更新 `scripts/qwen.ps1` 顶部的两个变量：

```powershell
$ModelHf    = 'unsloth/Qwen3.7-XXX-GGUF:UD-Q4_K_M'
$ModelAlias = 'qwen3.7-xxx'
```

然后重新跑一遍 sweep，因为架构变化（层数、expert 数等）会影响 `--n-cpu-moe` 的最优点。

---

## Qwen3 Thinking 模式

Qwen3 模型默认启用 extended thinking：先把推理过程写入 `message.reasoning_content`，再写最终答案到 `message.content`。如果返回内容为空，通常就是这个原因。

| 场景 | 解决方式 |
|---|---|
| 需要简短快速的回答 | 请求中加 `chat_template_kwargs: {enable_thinking: false}` |
| 需要复杂推理（数学、调试） | 保持默认，设 `max_tokens >= 1024` 留出 thinking 预算 |
| 客户端不支持 `reasoning_content` | 启动时加 `--reasoning-format none`（把 thinking 合并进 content） |

---

## LAN / WSL 访问

```powershell
qwen start -Lan -Background
```

绑定到 `0.0.0.0:8080`，自动生成 API key（存储到 `.apikey`），并尝试创建 Windows 防火墙规则。客户端使用 `Authorization: Bearer <key>` 鉴权。

完整步骤见 [HANDBOOK_zh.md §9.6](HANDBOOK_zh.md)。

---

## IDE / 工具接入

任何支持 OpenAI 兼容 API 的工具都可以直接用：

| 工具 | 配置 |
|---|---|
| [Continue](https://continue.dev) | `apiBase: http://127.0.0.1:8080/v1` |
| [Cline](https://github.com/cline/cline) | OpenAI 兼容模式，base URL 填 `http://127.0.0.1:8080/v1` |
| [Aider](https://aider.chat) | `--openai-api-base http://127.0.0.1:8080/v1` |
| OpenAI Python SDK | `OpenAI(base_url='http://127.0.0.1:8080/v1', api_key='dummy')` |

---

## 文档

| 文档 | 内容 |
|---|---|
| [HANDBOOK.md](HANDBOOK.md) | 完整维护手册（英文）— 决策记录、VRAM 预算、调参 Playbook、故障排查、集成示例 |
| [TUNING-REPORT.md](TUNING-REPORT.md) | 完整参数 Sweep 结果与分析（英文） |
| [HANDBOOK_zh.md](HANDBOOK_zh.md) | 完整维护手册（中文） |
| [TUNING-REPORT_zh.md](TUNING-REPORT_zh.md) | 参数 Sweep 调优报告（中文） |

---

## License

MIT — 见 [LICENSE](LICENSE)。
