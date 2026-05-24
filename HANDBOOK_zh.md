# Qwen3.6-35B-A3B 本地部署维护手册

> **本手册的目标读者**：未来某天打开这台机器、需要重新理解、调整或恢复这套部署的人（包括未来的你 / 未来 session 的 AI）。所有"为什么"都写在这里，不依赖外部 chat 记忆。
>
> **撰写日期**：2026-05-23
> **配置主机**：i7-13700KF / 64 GB / RTX 3080 10 GB / Windows 11

---

## 0. TL;DR — 一分钟上手

**任何 pwsh 终端**：
```powershell
qwen start              # 启动 (默认 balanced profile)
qwen status             # 查状态
qwen health             # 测响应速度
qwen restart -Profile safe   # 切换到 safe profile 重启
qwen stop               # 停止
qwen config -NCpuMoe 30 -Ctx 16384   # 预览参数（不启动）
qwen help               # 完整用法
```

`qwen` 是 `Set-Alias` 指向 `<repo-root>\scripts\qwen.ps1`，已加到用户 PowerShell profile。

**Profiles**：
| Profile | --n-cpu-moe | -c (ctx) | mmproj | 估算 idle VRAM | 估算 gen tok/s | 适用 |
|---|---|---|---|---|---|---|
| `safe` | 31 | 16384 | — | ~9682 / 10240 | ~37 | 桌面应用多/VRAM 波动大 |
| `balanced` ⭐ default | 29 | 24576 | — | ~9833 / 10240 | ~40 | sweep 最优，正常使用 |
| `longctx` | 30 | 32768 | — | ~9802 / 10240 | ~39 | 需要长上下文 |
| `conserve` | 33 | 8192 | — | ~9266 / 10240 | ~35 | 还要跑别的 GPU 任务时 |
| `vision` | 35 | 16384 | **BF16** | ~7700 / 10240 实测 | ~36 | 需要图像输入；只在需要时切到此 profile |

> Vision profile 用预估 9609，实测 idle 仅 7700 — heuristic 高估了 mmproj 的固定占用。无论如何，余量充足。

**单参数覆盖**（任何 profile 之上）：
```powershell
qwen start -NCpuMoe 30 -Ctx 16384 -UbatchSize 512
```
脚本会在启动前打印估算 idle VRAM + margin，>9950 触发红色 OOM 警告，9750-9950 触发黄色"建议关其它 GPU 应用"提示。

**遗留脚本**：`run-qwen36-35b-a3b.ps1`、`healthcheck.ps1` 仍可用，但 `qwen` 命令是新主入口。

**预期性能**（i7-13700KF + 64GB + RTX 3080 10GB）：
- gen ~40 tok/s
- prompt eval ~400 tok/s
- ctx 24576
- VRAM peak ~9.9 GB / 10.24 GB（边界吃紧）

---

## 1. 系统清单

### 硬件
| | |
|---|---|
| CPU | Intel i7-13700KF (16 cores: 8 P-core + 8 E-core, 24 threads) |
| RAM | 64 GB DDR (实测 TotalVisibleMemorySize 63.85 GB) |
| GPU | NVIDIA RTX 3080 10GB (sm_86, Ampere) |
| 存储 | D: 465 GB NTFS（部署/模型/日志全在 D 盘） |

### 软件
| | |
|---|---|
| OS | Windows 11 Pro 26200 (x64) |
| Shell | PowerShell 7.6.2 Core (pwsh) |
| NVIDIA driver | 595.97（report CUDA 13.2） |
| llama.cpp build | **b9294** (Clang 19.1.5) |
| llama.cpp backend | **CUDA 12.4**（从 GitHub Release 下载，不是 winget Vulkan） |
| Model | `unsloth/Qwen3.6-35B-A3B-GGUF :: UD-Q4_K_M`（22.1 GB） |

### 部署位置
```
<repo-root>\
├── bin\                          # llama.cpp 二进制 + CUDA runtime DLLs
│   ├── llama-server.exe
│   ├── llama-server-impl.dll
│   ├── ggml-cuda.dll             (538 MB - CUDA 后端)
│   ├── cublas64_12.dll, cublasLt64_12.dll, cudart64_12.dll
│   └── ... 其他 llama 工具
├── models\
│   └── models--unsloth--Qwen3.6-35B-A3B-GGUF\
│       └── blobs\                # HF 缓存格式
│           ├── 356dfaa3...       (~900 MB tokenizer/config blob)
│           └── ac0e2c11...       (~22.1 GB Q4_K_M 主权重)
├── scripts\
│   ├── run-qwen36-35b-a3b.ps1    # 最优配置启动脚本
│   ├── healthcheck.ps1           # 单次 chat completion 验证
│   ├── perf-monitor.ps1          # 2s 采样 VRAM/RAM/GPU 利用率
│   └── bench-config.ps1          # 参数 sweep 工具
├── logs\                          # 所有 server / bench 日志
├── FINAL-REPORT.md                # 初始部署完成报告
├── TUNING-REPORT.md               # Sweep 调优摘要
└── HANDBOOK.md                    # 本手册
```

