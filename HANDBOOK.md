# local-qwen Deployment Handbook

> **Audience:** Anyone who opens this machine (or clones this repo) and needs to understand, adjust, or restore this deployment. All "why" decisions are recorded here; this document is self-contained.

---

## 0. TL;DR — One-Minute Quickstart

**Any PowerShell terminal (after alias setup — see §8.8):**

```powershell
qwen start              # start server (default: balanced profile)
qwen status             # show running state
qwen health             # send a test request and report tok/s
qwen restart -Profile safe   # restart with a different profile
qwen stop               # stop the server
qwen config -NCpuMoe 30 -Ctx 16384   # preview params without starting
qwen -h                              # overview (or: qwen help)
qwen <action> -h                     # focused help for one action (e.g. qwen start -h)
qwen help <topic>                    # topic page (profiles | models | lan | examples | lang | all)
```

`qwen` is a `Set-Alias` pointing to `scripts\qwen.ps1` in this repo.

**Profiles:**

| Profile | --n-cpu-moe | -c (ctx) | mmproj | Est. idle VRAM | Est. gen tok/s | When to use |
|---|---|---|---|---|---|---|
| `safe` | 31 | 16384 | — | ~9682 / 10240 MiB | ~37 | Many desktop apps open / large VRAM swings |
| `balanced` ⭐ default | 29 | 24576 | — | ~9833 / 10240 MiB | ~40 | Sweep optimum for text-only |
| `longctx` | 30 | 32768 | — | ~9802 / 10240 MiB | ~39 | Need longest context window |
| `conserve` | 33 | 8192 | — | ~9266 / 10240 MiB | ~35 | Running other GPU workloads simultaneously |
| `vision` | 35 | 16384 | **BF16** | ~7700 / 10240 MiB (measured) | ~36 | Image input required |

> Vision profile: VRAM heuristic predicted 9609 MiB but idle measured 7700 MiB — the mmproj fixed overhead is much smaller than estimated. Either way, margin is comfortable.

**Single-parameter overrides** (on top of any profile):

```powershell
qwen start -NCpuMoe 30 -Ctx 16384 -UbatchSize 512
```

Before starting, the script prints estimated idle VRAM and margin. > 9950 MiB triggers a red OOM warning; 9750–9950 triggers a yellow "close other GPU apps" notice.

**Expected performance** (i7-13700KF + 64 GB + RTX 3080 10 GB):
- Generation: ~40 tok/s
- Prompt eval: ~400 tok/s
- Context: 24576 tokens
- VRAM peak: ~9.9 GB / 10.24 GB (tight, see §4.3)

---

## 1. System Inventory

### Hardware (reference benchmark machine)

| | |
|---|---|
| CPU | Intel i7-13700KF (16 cores: 8 P-core + 8 E-core, 24 threads) |
| RAM | 64 GB DDR |
| GPU | NVIDIA RTX 3080 10 GB (sm_86, Ampere) |
| Storage | D: 465 GB NTFS (deployment, models, and logs all on D:) |

### Software

| | |
|---|---|
| OS | Windows 11 Pro 26200 (x64) |
| Shell | PowerShell 7.6+ |
| NVIDIA driver | 595.97 (reports CUDA 13.2; compatible with CUDA 12.4 runtime) |
| llama.cpp build | **b9294** (Clang 19.1.5) |
| llama.cpp backend | **CUDA 12.4** (downloaded from GitHub Release — not the winget Vulkan build) |
| Model | `unsloth/Qwen3.6-35B-A3B-GGUF :: UD-Q4_K_M` (22.1 GB) |

### Directory Layout

```
local-qwen/
├── bin\                          # llama.cpp binaries + CUDA runtime DLLs  [not in git]
│   ├── llama-server.exe
│   ├── ggml-cuda.dll             (538 MB — CUDA backend)
│   ├── cublas64_12.dll, cublasLt64_12.dll, cudart64_12.dll
│   └── ... other llama tools
├── models\                       # model cache (HuggingFace format)          [not in git]
│   └── models--unsloth--Qwen3.6-35B-A3B-GGUF\
│       └── blobs\
│           ├── 356dfaa3...       (~900 MB tokenizer / config blob)
│           └── ac0e2c11...       (~22.1 GB Q4_K_M main weights)
├── mmproj\                       # vision encoder GGUF                       [not in git]
│   └── mmproj-BF16.gguf          (861 MB)
├── scripts\
│   ├── qwen.ps1                  # unified manager — main entry point
│   ├── run-qwen36-35b-a3b.ps1   # legacy single-shot launcher (still works)
│   ├── healthcheck.ps1           # one-shot chat completion verification
│   ├── perf-monitor.ps1          # 2-second VRAM / RAM / GPU util sampler
│   └── bench-config.ps1          # parameter sweep automation
├── logs\                          # server and bench logs                     [not in git]
├── .gitignore
├── LICENSE
├── README.md
├── HANDBOOK.md                    # this document (English)
├── HANDBOOK_zh.md                 # this document (Chinese)
├── TUNING-REPORT.md               # parameter sweep results (English)
└── TUNING-REPORT_zh.md            # parameter sweep results (Chinese)
```

