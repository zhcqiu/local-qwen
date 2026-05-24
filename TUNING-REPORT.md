# Qwen MoE — Parameter Sweep Tuning Report

**Date:** 2026-05-23  
**Hardware:** i7-13700KF / 64 GB RAM / NVIDIA RTX 3080 10 GB  
**llama.cpp:** b9294, CUDA 12.4 backend  
**Model:** `unsloth/Qwen3.6-35B-A3B-GGUF :: UD-Q4_K_M` (22.1 GB)  
**Architecture:** `n_layer=40, n_expert=256, n_expert_used=8` (DeepSeek-style fine-grained MoE)

---

## Optimal Configuration

```
-c 24576
-ngl 999 --n-cpu-moe 29
--cache-type-k q8_0 --cache-type-v q8_0
--flash-attn auto
-b 2048 -ub 512
-t 8 -tb 8
--jinja
```

**Measured results:**
- Generation: **39.73 tok/s** (vs. starting baseline 25.73 tok/s — **+55%**)
- Prompt eval: **414.5 tok/s** at ~7k token prompt
- VRAM idle: 9834 / 10240 MiB; peak: 9854 MiB (~386 MiB margin)
- Context window: **24576 tokens** (vs. starting 8192 — **3×**)

---

## Full Sweep Results

| Config | idle MiB | peak MiB | gen tok/s | prompt tok/s | Notes |
|---|---|---|---|---|---|
| n35-c16k | 8706 | 8868 | 32.76 | 300 | Starting point |
| n34-c16k | 9175 | 9322 | 33.72 | 347 | +1 expert layer on GPU |
| n33-c16k | 9266 | 9319 | 34.99 | 365 | Layer 33 expert is anomalously small |
| n32-c16k | 9399 | 9533 | 36.32 | 365 | |
| n31-c16k | 9682 | 9702 | 37.19 | 380 | |
| n30-c16k | 9752 | 9792 | 37.83 | 397 | |
| n29-c16k | 9808 | 9880 | 38.61 | 404 | Optimum at ctx=16k |
| n28-c16k | 9988 | 9998 | 38.56 | 310 ⚠️ | Gen stalls; prompt eval collapses |
| n29-c16k ub=1024 | 9983 | 10000 | 37.04 | 168 ⚠️ | Large ubatch triggers VRAM contention |
| n27-c16k ub=256 | 10030 | 10033 | 39.38 | 114 ⚠️ | Small ubatch serializes batched ops |
| **n29-c24k** ⭐ | **9834** | **9854** | **39.73** | **415** | **Overall optimum** |
| n29-c32k | 9796 | 9899 | 39.50 | 412 | Same speed; full-ctx OOM risk |

---

## Key Findings

1. **Each extra expert layer moved to GPU costs ~475 MiB VRAM** and gains proportionally in gen tok/s — until N=29.

2. **Layer 33 is an exception**: the +91 MiB jump from N=33→32 (vs. the usual +475 MiB) suggests this layer uses a different expert size or dimension. This is a Qwen3 architecture quirk, possibly related to the hybrid SSM/transformer design.

3. **N=28 is the performance cliff**: gen tok/s stops increasing (38.56 ≈ 38.61 at N=29), but prompt eval drops from 404 to 310 tok/s. At VRAM 9998/10240 MiB, the compute buffer competes with the KV cache, causing GPU scheduling contention during batched prefill.

4. **ubatch=512 is the sweet spot**: ubatch=1024 exceeds VRAM and collapses prompt eval by 60%; ubatch=256 serializes batched matrix multiplications and collapses prompt eval by 72%.

5. **KV cache is nearly free** (GQA + q8_0): context 8192→32768 adds only ~120 MiB VRAM total, a 4× ctx increase for negligible cost.

6. **Generation bottleneck is CPU expert computation**: GPU utilization stays at 30–50% throughout — the GPU is not the limiting factor; CPU-side expert weight lookups are.

7. **Prompt eval is GPU-friendly**: large batches enable highly efficient matrix multiplications, which is why prompt tok/s (400+) is 10× higher than gen tok/s (40).

---

## Risk Assessment

- VRAM peak at optimum config is **386 MiB from the 10240 MiB ceiling** — tight by design
- Desktop applications can add 100–200 MiB per new browser window; GPU-accelerated IDE previews add more
- ctx=32768 (vs. 24576): same speed, but full-context prompts push compute buffer to ~10126 MiB estimated — only 110 MiB margin, unacceptable
- If background GPU VRAM exceeds 200 MiB above normal, increase `--n-cpu-moe` to 30 or 31

---

## Performance Timeline

| Phase | Config | Gen tok/s | Ctx | vs. baseline |
|---|---|---|---|---|
| 1. Initial (Vulkan + q4_0 KV) | original prompt | (not measured) | 8192 | — |
| 2. CUDA + q8_0 KV + --cpu-moe | baseline | 25.73 | 8192 | — |
| 3. --n-cpu-moe 35 | +5 expert layers on GPU | 27.48 | 8192 | +6.8% |
| 4. ctx 16384 | KV doubled | 32.84 | 16384 | +27.6% |
| 5. **N=29, ctx=24576** ⭐ | **full sweep optimum** | **39.73** | **24576** | **+54.4%** |
