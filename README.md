# local-qwen

Self-host Qwen MoE models locally on Windows using llama.cpp's CUDA backend, with an OpenAI-compatible API. Includes a PowerShell management script with pre-tuned profiles, VRAM estimation, and LAN/WSL access.

[中文文档](README_zh.md)

---

## Features

- **OpenAI-compatible API** — drop-in replacement for any client that supports `base_url`
- **PowerShell manager** (`qwen.ps1`) — start / stop / restart / status / health / config preview
- **Pre-tuned profiles** — `balanced`, `safe`, `longctx`, `conserve`, `vision`
- **VRAM estimation** — warns before launch if OOM risk is high
- **Multimodal support** — image input via `vision` profile
- **LAN / WSL access** — bind to `0.0.0.0` with auto-generated API key auth
- **Fully local** — no data leaves the machine

---

## Requirements

| Component | Minimum | Benchmark machine |
|---|---|---|
| OS | Windows 10/11 x64 | Windows 11 Pro 26200 |
| GPU | NVIDIA, 8 GB+ VRAM | RTX 3080 10 GB |
| System RAM | 32 GB | 64 GB DDR |
| PowerShell | 7.0+ | 7.6.2 |
| NVIDIA driver | 520+ | 595.97 |

> **Note:** 64 GB RAM is recommended for the Q4_K_M quantization (22.1 GB model). With 32 GB RAM, use UD-IQ4_XS (17.7 GB) instead — see [Model Variants](#model-variants).

---

## Quickstart

### 1. Install llama.cpp (CUDA build)

Download **both** archives from the [llama.cpp GitHub Releases](https://github.com/ggml-org/llama.cpp/releases) page and extract into `bin\`:

```powershell
$ver = 'b9294'   # or latest build
$base = "https://github.com/ggml-org/llama.cpp/releases/download/$ver"
New-Item -ItemType Directory -Force bin, dl | Out-Null
Invoke-WebRequest "$base/llama-$ver-bin-win-cuda-12.4-x64.zip" -OutFile "dl\llama-$ver-cuda.zip"
Invoke-WebRequest "$base/cudart-llama-bin-win-cuda-12.4-x64.zip" -OutFile "dl\cudart-$ver.zip"
Expand-Archive "dl\llama-$ver-cuda.zip" bin -Force
Expand-Archive "dl\cudart-$ver.zip"    bin -Force
```

> **Why not `winget install ggml.llamacpp`?** That installs the Vulkan backend, which is 1.5–2× slower on RTX GPUs. See [HANDBOOK.md §2.1](HANDBOOK.md#21-why-cuda-124-and-not-the-winget-vulkan-build).

### 2. Clone This Repo

```powershell
git clone https://github.com/zhcqiu/local-qwen.git
cd local-qwen
```

### 3. Set Up the `qwen` Alias

Add to your PowerShell profile (`$PROFILE`):

```powershell
Set-Alias qwen '<absolute-path-to-repo>\scripts\qwen.ps1'
```

Reload the profile: `. $PROFILE`

### 4. Start the Server

```powershell
qwen start
```

On first launch, llama.cpp downloads the model (~22 GB) from HuggingFace. Subsequent starts load from the local cache.

> **Mainland China / slow HuggingFace access:** set the mirror endpoint before starting:
> ```powershell
> $env:HF_ENDPOINT = 'https://hf-mirror.com'
> qwen start
> ```
> To make it permanent, add that `$env:HF_ENDPOINT` line to your PowerShell profile before the alias line.

```
Endpoint: http://127.0.0.1:8080/v1  (localhost only)
```

### 5. Test It

```powershell
qwen health
```

```python
from openai import OpenAI

client = OpenAI(base_url='http://127.0.0.1:8080/v1', api_key='dummy')
resp = client.chat.completions.create(
    model='qwen3.6-35b-a3b',
    messages=[{'role': 'user', 'content': 'Hello'}],
    extra_body={'chat_template_kwargs': {'enable_thinking': False}},
    max_tokens=512,
)
print(resp.choices[0].message.content)
```

---

## Performance Benchmark

Hardware: **i7-13700KF / 64 GB RAM / RTX 3080 10 GB**, llama.cpp b9294 CUDA 12.4.

| Metric | Value |
|---|---|
| Generation speed | ~40 tok/s |
| Prompt eval speed | ~415 tok/s (7k token prompt) |
| Context window | 24576 tokens |
| VRAM (idle) | 9834 / 10240 MiB |
| VRAM (peak, 7k prompt) | 9854 / 10240 MiB |

Full sweep data and methodology: [TUNING-REPORT.md](TUNING-REPORT.md)

---

## GPU-Specific Recommendations

The key parameter is `--n-cpu-moe N`: expert layers ≤ N stay in CPU RAM; layers > N go on GPU. Lower N = more on GPU = faster generation but more VRAM.

The model has 40 layers, 256 experts/layer, top-8 active. Each layer moved to GPU costs ~475 MiB VRAM.

| GPU | `--n-cpu-moe` | ctx | Notes |
|---|---|---|---|
| RTX 3080 10 GB | 29 | 24576 | Benchmark machine; 386 MiB VRAM margin |
| RTX 4070 Ti 12 GB | ~23 | 32768 | Estimate; ~5 more expert layers fit |
| RTX 4090 / RTX 5090 24 GB+ | 0 | 65536+ | All experts on GPU; no CPU bottleneck |
| RTX 3060 12 GB | ~24 | 16384 | More VRAM but narrower bandwidth |
| RTX 3070 / 4060 Ti 8 GB | 32–33 | 16384 | Tight VRAM; start conservative |

**Always run `scripts/bench-config.ps1` to find your actual optimum** — these are starting estimates. See [HANDBOOK.md §6.2](HANDBOOK.md#62-starting-points-for-different-hardware) for CPU thread recommendations.

**CPU threads:** if you have an Intel hybrid CPU (P+E cores), set `-t <P-core-count> -tb <P-core-count>` to avoid E-cores degrading MoE math.

---

## Model Variants

All variants from [unsloth/Qwen3.6-35B-A3B-GGUF](https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF):

| Variant | Size | Quality | When to use |
|---|---|---|---|
| UD-Q4_K_M | 22.1 GB | Good | Default — sweet spot for 64 GB RAM |
| UD-IQ4_XS | 17.7 GB | Acceptable | 32 GB RAM or need longer context |
| UD-Q5_K_M | 26.5 GB | Better | 128 GB RAM / 24 GB+ GPU |
| UD-Q6_K | 29.3 GB | Best | 128 GB RAM / 24 GB+ GPU |

To switch variants, edit `$ModelHf` at the top of `scripts/qwen.ps1`.

---

## Switching to a Newer Model

When a new Qwen model is released, update two variables at the top of `scripts/qwen.ps1`:

```powershell
$ModelHf    = 'unsloth/Qwen3.7-XXX-GGUF:UD-Q4_K_M'
$ModelAlias = 'qwen3.7-xxx'
```

Then re-run the parameter sweep to find the new optimum — architecture changes (number of layers, experts, etc.) affect the `--n-cpu-moe` sweet spot.

---

## Qwen3 Thinking Mode

Qwen3 models use an extended thinking mode by default: the model writes reasoning to `message.reasoning_content` before writing `message.content`. If you get empty responses, this is usually the cause.

| Use case | Fix |
|---|---|
| Short chat / code completion | Add `chat_template_kwargs: {enable_thinking: false}` to your request |
| Complex reasoning (math, debug) | Keep default; set `max_tokens >= 1024` to leave thinking budget |
| Client doesn't handle `reasoning_content` | Launch with `--reasoning-format none` (merges thinking into content) |

---

## LAN / WSL Access

```powershell
qwen start -Lan -Background
```

This binds to `0.0.0.0:8080`, auto-generates an API key (stored in `.apikey`), and attempts to create a Windows Firewall inbound rule. Clients send `Authorization: Bearer <key>`.

See [HANDBOOK.md §9.6](HANDBOOK.md#96-lan--wsl-remote-access--step-by-step) for the full step-by-step guide.

---

## IDE / Tool Integration

Any tool that accepts an OpenAI-compatible base URL works:

| Tool | Setting |
|---|---|
| [Continue](https://continue.dev) | `apiBase: http://127.0.0.1:8080/v1` |
| [Cline](https://github.com/cline/cline) | OpenAI compatible, base URL `http://127.0.0.1:8080/v1` |
| [Aider](https://aider.chat) | `--openai-api-base http://127.0.0.1:8080/v1` |
| OpenAI Python SDK | `OpenAI(base_url='http://127.0.0.1:8080/v1', api_key='dummy')` |

---

## Documentation

| Document | Description |
|---|---|
| [HANDBOOK.md](HANDBOOK.md) | Full maintenance manual — rationale, VRAM budget, tuning playbook, troubleshooting, integration |
| [TUNING-REPORT.md](TUNING-REPORT.md) | Complete parameter sweep results and analysis |
| [HANDBOOK_zh.md](HANDBOOK_zh.md) | 完整维护手册（中文） |
| [TUNING-REPORT_zh.md](TUNING-REPORT_zh.md) | 参数 Sweep 调优报告（中文） |

---

## License

MIT — see [LICENSE](LICENSE).
