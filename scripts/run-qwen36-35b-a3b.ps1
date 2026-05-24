# Qwen3.6-35B-A3B local launcher (Windows native, CUDA 12.4 backend)
# Hardware: i7-13700KF / 64GB DDR / RTX 3080 10GB
# Model:    unsloth/Qwen3.6-35B-A3B-GGUF :: UD-Q4_K_M (~22.1 GB)

$ErrorActionPreference = 'Stop'

$Root    = Split-Path -Parent $PSScriptRoot
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
"llama-server: $Bin\llama-server.exe" | Out-File $LogFile -Append -Encoding utf8
(& "$Bin\llama-server.exe" --version 2>&1) | Out-File $LogFile -Append -Encoding utf8
"" | Out-File $LogFile -Append -Encoding utf8
"--- nvidia-smi snapshot ---" | Out-File $LogFile -Append -Encoding utf8
(nvidia-smi 2>&1) | Out-File $LogFile -Append -Encoding utf8
"" | Out-File $LogFile -Append -Encoding utf8
"--- Launch params ---" | Out-File $LogFile -Append -Encoding utf8

# Optimized launch parameters
#  -ngl 999            : send every layer to GPU (non-expert tensors)
#  --n-cpu-moe 29      : model has 40 layers / 256 experts / top-8.
#                        Layers 0-28 keep experts on CPU/RAM, layers 29-39 push
#                        experts (11 layers) onto GPU. Found via full sweep —
#                        N=28 starts thrashing compute buffer; N>29 leaves
#                        speed on the table. Measured +20% gen tok/s vs the
#                        starting --cpu-moe config.
#  --flash-attn auto   : Ampere supports FA
#  -ctk q8_0 -ctv q8_0 : q8_0 KV — Qwen GQA keeps KV small even at 24k
#  -c 24576            : context (model native is 262144). At N=29+ctx=24576
#                        VRAM idle ~9.8 GB, peak under 7k prompt ~9.9 GB.
#                        ctx can go to 32768 with the same VRAM, but 32k full
#                        prompts may push compute buffer over the edge.
#  -t 8 -tb 8          : 8 P-cores only; E-cores hurt MoE expert math
#  -b 2048 -ub 512     : default batch sizes — sweep showed ub=1024 thrashes,
#                        ub=256 kills prompt eval
#  --jinja             : use Qwen native chat template
$LlamaArgs = @(
  '-hf', 'unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_M',
  '--alias', 'qwen3.6-35b-a3b',
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

Write-Host "Launching llama-server (CUDA 12.4)..." -ForegroundColor Green
Write-Host "Log: $LogFile" -ForegroundColor DarkGray
Write-Host "Endpoint: http://127.0.0.1:8080" -ForegroundColor Cyan
Write-Host ""

# Redirect both stdout and stderr to the log
& "$Bin\llama-server.exe" @LlamaArgs *>&1 | Tee-Object -FilePath $LogFile -Append