⚠️ **不要把模型放回 `%LOCALAPPDATA%\llama.cpp`**：默认 HF 缓存路径会写 C 盘。启动脚本里 `$env:LLAMA_CACHE = $Models` 必须保留。

---

## 2. 关键决策与理由（按重要性排序）

### 2.1 为什么用 CUDA 12.4 而不是 winget Vulkan

`winget install ggml.llamacpp` 装的是 **Vulkan 后端**（`llama-b9294-bin-win-vulkan-x64.zip`）。Vulkan 在 RTX 3080 上能跑，但相比 CUDA：
- 缺少 sm_86 专用内核优化
- KV 量化和 flash-attn 路径不够成熟
- 实测 CUDA 后端 gen tok/s 通常高 1.5–2x

**改用**：从 [GitHub Release b9294](https://github.com/ggml-org/llama.cpp/releases/tag/b9294) 下载：
- `llama-b9294-bin-win-cuda-12.4-x64.zip` (248 MB)
- `cudart-llama-bin-win-cuda-12.4-x64.zip` (373 MB) — 必须，否则缺 cublas/cudart

直接解压到 `<repo-root>\bin\` 即可，不需要再装 CUDA Toolkit（runtime DLLs 已自带）。

**如果未来需要换 CUDA 13.x build**：driver 595.97 兼容 CUDA 13.x，可以下 `llama-bXXXX-bin-win-cuda-13.1-x64.zip` 替换。但 12.4 已经稳定，无强动机升级。

### 2.2 为什么是 `unsloth/Qwen3.6-35B-A3B-GGUF :: UD-Q4_K_M`

- **Qwen3.6-35B-A3B** = Qwen 团队 2026 年的细粒度 MoE，35B 总参 / 3B 激活
- **unsloth UD-** 前缀 = Unsloth 的 dynamic quant，对 MoE 在低位量化下 perplexity 更稳
- **Q4_K_M**（22.1 GB）是 RTX 3080 10GB + 64GB RAM 的甜点：
  - 比 IQ4_XS (17.7) 质量更好
  - 比 Q5_K_M (26.5) 小，能用 `--cpu-moe` 战术装进 64GB RAM
  - 比 Q8_0 (36.9) 小得多，无需 swap

**可选下行回退**（如果未来 RAM 紧或想跑更大 ctx）：UD-IQ4_XS (17.7 GB)，质量略降但能省 4 GB RAM。

**可选上行**（如果换 24GB+ GPU 或 128GB RAM）：UD-Q5_K_M (26.5) 或 UD-Q6_K (29.3) 都能直接用。

### 2.3 关键启动 flag 的选择理由

| flag | 值 | 理由 |
|---|---|---|
| `-hf` | `unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_M` | 直接 HF 拉，缓存路径由 `$env:LLAMA_CACHE` 控制 |
| `--host 127.0.0.1` | 仅本机 | 不开公网，无需防火墙规则 |
| `--port 8080` | 默认 | 与大多数 OpenAI client 默认一致 |
| `-c 24576` | 24k | 经 sweep 验证 VRAM 安全的最大值；模型 native 支持 262144 |
| `-ngl 999` | 全层 | 让所有可放 GPU 的非-MoE 张量都进 VRAM |
| `--n-cpu-moe 29` | 29 | **sweep 找到的最优点**（详见 §6） |
| `--flash-attn auto` | 启用 | Ampere 支持，省 VRAM + 提速 |
| `--cache-type-k q8_0` | q8_0 | 长 ctx 质量好；GQA + q8_0 让 24k ctx KV 只 ~150 MB |
| `--cache-type-v q8_0` | q8_0 | 同上 |
| `-t 8 -tb 8` | 8 thread | 13700KF 8 个 P-core；E-core 上跑 MoE expert 会拖累 |
| `-b 2048 -ub 512` | 默认 | sweep 显示 ub 双向偏离都掉性能 |
| `--jinja` | 启用 | 用 Qwen 原生 chat template（处理 thinking marker 等） |
| `--parallel 1` | 单 slot | 本机单用户场景，并行无收益反而增 KV |

### 2.4 为什么不用某些常见 flag

- ❌ `--mlock`：默认已 enabled，重复指定无意义；且 Windows 锁页需要 SeLockMemoryPrivilege
- ❌ `--no-mmap`：22 GB 模型用 mmap 让 OS 自然调页更稳；--no-mmap 会把整个模型读进进程内存
- ❌ `--mtmd-cli` / `--mmproj`：不启用 vision
- ❌ `--n-cpu-moe-draft` / speculative：单模型部署，无 draft model
- ❌ `--threads-http`：默认即可
- ❌ `--api-key`：本机部署，无需 auth

---

## 3. 模型架构关键事实

从 `print_info` 提取：

```
arch                  = qwen35moe
model type            = 35B.A3B
model params          = 34.66 B
file type             = Q4_K - Medium
file size             = 20.60 GiB (5.11 BPW)

n_ctx_train           = 262144            # native max ctx
n_layer               = 40                # 关键！--n-cpu-moe 取值上限
n_embd                = 2048
n_head                = 16
n_head_kv             = 2                 # GQA 8x（attention 头 16 → KV 头 2）
n_embd_head_k         = 256
n_gqa                 = 8

n_expert              = 256               # 每层 expert 总数
n_expert_used         = 8                 # 每 token 激活 expert 数
n_expert_groups       = 0
ssm_d_conv            = 4                 # 包含 SSM 组件（hybrid arch）
ssm_d_state           = 128
freq_base_train       = 10000000.0        # RoPE base，超大 ctx 支持
```

**重要 implications**：
1. **n_layer=40** → `--n-cpu-moe N` 中 N=40 等同 `--cpu-moe`（全部 expert 在 CPU），N=0 等同所有 expert 在 GPU
2. **n_head_kv=2 with GQA 8x** → KV cache 极小，q8_0 下 24k ctx 才 ~150 MB
3. **n_expert=256, used=8** → 极稀疏激活（3.1%），所以 A3B（3B 激活）能从 35B 总参中提取
4. **包含 SSM 组件** → 不是纯 transformer，有 recurrent state（log 中可见 `CUDA0 RS buffer size = 62.81 MiB`）
5. **n_ctx_train=262144** → 模型理论支持 256K context，我们只用 24k 是为 VRAM

---

## 4. VRAM 详细预算（关键参考）

### 4.1 加载后 VRAM 分布（来自 N=29 c=24576 启动 log）

| 组件 | 大小 (MiB) | 说明 |
|---|---|---|
| **桌面/其它进程** | ~2300-2700 | 浮动，会被 nvidia-smi 计入 used |
| CUDA0 model buffer | ~3800 (估) | 非-expert 张量 + 推到 GPU 的 11 层 expert |
| CPU_Mapped model buffer | ~17000 (估) | 留在 CPU 的 29 层 expert |
| CUDA0 KV buffer | ~150 | q8_0 KV @ 24576 ctx |
| CUDA0 RS buffer | ~63 | SSM recurrent state |
| CUDA_Host output buffer | ~1 | 微小 |
| CUDA0 compute buffer (reserved) | 497 | llama.cpp 启动时 reserve_compute_meta |
| CUDA_Host compute buffer | 24 | 主机端临时 |
| **总占用 (理论)** | ~6800-7300 | llama-server 本身 |
| **+ 桌面应用** | ~2700 | |
| **实测 idle peak** | **9834** | 与上述相符 |

### 4.2 各组件随参数缩放公式

| 参数变化 | VRAM 影响 |
|---|---|
| `--n-cpu-moe` -1（多 1 层 expert 到 GPU） | **+ 约 475 MB**（layer 33 是例外，只 +91 MB） |
| `-c` 翻倍（ctx 8192→16384→32768） | KV +~85 MiB / 翻倍（q8_0 + GQA 让它很小） |
| `--cache-type-k/v` q8_0 → q4_0 | KV 减半 |
| `--cache-type-k/v` q8_0 → f16 | KV 翻倍 |
| `-ub` 512→1024 | compute buffer +~150-200 MB |
| `-ub` 512→256 | compute buffer -~70 MB，**但 prompt eval 暴跌** |

### 4.3 VRAM 风险线（10240 MiB 上限）

- **< 9500 MiB 占用**：完全安全
- **9500-9900**：安全，但留意桌面应用波动（开新浏览器窗口可能 +100-200 MB）
- **9900-10100**：边界，长 prompt 可能触发性能衰退（compute buffer 争用）
- **> 10100**：OOM 或严重性能衰退，已不可用

**实际部署点**（N=29 c=24576）：idle 9834, peak 9854，**距上限 386 MB**。这就是当前余量。

---

## 5. 性能数据 — 完整 Sweep

### 5.1 测试方法

`scripts/bench-config.ps1` 自动化流程：
1. 停止任何运行中的 llama-server
2. 用指定参数启动新 server，等待 "server is listening"
3. 测量 idle VRAM（启动后 2s）
4. 发短 prompt（"用中文用三句话解释..."，~30 tokens），记录 gen tok/s
5. 后台 60s 内每 500ms 采样 VRAM，同时发长 prompt（~7120 tokens），记录 prompt/gen tok/s
6. 输出结构化结果

**测试 prompt 都关闭 thinking**：`chat_template_kwargs.enable_thinking=false`，避免 thinking token 干扰 gen tok/s 测量。

### 5.2 完整结果表

| 标签 | --n-cpu-moe | ctx | -ub | idle MiB | peak MiB | short gen tok/s | long gen tok/s | long prompt tok/s | 状态 |
|---|---|---|---|---|---|---|---|---|---|
| n35-c16k | 35 | 16384 | 512 | 8706 | 8868 | 32.84 | 32.76 | 300.41 | 调优起点 |
| n34-c16k | 34 | 16384 | 512 | 9175 | 9322 | 28.51 | 33.72 | 346.5 | |
| n33-c16k | 33 | 16384 | 512 | 9266 | 9319 | 29.45 | 34.99 | 365.46 | layer 33 例外小 |
| n32-c16k | 32 | 16384 | 512 | 9399 | 9533 | 34.61 | 36.32 | 364.74 | |
| n31-c16k | 31 | 16384 | 512 | 9682 | 9702 | 30.52 | 37.19 | 380.11 | |
| n30-c16k | 30 | 16384 | 512 | 9752 | 9792 | 31.63 | 37.83 | 396.75 | |
| **n29-c16k** | 29 | 16384 | 512 | 9808 | 9880 | 36.48 | 38.61 | 403.56 | ctx=16k 局部最优 |
| n28-c16k | 28 | 16384 | 512 | 9988 | 9998 | 34.19 | 38.56 | 309.86 | ⚠️ prompt eval 衰退 |
| n29-c16k-ub1024 | 29 | 16384 | **1024** | 9983 | 10000 | 36.74 | 37.04 | 168.44 | ⚠️ ubatch 过大 |
| n27-c16k-ub256 | 27 | 16384 | **256** | 10030 | 10033 | 35.83 | 39.38 | 114.11 | ⚠️ ubatch 过小 |
| **n29-c24k** ⭐ | 29 | **24576** | 512 | 9834 | 9854 | 33.15 | **39.73** | 414.51 | **🏆 最优** |
| n29-c32k | 29 | 32768 | 512 | 9796 | 9899 | 34.41 | 39.50 | 412.3 | 性能等价，但 full-ctx OOM 风险 |

CSV 原始数据：`logs/sweep-results.csv`

### 5.3 从数据中学到的事实

1. **gen tok/s 单调随 N 下降**（35→29）：CPU expert 是瓶颈，多推一层 expert 到 GPU 直接提速
2. **N=28 是性能拐点**：gen 不再涨（38.56 ≈ 38.61），但 prompt eval 暴跌（404 → 310）。VRAM 9998 / 10240 时 compute buffer 与 KV 争用，触发 GPU 内调度抖动
3. **ubatch 是凸函数**：512 是甜点，1024 和 256 都崩 prompt eval
4. **ctx 几乎免费**：从 16384 → 32768 KV 只多 ~100 MB（GQA + q8_0 的功劳）
5. **layer 33 的 expert 比一般层小**：N=33→32 VRAM 跳 +91 MB 而非 +475。原因未深究，可能是 Qwen3 在某些层用不同 expert 数或 hybrid 与 SSM 交替
6. **GPU 利用率长期 30-50%**：说明 GPU 没饱和，CPU expert 计算才是慢的部分

---

## 6. 调参 Playbook — 何时/如何调整

### 6.1 触发条件 → 应对

| 症状 | 原因猜测 | 应对 |
|---|---|---|
| 启动时 `out of memory` / `failed to allocate` | VRAM 不够 | `--n-cpu-moe` +1（释放 ~475 MB）或 `-c` 减半 |
| 启动成功但 prompt eval < 200 tok/s（长 prompt） | VRAM 边界，compute buffer 争用 | 同上：N+1 |
| gen tok/s < 30（之前正常） | 后台进程抢 GPU；模型不在 RAM cache 中 | 查 nvidia-smi compute apps；重启 server 让 mmap 重新预热 |
| RAM 用满 / Windows 卡顿 | 桌面应用 + 模型 mmap 共占 64GB | 关闭非必要应用；考虑切换到 IQ4_XS (17.7 GB) |
| 想跑长 prompt（>20k tokens） | 当前 c=24576 已 OK；c=32768 满 ctx 边界 | 把 N 回退到 30，再设 `-c 32768`，留 ~150 MB compute buffer 余量 |
| 需要更高质量回答 | 量化损失 / KV 量化损失 | KV 改 `--cache-type-k f16 --cache-type-v f16`（+150 MB VRAM）；或换 UD-Q5_K_M 模型（+4.4 GB RAM） |

### 6.2 不同硬件下的起点

如果未来换显卡：

| GPU | 推荐起点 |
|---|---|
| RTX 3080 10GB（当前） | N=29 c=24576 |
| RTX 4070 Ti 12GB | N=23 c=32768，估计可加 5 层 expert |
| RTX 4090 / 5090 24GB | `--n-cpu-moe 0`（所有 expert 到 GPU），c=65536+ |
| RTX 3060 12GB | N=24 c=16384（更多 VRAM 但带宽弱，可能不如 3080） |
| Mac M3 Max 36-128GB | 用 Metal build，全权重 RAM/统一内存 |

如果未来换 CPU：

| CPU 类别 | -t 调整 |
|---|---|
| Intel 12/13/14 代有 P+E core | `-t <P-core 数> -tb <P-core 数>`，避开 E-core |
| AMD Ryzen 7/9 X3D | `-t 6` 或 `-t 8`（缓存敏感，少线程往往更好） |
| 纯 P-core 或 server CPU | `-t <物理核数>` |

### 6.3 提速最后一公里（如果还想榨）

按性价比排序：
1. **关闭其它 GPU 占用**：浏览器、IDE、Discord webrtc、Dropbox 缩略图... 每释放 200 MB VRAM 可以让 N 再减 0.5 层
2. **跑 llama-bench 找精确瓶颈**：`bin\llama-bench.exe -m <gguf path>` 可以测 pp/tg 在不同 batch size 下的曲线
3. **试 b9300+ 版本**：llama.cpp 更新频繁，CUDA kernel 优化经常带来 5-15% 提升
4. **关 thinking 模式**：很多对话场景用 `enable_thinking=false` 直接出答案，省 token 等于省时间
5. **streaming 输出**：`stream: true` 不能提升 tok/s，但 user-perceived latency 大幅下降

---

## 7. 故障排查

### 7.1 启动失败

```
症状：脚本运行后没有 "server is listening" 出现
```

按顺序检查：
1. `nvidia-smi` 是否能跑（driver 健康）
2. `<repo-root>\bin\llama-server.exe --version` 应输出 `version: 9294 ...`
3. `<repo-root>\models\models--unsloth--Qwen3.6-35B-A3B-GGUF\blobs\` 下是否有 22 GB 主权重文件
4. 看 `logs\server-*.log` 最后几行：
   - `out of memory` → 见 §6.1
   - `model file not found` → 检查 `$env:LLAMA_CACHE`，可能写 C 盘了
   - `cublas` / `cudart` 缺失 → 重新解压 `cudart-llama-bin-win-cuda-12.4-x64.zip` 到 bin\
5. 防火墙弹窗：第一次可能要批准 llama-server.exe 监听 127.0.0.1

### 7.2 模型下载失败

`-hf` 拉模型走 HF Hub。如果网络不行：
- 临时方案：手动下载 GGUF 文件，放到 `<repo-root>\models\manual\` 下，把启动命令的 `-hf` 改成 `-m <绝对路径>`
- 走代理：`$env:HTTPS_PROXY = 'http://127.0.0.1:7890'` 然后再启动

### 7.3 响应内容为空

90% 是 Qwen3 thinking mode 把 token 全用在 reasoning_content。
- 看 JSON：`message.reasoning_content` 长，`message.content` 空 → 确认
- 解决：请求加 `chat_template_kwargs: {enable_thinking: false}`
- 或加大 `max_tokens >= 1024`（典型 thinking 用 ~200-800 tokens）

### 7.4 性能突然衰退

可能原因（按概率）：
1. **其它进程抢 GPU**：`nvidia-smi --query-compute-apps=pid,process_name --format=csv` 找出来杀掉
2. **VRAM 满了，进入 thrashing**：重启 server；如经常发生说明配置太激进，N+1
3. **Windows 后台扫描 / Defender**：模型 mmap 文件被扫，磁盘 I/O 阻塞 expert 计算
4. **温度墙**：长时间满载后 GPU/CPU 降频；检查 GPU 温度，3080 风扇曲线是否正常

### 7.5 长时间运行后 VRAM 漂移变高

**症状**：刚启动 server idle 9834 MiB，跑了几小时后 idle 升到 9950+ MiB，余量从 ~400 MB 缩到 ~100 MB。

**原因**：llama.cpp 在多次推理后会累积 sampler/HTTP worker 内部缓存。即使 `--parallel 1` 也会有 ~100-200 MiB 增长。**这是正常行为**，不是环境异常。

**验证方法**：`qwen stop` 后看 nvidia-smi — 桌面应用真实占用大约只有 700 MiB。如果 stop 后仍占 >1.5 GiB，那才是有其它进程抢 GPU。

**应对**：
- 一周或数十次推理后 `qwen restart` 一次，恢复初始 idle
- 或长期跑 `qwen start -Profile safe`（N=31）多留 200+ MB 余量吸收漂移
- 不要去删 `--n-cpu-moe`，单调 N 不能阻止累积

---

## 8. 运维操作（使用 `qwen` 统一管理器）

### 8.1 启动
```powershell
qwen start                           # balanced (默认)
qwen start -Profile safe             # 切 profile
qwen start -NCpuMoe 30 -Ctx 16384    # 单参数覆盖
qwen start -Background               # 后台运行（脱离当前终端）
```
前台启动会把日志同时打到屏幕和 `logs\server-YYYYMMDD-HHMMSS.log`，Ctrl+C 退出。后台启动返回后用 `qwen status` 查 PID。

环境变量 `LLAMA_CACHE` 由脚本内部自动设置为 `<repo-root>\models`，**不需要手动 export**。

### 8.2 停止 / 重启
```powershell
qwen stop
qwen restart -Profile longctx        # 停后用新 profile 重启
```

### 8.3 查状态
```powershell
qwen status
# 输出: PID / 启动时间 / 上线时长 / CPU 时间 / 进程内存 / GPU 占用 / endpoint
```

### 8.4 健康检查
```powershell
qwen health
# 输出: 一次 chat completion 的 wall_time / gen tok/s / prompt tok/s / 回复内容
```
低于 30 gen tok/s 通常说明配置异常或 VRAM 不足在 thrashing。

### 8.5 预览参数（不启动）
```powershell
qwen config -Profile longctx -NCpuMoe 28
# 显示将要使用的参数 + 估算 idle VRAM + margin/warning
```
非常适合实验新组合前先看看会不会 OOM。

### 8.6 监控资源（后台采样）
```powershell
& "<repo-root>\scripts\perf-monitor.ps1" -DurationSec 60
```
2s 采样 VRAM/RAM/GPU 利用率，结果到 `logs\perf-*.csv`。

### 8.7 重新跑 sweep
```powershell
$results = @()
$results += & "<repo-root>\scripts\bench-config.ps1" -NCpuMoe 29 -Ctx 24576 -Label "current"
# 重复添加不同参数
$results | Export-Csv "<repo-root>\logs\custom-sweep.csv" -NoTypeInformation
```

### 8.8 `qwen` 命令的实现位置（卸载用）
- 脚本本体：`<repo-root>\scripts\qwen.ps1`
- alias 定义：用户 PowerShell profile（`$PROFILE`）中的 `Set-Alias qwen ...` 行。删掉这行即可去除 `qwen` 命令。

---

## 9. 集成 / 客户端用法

### 9.0 两种运行模式

| 模式 | 启动 | 监听地址 | 鉴权 | 谁能访问 |
|---|---|---|---|---|
| **本机** (默认) | `qwen start` | `127.0.0.1:8080` | 无 | 仅 Windows 主机本机 |
| **LAN/WSL** | `qwen start -Lan` | `0.0.0.0:8080` | **api-key 必需** | Windows 主机 + 同 LAN 设备 + WSL（需防火墙） |

启动 `-Lan` 模式会：
- 首次运行自动生成 api-key → `<repo-root>\.apikey`（仅当前用户可读写）
- 传 `--api-key-file` 给 llama-server（key 不出现在进程命令行里）
- 尝试创建 Windows 防火墙规则（需要 admin，失败会打印一行命令让你手动跑一次）

⚠️ **api-key 只检查 `/v1/chat/completions` 等推理端点**，`/v1/models` 不需 key — 这是 llama.cpp 默认行为，正常。

### 9.1 Endpoint

| 来源 | 模式 | URL | Header |
|---|---|---|---|
| Windows 主机本机 | 任意 | `http://127.0.0.1:8080/v1` | `Authorization: Bearer <key>` (LAN 模式) |
| WSL 里 | -Lan | `http://<LAN-IP>:8080/v1` | `Authorization: Bearer <key>` |
| LAN 上 SSH 进的无头机 | -Lan | `http://<LAN-IP>:8080/v1` | `Authorization: Bearer <key>` |
| 公网 | — | **不要暴露**，没强化 |

Model name: `qwen3.6-35b-a3b`（由 `--alias` 设定）。

### 9.2 Python (openai SDK)
```python
from openai import OpenAI

client = OpenAI(
    base_url='http://127.0.0.1:8080/v1',
    api_key='not-needed',  # llama-server 不验，但 SDK 要求非空
)

# 关 thinking 的推荐用法
resp = client.chat.completions.create(
    model='qwen3.6-35b-a3b',
    messages=[{'role': 'user', 'content': '你好'}],
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
    "messages": [{"role":"user","content":"你好"}],
    "max_tokens": 1024,
    "chat_template_kwargs": {"enable_thinking": false}
  }'
```

### 9.4 Continue / Cline / Aider 等 IDE 插件
配置项一般是：
- `apiBase` 或 `OPENAI_API_BASE`: `http://127.0.0.1:8080/v1`
- `apiKey` 或 `OPENAI_API_KEY`: `dummy`（任意非空字符串）
- `model`: `qwen3.6-35b-a3b`

### 9.5 多模态（图像输入）

模型本身是多模态 (Image-Text-to-Text)，但默认 profile 不加载视觉编码器以保最大 gen 速度。需要图像时切换：

```powershell
qwen restart -Profile vision           # 本机 vision
qwen restart -Profile vision -Lan      # 暴露给 LAN/WSL
```

**mmproj 文件**：`<repo-root>\mmproj\mmproj-BF16.gguf` (861 MB on disk)

**实测开销**（N=35 c=16384 + mmproj-BF16）：
- idle VRAM ~7700 MiB（比纯文本 N=35 的 8700 还低 — mmproj 占的比预估少）
- 单张 1.5 MB JPEG → 编码为 4022 prompt tokens
- wall_time ~20s（含图像编码 + 短回答）
- gen tok/s ~36（与 N=35 文本模式接近）

**调用示例 (Python)**：

```python
from openai import OpenAI
import base64, os

img_b64 = base64.b64encode(open('test.jpg','rb').read()).decode()
client = OpenAI(base_url='http://127.0.0.1:8080/v1', api_key='not-needed')  # 或 LAN URL/Bearer

resp = client.chat.completions.create(
    model='qwen3.6-35b-a3b',
    messages=[{
        'role': 'user',
        'content': [
            {'type': 'image_url', 'image_url': {'url': f'data:image/jpeg;base64,{img_b64}'}},
            {'type': 'text', 'text': '描述这张图片。'}
        ]
    }],
    extra_body={'chat_template_kwargs': {'enable_thinking': False}},
    max_tokens=512,
)
print(resp.choices[0].message.content)
```

**curl 示例**（base64 直接嵌入）：

```bash
B64=$(base64 -w0 test.jpg)
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{
    \"model\":\"qwen3.6-35b-a3b\",
    \"messages\":[{\"role\":\"user\",\"content\":[
      {\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/jpeg;base64,$B64\"}},
      {\"type\":\"text\",\"text\":\"描述这张图片。\"}
    ]}],
    \"max_tokens\":512
  }"
```

**注意事项**：
- 切换 profile 需要 `qwen restart`（不能在线热切，mmproj 是启动时绑定的）
- 一张 1024×1024 图像通常占 1000–2000 tokens；高分辨率图占用更多 prompt tokens（计入 ctx）
- `--image-min-tokens` / `--image-max-tokens` 可控制图像 token 数上下限（默认让模型自适应）
- vision profile 下文本对话不变快（gen ~36 tok/s vs balanced 40 tok/s），代价就是这 4 个 tok/s

### 9.6 远程接入完整步骤

**1. Windows 主机一次性准备**（首次设 LAN 模式）

```powershell
# 1. 启动 LAN 模式（会自动生成 api-key 并尝试建防火墙规则）
qwen start -Lan -Background

# 2. 如果输出中提示防火墙创建失败，开个 admin pwsh 跑一次：
#    （或在普通 pwsh 里：Start-Process pwsh -Verb RunAs）
New-NetFirewallRule -DisplayName 'Qwen llama-server (Private LAN)' `
  -Direction Inbound -Action Allow `
  -Protocol TCP -LocalPort 8080 -Profile Private `
  -Program '<repo-root>\bin\llama-server.exe'

# 3. 把 key 复制出来传给客户端
Get-Content '<repo-root>\.apikey'
```

**2. WSL 客户端**（同一台 Windows 主机）

```bash
# 设环境变量（推荐写到 ~/.bashrc 或 ~/.zshrc）
export QWEN_KEY=$(cat /mnt/<drive>/path/to/local-qwen/.apikey 2>/dev/null \
                  || echo '<paste key here>')
export QWEN_URL='http://<LAN-IP>:8080/v1'

# 测试
curl -s -H "Authorization: Bearer $QWEN_KEY" $QWEN_URL/models | jq .

# Python (openai SDK)
python3 - <<'EOF'
import os
from openai import OpenAI
client = OpenAI(base_url=os.environ['QWEN_URL'], api_key=os.environ['QWEN_KEY'])
resp = client.chat.completions.create(
    model='qwen3.6-35b-a3b',
    messages=[{'role':'user','content':'你好'}],
    extra_body={'chat_template_kwargs':{'enable_thinking':False}},
    max_tokens=1024,
)
print(resp.choices[0].message.content)
EOF
```

**3. LAN 上 SSH 进入的无头服务器**

把 key 复制过去（一次性，比如 `scp` 或贴进 `~/.bashrc`），其余同 WSL：

```bash
# 在无头服务器上
echo 'export QWEN_KEY="<paste key>"' >> ~/.bashrc
echo 'export QWEN_URL="http://<LAN-IP>:8080/v1"' >> ~/.bashrc
source ~/.bashrc

# 测试
curl -s -H "Authorization: Bearer $QWEN_KEY" $QWEN_URL/models
```

**4. 切回本机模式**（停止 LAN 暴露）

```powershell
qwen restart  # 不带 -Lan 就回到 127.0.0.1，api-key 文件保留但不再被使用
```

防火墙规则保留无害（程序停了就 inbound 没意义）。要彻底删：

```powershell
Remove-NetFirewallRule -DisplayName 'Qwen llama-server (Private LAN)'   # 需 admin
```

要重新生成 api-key（旧的泄露了等场景）：

```powershell
Remove-Item '<repo-root>\.apikey'
qwen restart -Lan -Background   # 下次启动会建新的
```

### 9.7 ⚠️ Qwen3 Thinking Mode 必知

模型默认会先生成 reasoning（写到 `message.reasoning_content`）再写答案。处理选项：

| 场景 | 设置 |
|---|---|
| 需要短而快的回答（chat、code completion） | `chat_template_kwargs: {enable_thinking: false}` |
| 需要复杂推理（数学、调试） | 保持默认，但 `max_tokens >= 1024` 留 thinking 预算 |
| 客户端不支持 reasoning_content | 设 `--reasoning-format none`（启动 server 时），把 thinking 合到 content 中 |

---

## 10. 维护例行操作

### 10.1 更新 llama.cpp（推荐 1-3 月一次）

```powershell
# 看新版本：访问 https://github.com/ggml-org/llama.cpp/releases
$ver = 'b9500'  # 改成最新 build
$urls = @(
  "https://github.com/ggml-org/llama.cpp/releases/download/$ver/llama-$ver-bin-win-cuda-12.4-x64.zip"
  "https://github.com/ggml-org/llama.cpp/releases/download/$ver/cudart-llama-bin-win-cuda-12.4-x64.zip"
)
# 备份
Copy-Item '<repo-root>\bin' '<repo-root>\bin.old' -Recurse
# 下载并解压（参考初始安装步骤）
foreach ($u in $urls) {
  $f = "<repo-root>\dl\$([System.IO.Path]::GetFileName($u))"
  Invoke-WebRequest $u -OutFile $f
  Expand-Archive $f '<repo-root>\bin' -Force
}
# 验证
& '<repo-root>\bin\llama-server.exe' --version
```

升级后先跑 `healthcheck.ps1`。**如果 gen tok/s 显著退化**：回滚 `bin.old`，可能新版本动了 kernel 或 flag 默认值。

### 10.2 更新模型

unsloth 的 GGUF 仓库会随上游 Qwen 修复迭代。重新拉：
```powershell
# 删旧缓存
Remove-Item '<repo-root>\models\models--unsloth--Qwen3.6-35B-A3B-GGUF' -Recurse -Force
# 重新启动 server，-hf 会自动拉新版
& "<repo-root>\scripts\run-qwen36-35b-a3b.ps1"
```

### 10.3 备份必要文件

如果重装系统，需要备份：
- ✅ `<repo-root>\scripts\` （脚本）
- ✅ `<repo-root>\HANDBOOK.md` `TUNING-REPORT.md` `FINAL-REPORT.md`
- ✅ `<repo-root>\logs\sweep-results.csv`
- ⚠️ `<repo-root>\models\` （22 GB，可重下也可备份省时间）
- ⚠️ `<repo-root>\bin\` （620 MB，可重下，无版本问题）

模型 + 二进制重下大约 5-15 分钟（取决于网速）。

---

## 11. 安全 / 隐私 提醒

- 默认仅监听 `127.0.0.1`，无法从外网访问 ✓
- 没有 API key 鉴权 — 不要绑 0.0.0.0 或转发端口
- 模型权重在本地，**所有对话内容不会发送到外部** ✓
- 日志 `logs/server-*.log` 不记录用户输入，只记录系统/性能信息
- `logs/03-health-check.json`、`logs/bench-*.json` 包含 benchmark 用的测试 prompt，可放心删除

---

## 12. 时间线（决策记录）

| 阶段 | 配置 | gen tok/s | ctx | 决策动机 |
|---|---|---|---|---|
| 1 | Vulkan b9294 默认 | 未测 | 8192 | winget 默认装的 Vulkan，确认能用但非最优 |
| 2 | CUDA 12.4 + q8_0 KV + `--cpu-moe` | 25.73 | 8192 | 改用 GitHub CUDA 包；q4_0→q8_0 提升 KV 质量；MoE 全 CPU 起点稳 |
| 3 | `--n-cpu-moe 35` | 27.48 | 8192 | 用户提议；先验地以为 30B-A3B 是 48 层，35 = 12 层 GPU；实际发现是 40 层 |
| 4 | ctx 8192 → 16384 | 32.84 | 16384 | KV 翻倍 VRAM 影响小，长 ctx 价值大 |
| 5 | 全 sweep N=34→27, ub=256/512/1024 | — | — | 系统化探索，找拐点 |
| 6 | **N=29 c=24576** ⭐ | **39.73** | **24576** | sweep 最优；N=28 prompt eval 衰退；c=32k vs 24k 速度相同但 full-ctx 风险大 |

**从最初基线到最优配置的整体提升：gen +54%，ctx 3x。**

---

## 13. 附录：原始 sweep 数据

见同目录 `logs/sweep-results.csv`。
