# Qwen3.6-35B-A3B family local launcher (Windows native, CUDA 12.4 backend).
# Hardware: i7-13700KF / 64GB DDR / RTX 3080 10GB.
# Default model: unsloth/Qwen3.6-35B-A3B-GGUF :: UD-Q4_K_M (~22.1 GB).
#
# Model is resolved from ../models.json (override with -Model <id> or $env:QWEN_MODEL).
# For day-to-day use prefer scripts\qwen.ps1 — this script keeps the bare-bones
# foreground launch with the historical sweep-optimal tuning hard-coded.

param(
  [string]$Model
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_lib.ps1"

$ModelCfg = Resolve-Model -Explicit $Model
$Root    = Get-RepoRoot
$Bin     = "$Root\bin"
$Logs    = "$Root\logs"
$Models  = "$Root\models"
$Stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogFile = "$Logs\server-$Stamp.log"

$env:PATH        = "$Bin;$env:PATH"
$env:LLAMA_CACHE = $Models

New-Item -ItemType Directory -Force -Path $Logs, $Models | Out-Null

# Pre-flight snapshot
"=== Launch $Stamp ===" | Out-File $LogFile -Encoding utf8
"model id    : $($ModelCfg.id)" | Out-File $LogFile -Append -Encoding utf8
"model hf    : $($ModelCfg.hf)" | Out-File $LogFile -Append -Encoding utf8
"model alias : $($ModelCfg.alias)" | Out-File $LogFile -Append -Encoding utf8
"llama-server: $Bin\llama-server.exe" | Out-File $LogFile -Append -Encoding utf8
(& "$Bin\llama-server.exe" --version 2>&1) | Out-File $LogFile -Append -Encoding utf8
"" | Out-File $LogFile -Append -Encoding utf8
"--- nvidia-smi snapshot ---" | Out-File $LogFile -Append -Encoding utf8
(nvidia-smi 2>&1) | Out-File $LogFile -Append -Encoding utf8
"" | Out-File $LogFile -Append -Encoding utf8
"--- Launch params ---" | Out-File $LogFile -Append -Encoding utf8

# Sweep-optimal launch parameters (Qwen3.6-35B-A3B family, n_layer=40 / 256 experts / top-8).
#   -ngl 999            : send every layer to GPU (non-expert tensors)
#   --n-cpu-moe 29      : layers 0-28 keep experts on CPU/RAM, 29-39 push experts onto GPU.
#                         Found via full sweep on unsloth UD-Q4_K_M — N=28 thrashes compute
#                         buffer; N>29 leaves speed on the table. Same architecture means
#                         this tuning carries over to HauhauCS Q4_K_M / IQ4_NL.
#   --flash-attn auto   : Ampere supports FA
#   -ctk q8_0 -ctv q8_0 : q8_0 KV (Qwen GQA keeps KV small even at 24k)
#   -c 24576            : context. Native is 262144. At N=29+ctx=24576 VRAM idle ~9.8 GB.
#   -t 8 -tb 8          : 8 P-cores only; E-cores hurt MoE expert math
#   -b 2048 -ub 512     : sweep-validated batch sizes
#   --jinja             : use native chat template
$LlamaArgs = @(
  '-hf', $ModelCfg.hf,
  '--alias', $ModelCfg.alias,
  '--host', '127.0.0.1',
  '--port', '8080',
  '-c', '24576',
  '-ngl', '999',
  '--n-cpu-moe', '29',
  '-b', '2048', '-ub', '512',
  '--flash-attn', 'auto',
  '--cache-type-k', 'q8_0',
  '--cache-type-v', 'q8_0',
  '-t', '8',
  '-tb', '8',
  '--jinja',
  '--parallel', '1'
)

"$Bin\llama-server.exe $($LlamaArgs -join ' ')" | Out-File $LogFile -Append -Encoding utf8
"" | Out-File $LogFile -Append -Encoding utf8
"--- Server output ---" | Out-File $LogFile -Append -Encoding utf8

Write-Host "Launching llama-server (CUDA 12.4) for model: $($ModelCfg.id)" -ForegroundColor Green
Write-Host "Log: $LogFile" -ForegroundColor DarkGray
Write-Host "Endpoint: http://127.0.0.1:8080" -ForegroundColor Cyan
Write-Host ""

# Redirect both stdout and stderr to the log
& "$Bin\llama-server.exe" @LlamaArgs *>&1 | Tee-Object -FilePath $LogFile -Append