⚠️ **Do not put the model back in `%LOCALAPPDATA%\llama.cpp`**: the default HF cache path writes to C:. The launch scripts set `$env:LLAMA_CACHE` to keep everything on D:.

---

## 2. Key Decisions & Rationale

### 2.1 Why CUDA 12.4 and not the winget Vulkan build

`winget install ggml.llamacpp` installs the **Vulkan backend** (`llama-b9294-bin-win-vulkan-x64.zip`). Vulkan runs on RTX 3080 but compared to CUDA:
- Missing sm_86-specific kernel optimizations
- KV quantization and flash-attention paths are less mature
- Measured CUDA gen tok/s is typically 1.5–2× faster

**Use instead:** Download from [GitHub Release b9294](https://github.com/ggml-org/llama.cpp/releases/tag/b9294):
- `llama-b9294-bin-win-cuda-12.4-x64.zip` (248 MB)
- `cudart-llama-bin-win-cuda-12.4-x64.zip` (373 MB) — required; provides cublas / cudart DLLs

Extract both directly into `bin\`. No CUDA Toolkit installation needed — runtime DLLs are bundled.

**Upgrading to CUDA 13.x:** Driver 595.97 is CUDA-13.x compatible. Switching to `llama-bXXXX-bin-win-cuda-13.1-x64.zip` is safe but there is no pressing reason to move off 12.4.

### 2.2 Why `unsloth/Qwen3.6-35B-A3B-GGUF :: UD-Q4_K_M`

- **Qwen3.6-35B-A3B** = Qwen team's fine-grained MoE, 35B total / 3B active parameters
- **unsloth UD-** prefix = Unsloth's dynamic quantization, which maintains perplexity better than standard GGUF at low bit-widths for MoE models
- **Q4_K_M** (22.1 GB) is the sweet spot for RTX 3080 10 GB + 64 GB RAM:
  - Better quality than IQ4_XS (17.7 GB)
  - Smaller than Q5_K_M (26.5 GB), fitting comfortably with `--n-cpu-moe` strategy
  - Much smaller than Q8_0 (36.9 GB), no swap needed

**Downgrade fallback** (if RAM is tight or you need longer context): UD-IQ4_XS (17.7 GB) — slightly lower quality but saves 4 GB RAM.

**Upgrade options** (with 24 GB+ GPU or 128 GB+ RAM): UD-Q5_K_M (26.5 GB) or UD-Q6_K (29.3 GB) work as drop-in replacements.

### 2.3 Rationale for each launch flag

| Flag | Value | Reason |
|---|---|---|
| `-hf` | `unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_M` | HuggingFace pull; cache location controlled by `$env:LLAMA_CACHE` |
| `--host 127.0.0.1` | localhost only | No network exposure; no firewall rule needed |
| `--port 8080` | default | Matches most OpenAI client defaults |
| `-c 24576` | 24k ctx | Largest context verified safe by sweep; model natively supports 262144 |
| `-ngl 999` | all layers | Pushes all non-MoE tensors onto GPU |
| `--n-cpu-moe 29` | 29 | **Sweep optimum** (see §5) |
| `--flash-attn auto` | enabled | Ampere supports FA; saves VRAM and speeds up attention |
| `--cache-type-k q8_0` | q8_0 | Good long-context quality; GQA + q8_0 keeps 24k KV at ~150 MB |
| `--cache-type-v q8_0` | q8_0 | Same |
| `-t 8 -tb 8` | 8 threads | i7-13700KF has 8 P-cores; E-cores degrade MoE expert math |
| `-b 2048 -ub 512` | defaults | Sweep shows both ub=1024 and ub=256 hurt performance |
| `--jinja` | enabled | Uses Qwen's native chat template (handles thinking markers, etc.) |
| `--parallel 1` | single slot | Single-user local; parallel would waste KV budget |

### 2.4 Flags deliberately omitted

- ❌ `--mlock`: already enabled by default; specifying it again is a no-op; Windows locked pages require `SeLockMemoryPrivilege`
- ❌ `--no-mmap`: mmap lets the OS page a 22 GB model naturally; `--no-mmap` reads the entire model into process memory
- ❌ `--mmproj` (in default profiles): not loading vision encoder saves ~1.1 GB estimated VRAM and preserves gen tok/s
- ❌ `--n-cpu-moe-draft` / speculative decoding: single-model deployment, no draft model
- ❌ `--threads-http`: default is fine for single-user

---

## 3. Model Architecture Key Facts

Extracted from `print_info` at startup:

```
arch                  = qwen35moe
model type            = 35B.A3B
model params          = 34.66 B
file type             = Q4_K - Medium
file size             = 20.60 GiB (5.11 BPW)

n_ctx_train           = 262144            # native max context
n_layer               = 40                # IMPORTANT: upper bound for --n-cpu-moe
n_embd                = 2048
n_head                = 16
n_head_kv             = 2                 # GQA 8× (16 attention heads → 2 KV heads)
n_embd_head_k         = 256
n_gqa                 = 8

n_expert              = 256               # experts per layer
n_expert_used         = 8                 # experts activated per token
n_expert_groups       = 0
ssm_d_conv            = 4                 # contains SSM components (hybrid architecture)
ssm_d_state           = 128
freq_base_train       = 10000000.0        # RoPE base supporting very large context
```

**Key implications:**
1. **n_layer=40** → `--n-cpu-moe N` saturates at N=40 (≡ `--cpu-moe`, all experts on CPU); N=0 puts all experts on GPU
2. **n_head_kv=2 with GQA 8×** → KV cache is tiny; q8_0 at 24k context is only ~150 MB
3. **n_expert=256, used=8** → extremely sparse activation (3.1%), which is how A3B (3B active) extracts value from 35B total parameters
4. **SSM components** → not a pure transformer; has recurrent state (visible in logs as `CUDA0 RS buffer size = 62.81 MiB`)
5. **n_ctx_train=262144** → model theoretically supports 256K context; we use 24k for VRAM reasons

---

## 4. VRAM Budget Details

### 4.1 VRAM Breakdown at Startup (N=29, ctx=24576)

| Component | Size (MiB) | Notes |
|---|---|---|
| Desktop / other processes | ~2300–2700 | Fluctuates; included in nvidia-smi used |
| CUDA0 model buffer | ~3800 (est.) | Non-expert tensors + 11 expert layers on GPU |
| CPU_Mapped model buffer | ~17000 (est.) | 29 expert layers kept in RAM |
| CUDA0 KV buffer | ~150 | q8_0 KV @ 24576 ctx |
| CUDA0 RS buffer | ~63 | SSM recurrent state |
| CUDA0 compute buffer (reserved) | 497 | Reserved by llama.cpp at startup |
| CUDA_Host compute buffer | 24 | Host-side temporary |
| **Measured idle peak** | **9834** | Matches the above |

### 4.2 Scaling Formulas

| Parameter change | VRAM impact |
|---|---|
| `--n-cpu-moe` decreases by 1 (one more expert layer on GPU) | **+~475 MiB** (layer 33 is an exception: only +91 MiB) |
| `-c` doubles (ctx 8192→16384→32768) | KV +~85 MiB per doubling (q8_0 + GQA keeps it small) |
| `--cache-type-k/v` q8_0 → q4_0 | KV halved |
| `--cache-type-k/v` q8_0 → f16 | KV doubled |
| `-ub` 512→1024 | Compute buffer +~150–200 MiB |
| `-ub` 512→256 | Compute buffer -~70 MiB, **but prompt eval collapses** |

### 4.3 VRAM Risk Thresholds (10240 MiB ceiling)

| Occupancy | Status |
|---|---|
| < 9500 MiB | Fully safe |
| 9500–9900 MiB | Safe, but watch desktop app swings (+100–200 MiB per new browser window) |
| 9900–10100 MiB | Borderline — long prompts may trigger compute buffer contention and performance drops |
| > 10100 MiB | OOM or severe degradation; unusable |

**Current deployment point** (N=29, ctx=24576): idle 9834 MiB, peak 9854 MiB, **~386 MiB margin**.

---

## 5. Performance Data — Full Parameter Sweep

### 5.1 Methodology

`scripts/bench-config.ps1` automates:
1. Stop any running llama-server
2. Start a new server with the specified parameters; wait for "server is listening"
3. Measure idle VRAM (2 seconds after start)
4. Send a short prompt (~30 tokens); record gen tok/s
5. Over 60 seconds: sample VRAM every 500 ms while sending a long prompt (~7120 tokens); record prompt/gen tok/s
6. Output structured results

**Thinking mode disabled during all tests** (`chat_template_kwargs.enable_thinking=false`) to avoid thinking tokens inflating gen tok/s numbers.

### 5.2 Full Results Table

| Label | --n-cpu-moe | ctx | -ub | idle MiB | peak MiB | short gen tok/s | long gen tok/s | long prompt tok/s | Notes |
|---|---|---|---|---|---|---|---|---|---|
| n35-c16k | 35 | 16384 | 512 | 8706 | 8868 | 32.84 | 32.76 | 300.41 | Starting point |
| n34-c16k | 34 | 16384 | 512 | 9175 | 9322 | 28.51 | 33.72 | 346.5 | |
| n33-c16k | 33 | 16384 | 512 | 9266 | 9319 | 29.45 | 34.99 | 365.46 | Layer 33 expert is unusually small |
| n32-c16k | 32 | 16384 | 512 | 9399 | 9533 | 34.61 | 36.32 | 364.74 | |
| n31-c16k | 31 | 16384 | 512 | 9682 | 9702 | 30.52 | 37.19 | 380.11 | |
| n30-c16k | 30 | 16384 | 512 | 9752 | 9792 | 31.63 | 37.83 | 396.75 | |
| **n29-c16k** | 29 | 16384 | 512 | 9808 | 9880 | 36.48 | 38.61 | 403.56 | Local optimum at ctx=16k |
| n28-c16k | 28 | 16384 | 512 | 9988 | 9998 | 34.19 | 38.56 | 309.86 | ⚠️ prompt eval collapses |
| n29-c16k-ub1024 | 29 | 16384 | **1024** | 9983 | 10000 | 36.74 | 37.04 | 168.44 | ⚠️ ubatch too large |
| n27-c16k-ub256 | 27 | 16384 | **256** | 10030 | 10033 | 35.83 | 39.38 | 114.11 | ⚠️ ubatch too small |
| **n29-c24k** ⭐ | 29 | **24576** | 512 | 9834 | 9854 | 33.15 | **39.73** | 414.51 | **Overall optimum** |
| n29-c32k | 29 | 32768 | 512 | 9796 | 9899 | 34.41 | 39.50 | 412.3 | Same speed as c24k; full-ctx OOM risk |

Raw CSV: `logs/sweep-results.csv`

### 5.3 Lessons from the Data

1. **Gen tok/s increases monotonically as N decreases** (35→29): CPU expert computation is the bottleneck; pushing one more expert layer to GPU directly converts to speed.
2. **N=28 is the inflection point**: gen stops improving (38.56 ≈ 38.61), but prompt eval collapses (404→310). At VRAM 9998/10240, compute buffer competes with KV, causing GPU scheduling jitter.
3. **ubatch is a convex function**: 512 is the sweet spot; both 1024 and 256 destroy prompt eval.
4. **Context is nearly free**: going from 16384 to 32768 adds only ~100 MiB KV (GQA + q8_0).
5. **Layer 33 expert is anomalously small**: N=33→32 adds only +91 MiB instead of the usual +475 MiB. Likely a different expert count or dimension in that layer (hybrid SSM interaction not fully investigated).
6. **GPU utilization stays at 30–50%**: the GPU is not saturated — CPU expert computation is the slow path.

---

## 6. Tuning Playbook

### 6.1 Symptom → Response

| Symptom | Likely cause | Response |
|---|---|---|
| `out of memory` / `failed to allocate` at startup | Insufficient VRAM | `--n-cpu-moe` +1 (frees ~475 MiB) or halve `-c` |
| Startup succeeds but prompt eval < 200 tok/s (long prompts) | VRAM borderline; compute buffer contention | Same: N+1 |
| Gen tok/s < 30 (was normal before) | Background process stealing GPU; model not in RAM cache | Check `nvidia-smi --query-compute-apps`; restart server to re-warm mmap |
| RAM full / Windows sluggish | Desktop apps + 22 GB mmap + OS filling 64 GB | Close non-essential apps; consider switching to IQ4_XS (17.7 GB) |
| Need very long prompts (>20k tokens) | Current ctx=24576 is fine; 32768 has full-ctx OOM risk | Set N=30, `-c 32768`, leaving ~150 MiB compute buffer margin |
| Want higher-quality responses | Quantization / KV quantization loss | Switch to `--cache-type-k f16 --cache-type-v f16` (+150 MiB VRAM); or upgrade to UD-Q5_K_M model (+4.4 GB RAM) |

### 6.2 Starting Points for Different Hardware

| GPU | Recommended starting config |
|---|---|
| RTX 3080 10 GB (benchmark machine) | N=29, ctx=24576 |
| RTX 4070 Ti 12 GB | N=23, ctx=32768 — estimate ~5 more expert layers fit |
| RTX 4090 / RTX 5090 24 GB | `--n-cpu-moe 0` (all experts on GPU), ctx=65536+ |
| RTX 3060 12 GB | N=24, ctx=16384 — more VRAM but narrower bandwidth vs 3080 |
| Mac M3 Max 36–128 GB | Use Metal build; all weights fit in unified memory |

These are starting estimates — run a sweep with `scripts/bench-config.ps1` to find your actual optimum.

**CPU thread count:**

| CPU type | `-t` / `-tb` guidance |
|---|---|
| Intel 12th–14th gen (P+E cores) | `-t <P-core count> -tb <P-core count>` — exclude E-cores |
| AMD Ryzen 7/9 X3D | Start at `-t 6` or `-t 8` (cache-sensitive; fewer threads often wins) |
| Pure P-core or server CPU | `-t <physical core count>` |

### 6.3 Squeezing Out the Last Few tok/s

In order of return-on-effort:

1. **Free VRAM from desktop apps**: every 200 MiB freed allows N to decrease by ~0.4, which translates directly to speed. Close browser tabs, IDE previews, Discord hardware-accelerated windows.
2. **Run llama-bench for exact profiling**: `bin\llama-bench.exe -m <gguf-path>` plots pp/tg curves across batch sizes.
3. **Try a newer llama.cpp build**: CUDA kernel improvements ship frequently; a newer build often gives 5–15% for free.
4. **Disable thinking mode**: `chat_template_kwargs: {enable_thinking: false}` removes reasoning overhead and returns results faster.
5. **Use streaming**: `stream: true` doesn't improve tok/s but dramatically reduces perceived latency.

---

## 7. Troubleshooting

### 7.1 Server Fails to Start

```
Symptom: script runs but "server is listening" never appears
```

Check in order:
1. `nvidia-smi` runs successfully (driver healthy)
2. `bin\llama-server.exe --version` outputs `version: 9294 ...`
3. `models\models--unsloth--Qwen3.6-35B-A3B-GGUF\blobs\` contains the 22 GB weight blob
4. Check the last lines of `logs\server-*.log`:
   - `out of memory` → see §6.1
   - `model file not found` → check that `$env:LLAMA_CACHE` is set correctly (scripts do this automatically)
   - `cublas` / `cudart` missing → re-extract `cudart-llama-bin-win-cuda-12.4-x64.zip` into `bin\`
5. Windows Firewall prompt: first run may ask to allow llama-server.exe to listen on 127.0.0.1

### 7.2 Model Download Fails

`-hf` downloads from HuggingFace Hub. If network access is limited:
- **Manual download**: download the GGUF file manually, place it in `models\manual\`, and change `-hf <repo>` to `-m <absolute-path>` in the launch args
- **Proxy**: set `$env:HTTPS_PROXY = 'http://127.0.0.1:<port>'` before starting

### 7.3 Empty Responses

90% of the time this is Qwen3 thinking mode consuming all the token budget.
- Inspect the response JSON: `message.reasoning_content` is long and `message.content` is empty → confirmed
- Fix: add `chat_template_kwargs: {enable_thinking: false}` to your request
- Or: set `max_tokens >= 1024` to give thinking enough budget before the answer

### 7.4 Sudden Performance Drop

Likely causes (in order of probability):

1. **Another process grabbed GPU**: `nvidia-smi --query-compute-apps=pid,process_name --format=csv` — find and kill it
2. **VRAM full, entering thrash**: restart the server; if this happens repeatedly, the config is too aggressive — increase N by 1
3. **Windows background scan / Defender**: model mmap file is being scanned; disk I/O blocks expert computation
4. **Thermal throttling**: after sustained load, GPU/CPU may downclock; check GPU temperature and fan curve

### 7.5 VRAM Drift Over Long Runs

**Symptom:** idle VRAM starts at 9834 MiB right after launch; after hours of use it climbs to 9950+ MiB.

**Cause:** llama.cpp accumulates internal sampler/HTTP worker caches across multiple inference calls. Even with `--parallel 1`, expect ~100–200 MiB growth. **This is normal behavior.**

**Verify:** after `qwen stop`, check nvidia-smi — true desktop app baseline is ~700 MiB. If > 1.5 GiB remains after stop, another process is holding GPU memory.

**Mitigation:**
- Run `qwen restart` weekly or after ~50 inference calls to reset idle VRAM
- Use `qwen start -Profile safe` (N=31) for an extra 200+ MiB margin to absorb drift
- Increasing N does not prevent accumulation — restart is the only reset

---

## 8. Operations

### 8.1 Start

```powershell
qwen start                           # balanced profile (default)
qwen start -Profile safe             # switch profile
qwen start -NCpuMoe 30 -Ctx 16384    # single-param override
qwen start -Background               # detach from terminal
```

Foreground mode tees logs to screen and `logs\server-YYYYMMDD-HHMMSS.log`; Ctrl+C stops the server. Background mode prints the PID; use `qwen status` to check it.

`LLAMA_CACHE` is set automatically inside the script — no manual export needed.

### 8.2 Stop / Restart

```powershell
qwen stop
qwen restart -Profile longctx        # stop, then restart with new profile
```

### 8.3 Status

```powershell
qwen status
# Output: PID / start time / uptime / CPU time / working set / GPU memory / endpoint
```

### 8.4 Health Check

```powershell
qwen health
# Output: wall_time / gen tok/s / prompt tok/s / response text
```

Gen tok/s below 30 usually indicates a configuration problem or VRAM thrashing.

### 8.5 Preview Config Without Starting

```powershell
qwen config -Profile longctx -NCpuMoe 28
# Shows the parameters that would be used + estimated idle VRAM + margin / warning
```

Use this before trying an aggressive configuration to check whether it will OOM.

### 8.6 Resource Monitoring

```powershell
& ".\scripts\perf-monitor.ps1" -DurationSec 60
```

Samples VRAM / RAM / GPU utilization every 2 seconds; results go to `logs\perf-*.csv`.

### 8.7 Re-Running a Parameter Sweep

```powershell
$results = @()
$results += & ".\scripts\bench-config.ps1" -NCpuMoe 29 -Ctx 24576 -Label "current"
# Add more entries with different params...
$results | Export-Csv ".\logs\custom-sweep.csv" -NoTypeInformation
```

### 8.8 Alias Setup (First Time)

Add to your PowerShell profile (`$PROFILE`):

```powershell
Set-Alias qwen '<absolute-path-to-repo>\scripts\qwen.ps1'
```

To remove the `qwen` command, delete that line from your profile.

### 8.9 Switching Models

All scripts read model definitions from [`models.json`](../models.json) at the repo root. Resolution order:

1. `-Model <id>` flag (highest priority)
2. `$env:QWEN_MODEL` (persists for the shell session)
3. `default` field in `models.json`

```powershell
qwen start                              # default model
qwen start -Model hauhau-q4km           # one-off switch
qwen config -Model hauhau-iq2m          # preview without launching
$env:QWEN_MODEL = 'hauhau-iq4nl'        # persist for this shell
qwen restart -Background                 #   ↳ picks up the env var
```

Seeded entries are documented in `README.md` → *Model Variants*. Each entry stores:

- `hf` — passed to `llama-server -hf <repo>:<quant>`; weights download to `models/` on first launch
- `alias` — value clients must send in the `model` field of OpenAI-compatible requests
- `n_layer` — used as the upper bound for `--n-cpu-moe` (all current entries are 40)
- `mmproj_url` / `mmproj_file` — optional; the launcher auto-downloads on first use of the `vision` profile

To add a new model, append an entry to `models.json` and re-launch. Same architecture as Qwen3.6-35B-A3B (40 layers, 256 experts, top-8) → existing profile presets carry over. Different architecture → re-run the sweep (§5) to find the new `--n-cpu-moe` sweet spot.

`bench-config.ps1` tags results with the resolved model id, so sweep CSVs from different models stay distinguishable.

### 8.10 Help System

There are exactly three help calls to remember:

| Need | Command |
|---|---|
| Overview (actions, topics, common recipes) | `qwen -h` |
| Focused help for one action | `qwen <action> -h`  (e.g. `qwen start -h`) |
| Cross-cutting topic page | `qwen help <topic>` |

`-h` is the canonical flag. `-Help` and `-?` are accepted aliases. PowerShell does not support `--help` (the language parses it as `-help`, which then collides with our switch); use `-h`.

**Per-action help** exists for every action:

```
qwen start -h        qwen restart -h     qwen health -h     qwen config -h
qwen stop -h         qwen status -h      qwen validate -h
```

Each prints: synopsis, signature, relevant flags only for that action, and 2–4 examples. No flag dumped that doesn't apply to that action.

**Topic pages** cover things that span actions:

| Topic | Contents |
|---|---|
| `qwen help models` | Listing/switching models, resolution precedence, registry schema |
| `qwen help profiles` | Profile cheat sheet (safe / balanced / longctx / conserve / vision), resolution order |
| `qwen help lan` | LAN/WSL exposure + API key + firewall rule |
| `qwen help examples` | Common command patterns |
| `qwen help lang` | How to set the help language permanently |
| `qwen help actions` | All actions listed with one-line descriptions |
| `qwen help all` | The full `Get-Help -Full` dump (PowerShell-native, verbose) |

**Language.** Default is English. Three ways to switch to Chinese:

```powershell
qwen <anything> -h -Zh                  # one-off override
$env:QWEN_HELP_LANG = 'zh'              # this shell only
# Add the line above to $PROFILE for global persistence.
```

Resolution: `-En` / `-Zh` flag > `$env:QWEN_HELP_LANG` > English. `qwen help lang` prints the currently-effective language and the persistence recipe.

---

## 9. Integration / Client Usage

### 9.0 Two Access Modes

| Mode | Launch | Listen address | Auth | Who can access |
|---|---|---|---|---|
| **Local** (default) | `qwen start` | `127.0.0.1:8080` | None | This Windows machine only |
| **LAN / WSL** | `qwen start -Lan` | `0.0.0.0:8080` | **API key required** | Windows machine + same-LAN devices + WSL |

Starting with `-Lan`:
- Auto-generates an API key → `.apikey` (current-user-only ACL)
- Passes `--api-key-file` to llama-server (key never appears in process command line)
- Attempts to create a Windows Firewall inbound rule (requires admin; prints the command to run manually if it fails)

⚠️ **API key enforcement:** llama.cpp only checks keys on inference endpoints (`/v1/chat/completions`, etc.). `/v1/models` is unauthenticated — this is llama.cpp's default behavior and is expected.

### 9.1 Endpoints

| Caller | Mode | URL | Header |
|---|---|---|---|
| Windows host (local) | Either | `http://127.0.0.1:8080/v1` | None (local mode) / `Authorization: Bearer <key>` (LAN mode) |
| WSL | LAN | `http://<LAN-IP>:8080/v1` | `Authorization: Bearer <key>` |
| SSH'd headless machine on same LAN | LAN | `http://<LAN-IP>:8080/v1` | `Authorization: Bearer <key>` |
| Public internet | — | **Do not expose** — no hardening | |

Model name: defined per-model in `models.json` under the `alias` field. Clients must send the alias of whichever model the server was started with — each model has a unique alias (e.g. `qwen3.6-35b-a3b` for unsloth-q4km, `hauhau-35b-q4km`/`hauhau-35b-q4kp`/`hauhau-35b-iq4nl`/`hauhau-35b-iq2m` for the Hauhau variants). Confirm the active alias with `GET /v1/models`.

### 9.2 Python (openai SDK)

```python
from openai import OpenAI

client = OpenAI(
    base_url='http://127.0.0.1:8080/v1',
    api_key='not-needed',  # llama-server doesn't check in local mode, but SDK requires non-empty
)

# Recommended: disable thinking for chat/code tasks
resp = client.chat.completions.create(
    model='qwen3.6-35b-a3b',
    messages=[{'role': 'user', 'content': 'Hello'}],
    extra_body={
        'chat_template_kwargs': {'enable_thinking': False}
    },
    max_tokens=1024,
)
print(resp.choices[0].message.content)
```

### 9.3 curl

```bash
curl http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "qwen3.6-35b-a3b",
    "messages": [{"role":"user","content":"Hello"}],
    "max_tokens": 1024,
    "chat_template_kwargs": {"enable_thinking": false}
  }'
```

### 9.4 IDE Plugins (Continue / Cline / Aider)

Typical config:
- `apiBase` / `OPENAI_API_BASE`: `http://127.0.0.1:8080/v1`
- `apiKey` / `OPENAI_API_KEY`: `dummy` (any non-empty string)
- `model`: `qwen3.6-35b-a3b`

### 9.5 Multimodal (Image Input)

The model is multimodal (Image-Text-to-Text), but default profiles omit the vision encoder to maximize gen speed. Switch when image input is needed:

```powershell
qwen restart -Profile vision           # local vision
qwen restart -Profile vision -Lan      # expose to LAN / WSL
```

**mmproj file:** `mmproj\mmproj-BF16.gguf` (861 MB).
Download if missing:
```powershell
New-Item -ItemType Directory -Force mmproj
Invoke-WebRequest -Uri 'https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/resolve/main/mmproj-BF16.gguf?download=true' -OutFile 'mmproj\mmproj-BF16.gguf'
```

**Measured overhead** (N=35, ctx=16384, mmproj-BF16):
- Idle VRAM: ~7700 MiB (prediction was 9609 MiB — mmproj fixed overhead much smaller than estimated)
- 1.5 MB JPEG → 4022 prompt tokens
- Wall time: ~20 s (image encoding + short answer)
- Gen tok/s: ~36 (vs ~40 for text-only balanced profile)

**Python example:**

```python
from openai import OpenAI
import base64

img_b64 = base64.b64encode(open('test.jpg', 'rb').read()).decode()
client = OpenAI(base_url='http://127.0.0.1:8080/v1', api_key='not-needed')

resp = client.chat.completions.create(
    model='qwen3.6-35b-a3b',
    messages=[{
        'role': 'user',
        'content': [
            {'type': 'image_url', 'image_url': {'url': f'data:image/jpeg;base64,{img_b64}'}},
            {'type': 'text', 'text': 'Describe this image.'}
        ]
    }],
    extra_body={'chat_template_kwargs': {'enable_thinking': False}},
    max_tokens=512,
)
print(resp.choices[0].message.content)
```

**Notes:**
- Switching profiles requires `qwen restart` — mmproj is bound at startup and cannot be hot-swapped
- A 1024×1024 image typically uses 1000–2000 prompt tokens; high-resolution images count against ctx
- `--image-min-tokens` / `--image-max-tokens` control token budget per image (default: model-adaptive)

### 9.6 LAN / WSL Remote Access — Step-by-Step

**Step 1 — Windows host (one-time setup):**

```powershell
# Start in LAN mode (auto-generates API key, attempts firewall rule)
qwen start -Lan -Background

# If firewall rule creation failed, run once in an elevated pwsh:
New-NetFirewallRule -DisplayName 'Qwen llama-server (Private LAN)' `
  -Direction Inbound -Action Allow `
  -Protocol TCP -LocalPort 8080 -Profile Private `
  -Program '<repo-root>\bin\llama-server.exe'

# Print the key to share with clients
Get-Content '.apikey'
```

**Step 2 — WSL client (same Windows machine):**

```bash
export QWEN_KEY=$(cat /mnt/<drive>/AI/local-qwen/.apikey 2>/dev/null || echo '<paste-key>')
export QWEN_URL='http://<LAN-IP>:8080/v1'

# Test
curl -s -H "Authorization: Bearer $QWEN_KEY" $QWEN_URL/models | jq .
```

**Step 3 — SSH'd machine on same LAN:**

```bash
echo 'export QWEN_KEY="<paste key>"' >> ~/.bashrc
echo 'export QWEN_URL="http://<LAN-IP>:8080/v1"' >> ~/.bashrc
source ~/.bashrc
curl -s -H "Authorization: Bearer $QWEN_KEY" $QWEN_URL/models
```

**Step 4 — Return to local-only mode:**

```powershell
qwen restart   # without -Lan: binds back to 127.0.0.1; .apikey file is retained but unused
```

**Rotate the API key** (if compromised):

```powershell
Remove-Item '.apikey'
qwen restart -Lan -Background   # new key generated on next start
```

### 9.7 Qwen3 Thinking Mode

The model by default writes reasoning to `message.reasoning_content` before writing `message.content`. Options:

| Use case | Setting |
|---|---|
| Short, fast answers (chat, code completion) | `chat_template_kwargs: {enable_thinking: false}` |
| Complex reasoning (math, debugging) | Leave default; set `max_tokens >= 1024` for thinking budget |
| Client doesn't support `reasoning_content` | Pass `--reasoning-format none` at server startup (merges thinking into content) |

---

## 10. Maintenance

### 10.1 Updating llama.cpp (Recommended Every 1 Month)

```powershell
$ver = 'b9500'  # replace with latest build number
$urls = @(
  "https://github.com/ggml-org/llama.cpp/releases/download/$ver/llama-$ver-bin-win-cuda-12.4-x64.zip"
  "https://github.com/ggml-org/llama.cpp/releases/download/$ver/cudart-llama-bin-win-cuda-12.4-x64.zip"
)
# Backup first
Copy-Item 'bin' 'bin.old' -Recurse
# Download and extract
foreach ($u in $urls) {
  $f = "dl\$([System.IO.Path]::GetFileName($u))"
  Invoke-WebRequest $u -OutFile $f
  Expand-Archive $f 'bin' -Force
}
# Verify
& 'bin\llama-server.exe' --version
```

After upgrading, run `qwen health`. **If gen tok/s drops significantly**, roll back `bin.old` — a new build may have changed kernel defaults or removed a flag.

### 10.2 Updating the Model

unsloth's GGUF repository updates with upstream Qwen fixes. To refresh:

```powershell
# Remove cached weights
Remove-Item 'models\models--unsloth--Qwen3.6-35B-A3B-GGUF' -Recurse -Force
# Restart server — -hf will pull the latest version
qwen start
```

### 10.3 Backup Checklist

If reinstalling the OS, back up:
- ✅ `scripts\` — the management scripts
- ✅ `HANDBOOK.md`, `TUNING-REPORT.md` — documentation
- ✅ `logs\sweep-results.csv` — raw sweep data
- ⚠️ `models\` — 22 GB, re-downloadable in 5–15 min; back up to save time
- ⚠️ `bin\` — 620 MB, re-downloadable; no state to preserve

---

## 11. Security Notes

- Default mode listens on `127.0.0.1` only — not reachable from the network ✓
- No API key in local mode — do not bind to `0.0.0.0` or forward the port without enabling `-Lan` mode (which adds key auth)
- Model weights are local — **no conversation data leaves the machine** ✓
- `logs\server-*.log` does not record user inputs; only system/performance information
- `logs\bench-*.json` contains only benchmark test prompts; safe to delete

---

## 12. Decision Log (Timeline)

| Phase | Config | Gen tok/s | Ctx | Decision motivation |
|---|---|---|---|---|
| 1 | Vulkan b9294 defaults | (not measured) | 8192 | winget default; confirmed functional but not optimal |
| 2 | CUDA 12.4 + q8_0 KV + `--cpu-moe` | 25.73 | 8192 | Switched to GitHub CUDA package; q4_0→q8_0 for KV quality; `--cpu-moe` as safe starting point |
| 3 | `--n-cpu-moe 35` | 27.48 | 8192 | Moved 5 expert layers to GPU; model has 40 layers (not 48 as initially assumed) |
| 4 | ctx 8192 → 16384 | 32.84 | 16384 | KV doubling has negligible VRAM cost; long context has high value |
| 5 | Full sweep N=34→27, ub=256/512/1024 | — | — | Systematic exploration to find inflection points |
| 6 | **N=29, ctx=24576** ⭐ | **39.73** | **24576** | Sweep optimum; N=28 causes prompt eval collapse; ctx=32k has same speed but full-ctx OOM risk |

**Overall improvement from initial baseline to optimum: gen +54%, context 3×.**

---

## 13. Appendix: Raw Sweep Data

See `logs/sweep-results.csv`.
