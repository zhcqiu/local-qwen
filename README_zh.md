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

## 帮助系统

只需要记三种：

```powershell
qwen -h                     # 概览（actions、topics、常用命令）
qwen <action> -h            # 单个 action 的专属帮助 — 例如 qwen start -h
qwen help <topic>           # 跨 action 的主题页
```

`-h` / `--help` / `-Help` / `-?` 均可接受。每个 action（`start`、`stop`、`restart`、`status`、`health`、`config`、`validate`）都有自己的页面，只列该 action 相关的 flags + 2–4 个示例。主题页覆盖跨 action 的概念：`models`、`profiles`、`lan`、`examples`、`lang`、`actions`、`all`。

默认英文。要永久切到中文，在 `$PROFILE` 加：

```powershell
$env:QWEN_HELP_LANG = 'zh'
```

单次覆盖：在任意 help 命令后加 `-Zh`（或 `-En`）。`qwen help lang` 显示当前设置和持久化方法。

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

模型列表集中在仓库根目录的 [`models.json`](models.json)。启动器按以下优先级解析使用哪个模型：

1. 命令行 `-Model <id>`
2. 环境变量 `$env:QWEN_MODEL`
3. `models.json` 的 `default` 字段

预置 id：

| id | HF 仓库 : 量化 | 大小 | 说明 |
|---|---|---|---|
| `unsloth-q4km` | `unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_M` | 22.1 GB | 默认；RTX 3080 sweep 调优后的基线（balanced profile 约 41 tok/s）。 |
| `hauhau-q4km` | `HauhauCS/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive:Q4_K_M` | 21 GB | Uncensored Aggressive 越狱版，架构一致，参数沿用。 |
| `hauhau-q4kp` | `…-Aggressive:Q4_K_P` | 23 GB | 体积更大；10 GB 显卡建议 `-Profile conserve`。 |
| `hauhau-iq4nl` | `…-Aggressive:IQ4_NL` | 20 GB | 高压缩高质量。VRAM 略宽松。 |
| `hauhau-iq2m` | `…-Aggressive:IQ2_M` | 11 GB | 最小可用量化；面向 6-8 GB 显卡。 |

常用调用：

```powershell
# 使用默认模型（unsloth-q4km）
.\scripts\qwen.ps1 start

# 临时切换
.\scripts\qwen.ps1 start -Model hauhau-q4km

# 当前 shell 持久化
$env:QWEN_MODEL = 'hauhau-iq4nl'
.\scripts\qwen.ps1 restart -Background

# 只打印解析后的配置，不启动
.\scripts\qwen.ps1 config -Model hauhau-iq2m
```

`healthcheck.ps1`、`bench-config.ps1`、`run-qwen36-35b-a3b.ps1` 都支持同一个 `-Model` 参数，也都读 `$env:QWEN_MODEL`。

---

## 切换 Profile（VRAM / 上下文 trade-off）

Profile 是预设的 `--n-cpu-moe` + `--ctx-size` 组合，按 Qwen3.6-35B-A3B（n_layer=40）调优。**不需要改 models.json**，命令行直接切换：

```powershell
qwen start -Profile safe        # N=31, ctx=16384, 余量 ~540 MB（桌面应用多时用）
qwen start -Profile balanced    # N=29, ctx=24576, sweep 最优（默认；纯文本）
qwen start -Profile longctx     # N=30, ctx=32768, 牺牲少量速度换最长 ctx
qwen start -Profile conserve    # N=33, ctx=8192,  释放 ~1 GB VRAM
qwen start -Profile vision      # N=35, ctx=16384 + mmproj 加载（启用图像输入）
```

Profile 解析优先级：

1. 命令行 `-Profile <name>`
2. 当前模型在 `models.json` 中的 `recommended_profile`
3. 兜底 `balanced`

`qwen config` 会打印解析结果及来源，例如：

```
Profile        : conserve
  source       : model.recommended_profile (hauhau-q4kp)
```

需要精细调整时也可用单参数覆盖（在 profile 之上叠加）：

```powershell
qwen start -Profile balanced -NCpuMoe 30 -Ctx 16384
```

约束：`-NCpuMoe` 必须 ∈ `[0, n_layer]`，超出会在启动前报错。

需要给某个模型固定默认 profile（而不是每次都打 `-Profile`），把它的 `recommended_profile` 字段写进 `models.json` 即可。

---

## 切换到新版模型

在 `models.json` 添加新条目：

```json
"qwen37-q4km": {
  "hf": "unsloth/Qwen3.7-XXX-GGUF:UD-Q4_K_M",
  "alias": "qwen3.7-xxx",
  "n_layer": 40,
  "size_gb": 22.0,
  "mmproj_url": "https://huggingface.co/.../mmproj-BF16.gguf?download=true",
  "mmproj_file": "mmproj/qwen37-mmproj-BF16.gguf",
  "recommended_profile": "balanced",
  "notes": "..."
}
```

然后 `qwen.ps1 start -Model qwen37-q4km`。如果架构变化（`n_layer` 或 expert 数变了），需要重新跑 sweep，`--n-cpu-moe` 的最优点会移位。同属 A3B 家族（n_layer=40）的模型可直接复用现有 profile 预设。

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

## 聊天 Web UI

浏览器端聊天界面，支持模型/profile 切换、思维链开关、中英繁三语界面。

**前置条件：** PATH 中需有 Python 3.8+，首次运行自动在 `web/.venv` 创建虚拟环境。

```powershell
qwen start -Background      # 先启动 llama-server
qwen ui                     # 在浏览器打开 http://127.0.0.1:8090
qwen ui -Background         # 后台运行（日志 → logs\qwen-ui.log）
qwen ui -h                  # 完整参数说明
```

UI 将 `/v1/*` 代理到 llama-server（默认 8080 端口）。若 llama-server 在别的端口，启动前设置 `$env:QWEN_LLAMA_PORT`。

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
