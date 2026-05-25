# Restart llama-server with given config, run short + long prompt benchmark,
# capture peak VRAM. Returns object with all metrics.
# Usage: .\bench-config.ps1 -NCpuMoe 34 -Ctx 16384 -UbatchSize 512 -Label "n34-c16k"
# Model is resolved from models.json (override with -Model <id> or $env:QWEN_MODEL).
#
# Safe-by-default: this script will NOT kill any pre-existing process. If port 8080 is
# busy, it aborts. Use -KillExisting to forcibly stop the PID that owns the bench port
# (only that one PID, never a blanket name-based kill). The llama-server started by
# this run is always stopped on exit.

param(
  [Parameter(Mandatory)] [int]$NCpuMoe,
  [Parameter(Mandatory)] [int]$Ctx,
  [int]$UbatchSize = 512,
  [int]$BatchSize  = 2048,
  [string]$Label,
  [string]$Model,
  [int]$Port = 8080,
  [switch]$KillExisting
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_lib.ps1"

$ModelCfg = Resolve-Model -Explicit $Model
$Alias    = $ModelCfg.alias

if (-not $Label) { $Label = "$($ModelCfg.id)-n${NCpuMoe}-c${Ctx}-ub${UbatchSize}" }

$Root = Get-RepoRoot
$Bin  = "$Root\bin"
$Logs = "$Root\logs"
$ExePath = "$Bin\llama-server.exe"
$env:LLAMA_CACHE = "$Root\models"

Write-Host "[bench:$Label] model=$($ModelCfg.id) hf=$($ModelCfg.hf)" -ForegroundColor DarkGray

# Pre-flight: port collision check. Only act on the specific PID bound to $Port — never
# kill processes by name (would clobber unrelated llama-server instances from other repos).
$listen = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
if ($listen) {
  $owningPid = $listen.OwningProcess
  $owningProc = Get-Process -Id $owningPid -ErrorAction SilentlyContinue
  $name = if ($owningProc) { $owningProc.ProcessName } else { '?' }
  if ($KillExisting) {
    Write-Host "[bench:$Label] -KillExisting: stopping PID $owningPid ($name) on port $Port" -ForegroundColor Yellow
    if ($owningProc) {
      $owningProc | Stop-Process -Force
      $deadline = (Get-Date).AddSeconds(10)
      while ((Get-Date) -lt $deadline -and (Get-Process -Id $owningPid -ErrorAction SilentlyContinue)) {
        Start-Sleep -Milliseconds 200
      }
    }
    Start-Sleep -Seconds 2
  } else {
    throw "Port $Port is already bound by PID $owningPid ($name). Stop it manually, or re-run with -KillExisting."
  }
}

$stamp = Get-Date -Format 'HHmmss'
$srvLog = "$Logs\bench-$Label-$stamp.log"

Write-Host "[bench:$Label] starting llama-server: n_cpu_moe=$NCpuMoe ctx=$Ctx ub=$UbatchSize b=$BatchSize" -ForegroundColor Cyan
$args = @(
  '-hf', $ModelCfg.hf,
  '--alias', $Alias,
  '--host', '127.0.0.1', '--port', $Port,
  '-c', $Ctx,
  '-ngl', '999', '--n-cpu-moe', $NCpuMoe,
  '--flash-attn', 'auto',
  '--cache-type-k', 'q8_0', '--cache-type-v', 'q8_0',
  '-t', '8', '-tb', '8',
  '-b', $BatchSize, '-ub', $UbatchSize,
  '--jinja', '--parallel', '1'
)
$proc = Start-Process -FilePath $ExePath -ArgumentList $args -RedirectStandardOutput $srvLog -RedirectStandardError "$srvLog.err" -PassThru -WindowStyle Hidden
$benchPid = $proc.Id  # only this PID will be stopped on cleanup

# Wait for ready (or fail)
$deadline = (Get-Date).AddSeconds(120)
$ready = $false; $err = $null
while ((Get-Date) -lt $deadline) {
  if ($proc.HasExited) { $err = "process exited code=$($proc.ExitCode)"; break }
  $content = ''
  if (Test-Path $srvLog) { $content = Get-Content $srvLog -Raw -ErrorAction SilentlyContinue }
  if (Test-Path "$srvLog.err") { $content += "`n" + (Get-Content "$srvLog.err" -Raw -ErrorAction SilentlyContinue) }
  if ($content -match 'server is listening') { $ready = $true; break }
  if ($content -match '(?i)out of memory|cuda error|failed to allocate|cannot allocate|ggml_assert') {
    $err = "load failed (OOM/CUDA error)"; break
  }
  Start-Sleep -Milliseconds 500
}
function Stop-BenchServer {
  param([int]$BenchPid)
  if (-not $BenchPid) { return }
  $p = Get-Process -Id $BenchPid -ErrorAction SilentlyContinue
  if (-not $p) { return }
  $p | Stop-Process -Force -ErrorAction SilentlyContinue
  $deadline = (Get-Date).AddSeconds(10)
  while ((Get-Date) -lt $deadline -and (Get-Process -Id $BenchPid -ErrorAction SilentlyContinue)) {
    Start-Sleep -Milliseconds 200
  }
}

if (-not $ready) {
  Write-Host "[bench:$Label] FAILED: $err" -ForegroundColor Red
  Stop-BenchServer -BenchPid $benchPid
  return [pscustomobject]@{
    label=$Label; model_id=$ModelCfg.id; n_cpu_moe=$NCpuMoe; ctx=$Ctx; ubatch=$UbatchSize; batch=$BatchSize
    loaded=$false; error=$err
  }
}

# Everything past this point may throw (nvidia-smi missing, REST timeout, Start-Job failure,
# JSON access on a null response, etc.). The finally block must always reach Stop-BenchServer
# so a failed bench never leaks the heavyweight llama-server process or holds the port.
$vramSampler = $null
$result = $null
try {
  # Capture idle VRAM
  Start-Sleep -Seconds 2
  $idleVram = ((nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits) -as [int])

  # Short prompt benchmark
  $short = @{
    model=$Alias
    messages=@(@{role='user';content='用中文用三句话解释 MoE 模型为什么适合消费级显卡本地运行。'})
    temperature=0.3; max_tokens=256; stream=$false
    chat_template_kwargs=@{enable_thinking=$false}
  } | ConvertTo-Json -Depth 10 -Compress
  $r1 = Invoke-RestMethod "http://127.0.0.1:$Port/v1/chat/completions" -Method Post -ContentType 'application/json' -Body $short

  # Long prompt — ~8000 tokens to stress compute buffer
  $filler = ("MoE 模型在大语言模型领域是一种重要的稀疏激活架构设计，它通过将庞大的参数空间划分为多个独立的专家网络，并在推理时由路由器动态选择少数几个专家进行计算，从而在保持总参数量巨大的同时显著降低单次前向传播的算力开销。这种设计特别适合内存带宽和计算能力受限的消费级硬件环境。" * 100)
  $long = @{
    model=$Alias
    messages=@(@{role='user';content=$filler + "`n`n请用中文用三句话总结。"})
    temperature=0.3; max_tokens=128; stream=$false
    chat_template_kwargs=@{enable_thinking=$false}
  } | ConvertTo-Json -Depth 10 -Compress

  # Sample VRAM during long prompt
  $vramSampler = Start-Job -ScriptBlock {
    $peak = 0
    for ($i=0; $i -lt 60; $i++) {
      $v = (nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits) -as [int]
      if ($v -gt $peak) { $peak = $v }
      Start-Sleep -Milliseconds 500
    }
    return $peak
  }
  $t0 = Get-Date
  $r2 = $null; $longErr = $null
  try {
    $r2 = Invoke-RestMethod "http://127.0.0.1:$Port/v1/chat/completions" -Method Post -ContentType 'application/json' -Body $long -TimeoutSec 600
  } catch {
    $longErr = $_.Exception.Message
  }
  $wall2 = ((Get-Date) - $t0).TotalSeconds
  $peakVram = $vramSampler | Receive-Job -Wait
  $vramSampler = $null   # consumed

  $result = [pscustomobject]@{
    label       = $Label
    model_id    = $ModelCfg.id
    n_cpu_moe   = $NCpuMoe
    ctx         = $Ctx
    ubatch      = $UbatchSize
    batch       = $BatchSize
    loaded      = $true
    idle_vram   = $idleVram
    peak_vram   = $peakVram
    short_prompt_tok        = $r1.usage.prompt_tokens
    short_gen_tok           = $r1.usage.completion_tokens
    short_prompt_tok_per_s  = [math]::Round($r1.timings.prompt_per_second,2)
    short_gen_tok_per_s     = [math]::Round($r1.timings.predicted_per_second,2)
    long_loaded             = ($null -eq $longErr)
    long_error              = $longErr
    long_prompt_tok         = if ($r2) { $r2.usage.prompt_tokens } else { $null }
    long_gen_tok            = if ($r2) { $r2.usage.completion_tokens } else { $null }
    long_prompt_tok_per_s   = if ($r2) { [math]::Round($r2.timings.prompt_per_second,2) } else { $null }
    long_gen_tok_per_s      = if ($r2) { [math]::Round($r2.timings.predicted_per_second,2) } else { $null }
    long_wall_s             = [math]::Round($wall2,2)
  }
} finally {
  if ($vramSampler) {
    Remove-Job -Job $vramSampler -Force -ErrorAction SilentlyContinue
  }
  # Always stop the llama-server this script started — never any other PID.
  Stop-BenchServer -BenchPid $benchPid
}

return $result
