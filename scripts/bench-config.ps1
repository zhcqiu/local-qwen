# Restart llama-server with given config, run short + long prompt benchmark,
# capture peak VRAM. Returns object with all metrics.
# Usage: .\bench-config.ps1 -NCpuMoe 34 -Ctx 16384 -UbatchSize 512 -Label "n34-c16k"

param(
  [Parameter(Mandatory)] [int]$NCpuMoe,
  [Parameter(Mandatory)] [int]$Ctx,
  [int]$UbatchSize = 512,
  [int]$BatchSize  = 2048,
  [string]$Label
)

if (-not $Label) { $Label = "n${NCpuMoe}-c${Ctx}-ub${UbatchSize}" }

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Bin  = "$Root\bin"
$Logs = "$Root\logs"
$env:LLAMA_CACHE = "$Root\models"

Write-Host "[bench:$Label] stopping any existing server" -ForegroundColor DarkGray
Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 3

$stamp = Get-Date -Format 'HHmmss'
$srvLog = "$Logs\bench-$Label-$stamp.log"

Write-Host "[bench:$Label] starting llama-server: n_cpu_moe=$NCpuMoe ctx=$Ctx ub=$UbatchSize b=$BatchSize" -ForegroundColor Cyan
$args = @(
  '-hf', 'unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_M',
  '--alias', 'qwen3.6-35b-a3b',
  '--host', '127.0.0.1', '--port', '8080',
  '-c', $Ctx,
  '-ngl', '999', '--n-cpu-moe', $NCpuMoe,
  '--flash-attn', 'auto',
  '--cache-type-k', 'q8_0', '--cache-type-v', 'q8_0',
  '-t', '8', '-tb', '8',
  '-b', $BatchSize, '-ub', $UbatchSize,
  '--jinja', '--parallel', '1'
)
$proc = Start-Process -FilePath "$Bin\llama-server.exe" -ArgumentList $args -RedirectStandardOutput $srvLog -RedirectStandardError "$srvLog.err" -PassThru -WindowStyle Hidden

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
if (-not $ready) {
  Write-Host "[bench:$Label] FAILED: $err" -ForegroundColor Red
  if ($proc -and -not $proc.HasExited) { $proc | Stop-Process -Force }
  return [pscustomobject]@{
    label=$Label; n_cpu_moe=$NCpuMoe; ctx=$Ctx; ubatch=$UbatchSize; batch=$BatchSize
    loaded=$false; error=$err
  }
}

# Capture idle VRAM
Start-Sleep -Seconds 2
$idleVram = ((nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits) -as [int])

# Short prompt benchmark
$short = @{
  model='qwen3.6-35b-a3b'
  messages=@(@{role='user';content='用中文用三句话解释 MoE 模型为什么适合消费级显卡本地运行。'})
  temperature=0.3; max_tokens=256; stream=$false
  chat_template_kwargs=@{enable_thinking=$false}
} | ConvertTo-Json -Depth 10 -Compress
$r1 = Invoke-RestMethod 'http://127.0.0.1:8080/v1/chat/completions' -Method Post -ContentType 'application/json' -Body $short

# Long prompt — ~8000 tokens to stress compute buffer
$filler = ("MoE 模型在大语言模型领域是一种重要的稀疏激活架构设计，它通过将庞大的参数空间划分为多个独立的专家网络，并在推理时由路由器动态选择少数几个专家进行计算，从而在保持总参数量巨大的同时显著降低单次前向传播的算力开销。这种设计特别适合内存带宽和计算能力受限的消费级硬件环境。" * 100)
$long = @{
  model='qwen3.6-35b-a3b'
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
  $r2 = Invoke-RestMethod 'http://127.0.0.1:8080/v1/chat/completions' -Method Post -ContentType 'application/json' -Body $long -TimeoutSec 600
} catch {
  $longErr = $_.Exception.Message
}
$wall2 = ((Get-Date) - $t0).TotalSeconds
$peakVram = $vramSampler | Receive-Job -Wait

$result = [pscustomobject]@{
  label       = $Label
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
return $result
