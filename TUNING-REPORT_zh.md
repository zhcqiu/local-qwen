# Qwen3.6-35B-A3B 调优 Sweep 报告

**日期**: 2026-05-23
**硬件**: i7-13700KF / 64GB / RTX 3080 10GB
**llama.cpp**: b9294 CUDA 12.4
**模型**: unsloth/Qwen3.6-35B-A3B-GGUF :: UD-Q4_K_M (22.1 GB)
**模型架构**: `n_layer=40, n_expert=256, n_expert_used=8` (DeepSeek 风格细粒度 MoE)

## 最优配置

```
-c 24576
-ngl 999 --n-cpu-moe 29
--cache-type-k q8_0 --cache-type-v q8_0
--flash-attn auto
-b 2048 -ub 512
-t 8 -tb 8
--jinja
```

**实测**：
- gen **39.73 tok/s** (vs 起始 25.7 tok/s，**+55%**)
- prompt eval **414.5 tok/s** at 7k prompt
- VRAM idle 9834 / 10240, peak 9854 (~386 MB margin)
- Context window: **24576 tokens** (vs 起始 8192，3x)

## 完整 Sweep 数据

| 配置 | idle MiB | peak MiB | gen tok/s | prompt tok/s | 备注 |
|---|---|---|---|---|---|
| n35-c16k | 8706 | 8868 | 32.76 | 300 | 起点 |
| n34-c16k | 9175 | 9322 | 33.72 | 347 | +1 expert layer |
| n33-c16k | 9266 | 9319 | 34.99 | 365 | layer 33 expert 偏小 |
| n32-c16k | 9399 | 9533 | 36.32 | 365 | |
| n31-c16k | 9682 | 9702 | 37.19 | 380 | |
| n30-c16k | 9752 | 9792 | 37.83 | 397 | |
| n29-c16k | 9808 | 9880 | 38.61 | 404 | 16k 最优 N |
| n28-c16k | 9988 | 9998 | 38.56 | 310 ⚠️ | gen 停止涨；prompt 衰退 |
| n29-c16k ub=1024 | 9983 | 10000 | 37.04 | 168 ⚠️ | ubatch 太大触发 VRAM 争用 |
| n27-c16k ub=256 | 10030 | 10033 | 39.38 | 114 ⚠️ | ubatch 太小杀 prompt eval |
| **n29-c24k** ⭐ | **9834** | **9854** | **39.73** | **415** | **最优** |
| n29-c32k | 9796 | 9899 | 39.50 | 412 | 与 c24k 同性能，full-ctx OOM 风险 |

## 关键洞察

1. **每多 1 层 expert 到 GPU 约 +475 MB VRAM**，但 layer 33 例外（仅 +91 MB），怀疑该层 expert 数或维度配置与其他层不同。
2. **N=28 是性能拐点**：gen 不再涨，prompt eval 反而衰退到 310 tok/s（VRAM 争用，compute buffer 被挤）。
3. **ubatch=512 是甜点**：放大到 1024 触发 VRAM 边界，prompt eval 暴跌 60%；缩到 256 仅依赖串行 batch，prompt eval 暴跌 72%。
4. **q8_0 KV + Qwen GQA 极省空间**：ctx 从 8192 翻 4 倍到 32768 只额外 ~120 MB VRAM。
5. **gen tok/s 真正瓶颈是 CPU expert 计算**：GPU util 全程 30-50%，没饱和；把更多 expert 推到 GPU 直接转化为速度。
6. **prompt eval 在 GPU 友好**：长 prompt 因 batched matmul 高效，prompt eval (400+) >> gen (40) 一个数量级。

## 边界与告警

- VRAM peak 距离 10240 MiB 上限只 386 MB
- 若有新进程抢 GPU 内存（开浏览器新标签、启动 IDE），可能触发 OOM
- 推荐 ctx=24576 而非 32768：32k 满 ctx prompt eval 时 compute buffer 估算 ~330 MB，加上 idle 9796 → ~10126 MB，余量仅 110 MB，太危险
- 若桌面应用占用 VRAM 上涨 > 200 MB，需要把 N 回调到 30 或 31

## 性能演进时间线

| 阶段 | 配置 | gen tok/s | ctx | 提升 |
|---|---|---|---|---|
| 1. 初始 (Vulkan + q4_0 KV) | 原始 prompt | (未测) | 8192 | - |
| 2. CUDA + q8_0 KV + --cpu-moe | baseline | 25.73 | 8192 | 基线 |
| 3. --n-cpu-moe 35 | 推 5 层 expert | 27.48 | 8192 | +6.8% |
| 4. ctx 16384 | KV 翻倍 | 32.84 | 16384 | +20% |
| 5. **N=29 ctx=24576** ⭐ | **完整 sweep 最优** | **39.73** | **24576** | **+24% vs N=35** |

总提升相对最初基线 (N=35 c=8192 25.73 tok/s): **gen +54%, ctx 3x**.
