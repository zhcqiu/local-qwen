<#
.SYNOPSIS
Qwen3.6-35B-A3B 本地 llama-server 统一管理器。

.DESCRIPTION
管理本地 llama.cpp server 的生命周期（启动/停止/重启/状态/健康检查），支持预设 profile 和单参数覆盖。

.PARAMETER Action
要执行的操作：
  start    启动 server（默认；如已在运行则报错，要重启用 restart）
  stop     停止 server
  restart  停止后重启（用最新参数或当前 profile）
  status   查看运行状态、PID、VRAM 占用
  health   发一个测试请求，报告 gen tok/s
  config   仅打印将要使用的参数，不启动
  help     显示用法

.PARAMETER Profile
预设组合：
  safe       N=31, ctx=16384 — 余量 ~540 MB，桌面应用波动大时用
  balanced   N=29, ctx=24576 — sweep 最优（默认；纯文本）
  longctx    N=30, ctx=32768 — 牺牲少量速度换最长 ctx
  conserve   N=33, ctx=8192  — 释放 ~1 GB VRAM，适合还想跑别的 GPU 任务
  vision     N=35, ctx=16384 + mmproj-BF16 加载 — 启用图像输入。
             gen 降到 ~33 tok/s（5 expert layer 给 mmproj 让位），mmproj 在 GPU。

.PARAMETER NCpuMoe
覆盖 --n-cpu-moe（0-40）。模型 n_layer=40，N=40 等同 --cpu-moe。

.PARAMETER Ctx
覆盖 --ctx-size（建议 4096 / 8192 / 16384 / 24576 / 32768）。

.PARAMETER UbatchSize
覆盖 --ubatch-size（默认 512；不建议改，sweep 显示 256/1024 都掉性能）。

.PARAMETER Port
绑定端口（默认 8080）。

.PARAMETER Background
启动时放后台运行（脱离当前终端）。Action=start 默认前台运行。

.EXAMPLE
.\qwen.ps1 start
启动 balanced profile (N=29 c=24576)

.EXAMPLE
.\qwen.ps1 start -Profile safe
启动 safe profile (N=31 c=16384)

.EXAMPLE
.\qwen.ps1 start -NCpuMoe 30 -Ctx 16384
覆盖单个参数

.EXAMPLE
.\qwen.ps1 restart -Background
后台重启用最新参数

.EXAMPLE
.\qwen.ps1 status
查看当前 server 状态

.EXAMPLE
.\qwen.ps1 health
发健康检查请求
#>
[CmdletBinding()]
param(
  [Parameter(Position=0)]
  [ValidateSet('start','stop','restart','status','health','config','help')]
  [string]$Action = 'start',

  [ValidateSet('safe','balanced','longctx','conserve','vision')]
  [string]$Profile = 'balanced',

  [ValidateRange(0,40)] [int]$NCpuMoe,
  [ValidateRange(1024, 262144)] [int]$Ctx,
  [ValidateRange(64, 4096)] [int]$UbatchSize,
  [ValidateRange(64, 8192)] [int]$BatchSize,
  [ValidateRange(1, 65535)] [int]$Port,

  [switch]$Lan,           # bind to 0.0.0.0 + use api-key (LAN/WSL access)
  [switch]$Background,
  [switch]$Quiet
)

# ===== Model config — update here when switching models =====
$ModelHf    = 'unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_M'   # HuggingFace repo:file
$ModelAlias = 'qwen3.6-35b-a3b'                             # name exposed at /v1/models

# ===== Paths =====
$Root      = Split-Path -Parent $PSScriptRoot   # repo root (parent of scripts/)
$Bin       = "$Root\bin"
$Logs      = "$Root\logs"
$Models    = "$Root\models"
$ExePath   = "$Bin\llama-server.exe"

$env:LLAMA_CACHE = $Models
$env:PATH        = "$Bin;$env:PATH"

# ===== Profile presets =====
$MmprojPath = "$Root\mmproj\mmproj-BF16.gguf"
$Profiles = @{
  safe     = @{ NCpuMoe = 31; Ctx = 16384 }
  balanced = @{ NCpuMoe = 29; Ctx = 24576 }   # sweep optimum (text-only)
  longctx  = @{ NCpuMoe = 30; Ctx = 32768 }
  conserve = @{ NCpuMoe = 33; Ctx = 8192  }
  vision   = @{ NCpuMoe = 35; Ctx = 16384; Mmproj = $true }
}

# ===== Effective config (profile defaults, overridden by explicit params) =====
$cfg = @{
  NCpuMoe     = $Profiles[$Profile].NCpuMoe
  Ctx         = $Profiles[$Profile].Ctx
  UbatchSize  = 512
  BatchSize   = 2048
  Port        = 8080
}
foreach ($k in @('NCpuMoe','Ctx','UbatchSize','BatchSize','Port')) {
  if ($PSBoundParameters.ContainsKey($k)) { $cfg[$k] = $PSBoundParameters[$k] }
}

# ===== Helpers =====
function Get-ServerProc { Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue }

function Get-LanIp {
  # Pick the first DHCP/Manual IPv4 on a real Ethernet/Wi-Fi interface (skip WSL/VPN)
  $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.PrefixOrigin -in 'Dhcp','Manual' -and $_.InterfaceAlias -notmatch 'Loopback|WSL|vEthernet|singbox' } |
    Select-Object -First 1
  if ($ip) { return $ip.IPAddress } else { return '0.0.0.0' }
}

function Get-OrCreate-ApiKey {
  $keyFile = "$Root\.apikey"
  if (-not (Test-Path $keyFile)) {
    # 32-byte cryptographically random key, base64-url encoded
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $key = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
    Set-Content -Path $keyFile -Value $key -Encoding ascii -NoNewline
    # Restrict to current user only (Windows ACL)
    icacls $keyFile /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
    Write-Host "Generated new API key -> $keyFile" -ForegroundColor Yellow
  }
  return @{ Path = $keyFile; Key = (Get-Content $keyFile -Raw).Trim() }
}

function Ensure-FirewallRule {
  $ruleName = 'Qwen llama-server (Private LAN)'
  $exe = $ExePath
  $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
  if ($existing) {
    Write-Host "Firewall rule already present: $ruleName" -ForegroundColor DarkGray
    return $true
  }
  Write-Host "Creating firewall rule (needs admin)..." -ForegroundColor Yellow
  try {
    New-NetFirewallRule -DisplayName $ruleName `
      -Direction Inbound -Action Allow `
      -Protocol TCP -LocalPort $cfg.Port `
      -Profile Private `
      -Program $exe `
      -Description 'Allow LAN access to local Qwen llama-server (api-key required).' `
      -ErrorAction Stop | Out-Null
    Write-Host "Firewall rule created." -ForegroundColor Green
    return $true
  } catch {
    Write-Host "Failed to create firewall rule: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Run once in an elevated pwsh:" -ForegroundColor Yellow
    Write-Host "  New-NetFirewallRule -DisplayName '$ruleName' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $($cfg.Port) -Profile Private -Program '$exe'" -ForegroundColor Cyan
    return $false
  }
}

function Show-Status {
  $p = Get-ServerProc
  if (-not $p) { Write-Host 'Server: NOT RUNNING' -ForegroundColor Yellow; return }
  $vram = (nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader) -split ','
  $listen = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
            Where-Object { $_.OwningProcess -eq $p.Id -and $_.LocalPort -eq $cfg.Port } |
            Select-Object -First 1
  $bind = if ($listen) { $listen.LocalAddress } else { '?' }
  Write-Host 'Server: RUNNING' -ForegroundColor Green
  Write-Host ("  PID         : {0}" -f $p.Id)
  Write-Host ("  Start time  : {0}" -f $p.StartTime)
  Write-Host ("  Uptime      : {0:hh\:mm\:ss}" -f ((Get-Date) - $p.StartTime))
  Write-Host ("  CPU time    : {0:N1} s" -f $p.CPU)
  Write-Host ("  Working set : {0:N0} MB" -f ($p.WorkingSet64/1MB))
  Write-Host ("  GPU used    : {0} (free {1})" -f $vram[0].Trim(), $vram[1].Trim())
  Write-Host ("  Listening on: {0}:{1}" -f $bind, $cfg.Port)
  if ($bind -eq '0.0.0.0' -or $bind -eq '::') {
    $lanIp = Get-LanIp
    Write-Host ("  LAN endpoint: http://{0}:{1}/v1  (api-key required)" -f $lanIp, $cfg.Port) -ForegroundColor Cyan
    $keyFile = "$Root\.apikey"
    if (Test-Path $keyFile) {
      Write-Host ("  API key file: {0}" -f $keyFile) -ForegroundColor DarkGray
    }
  } else {
    Write-Host ("  Endpoint    : http://127.0.0.1:{0}/v1  (localhost only)" -f $cfg.Port)
  }
}

function Show-Config {
  Write-Host "Profile        : $Profile" -ForegroundColor Cyan
  Write-Host ("Effective config:") -ForegroundColor Cyan
  Write-Host ("  --n-cpu-moe  : {0}" -f $cfg.NCpuMoe)
  Write-Host ("  -c           : {0}" -f $cfg.Ctx)
  Write-Host ("  -ub          : {0}" -f $cfg.UbatchSize)
  Write-Host ("  -b           : {0}" -f $cfg.BatchSize)
  Write-Host ("  --port       : {0}" -f $cfg.Port)
  # VRAM estimates from sweep at ctx=16384 (ctx delta is ~25 MiB per 8k, negligible)
  $vramTable = @{ 40=8230; 35=8706; 34=9175; 33=9266; 32=9399; 31=9682; 30=9752; 29=9808; 28=9988; 27=10030 }
  $n = $cfg.NCpuMoe
  if ($vramTable.ContainsKey($n)) {
    $estIdle = $vramTable[$n]
  } else {
    # linear interpolation between nearest sweep points
    $keys = $vramTable.Keys | Sort-Object
    $lo = ($keys | Where-Object { $_ -le $n } | Select-Object -Last 1)
    $hi = ($keys | Where-Object { $_ -ge $n } | Select-Object -First 1)
    if ($lo -and $hi -and $lo -ne $hi) {
      $estIdle = [int]($vramTable[$lo] + ($vramTable[$hi] - $vramTable[$lo]) * ($n - $lo) / ($hi - $lo))
    } else {
      $estIdle = if ($lo) { $vramTable[$lo] } else { $vramTable[$hi] }
    }
  }
  # ctx contribution: ~25 MiB per 8k delta above 16k baseline
  $ctxDelta = [math]::Max(0, [int](($cfg.Ctx - 16384) / 8192 * 25))
  $estIdle += $ctxDelta
  # mmproj contribution (vision profile or explicit -Vision-style usage)
  if ($Profiles[$Profile].Mmproj) {
    $estIdle += 903   # mmproj-BF16 size
    Write-Host ("Mmproj         : BF16 (+903 MiB GPU)") -ForegroundColor Magenta
  }
  Write-Host ("Estimated idle VRAM : ~{0} MiB (based on 2026-05-23 sweep)" -f $estIdle) -ForegroundColor DarkGray
  if ($estIdle -gt 9950) {
    Write-Host "  WARNING: very tight or unstable; expect OOM or prompt-eval thrash" -ForegroundColor Red
  } elseif ($estIdle -gt 9750) {
    Write-Host "  NOTE: tight VRAM (<~290 MB margin); close other GPU apps first" -ForegroundColor Yellow
  } else {
    Write-Host ("  margin       : ~{0} MiB" -f (10240 - $estIdle)) -ForegroundColor Green
  }
}

function Stop-Server {
  $p = Get-ServerProc
  if (-not $p) { Write-Host 'No server running.' -ForegroundColor DarkGray; return }
  Write-Host ("Stopping PID {0}..." -f $p.Id) -ForegroundColor Yellow
  $p | Stop-Process -Force
  $deadline = (Get-Date).AddSeconds(10)
  while ((Get-Date) -lt $deadline -and (Get-ServerProc)) { Start-Sleep -Milliseconds 200 }
  if (Get-ServerProc) { Write-Host 'WARN: process still alive after 10s.' -ForegroundColor Red } else { Write-Host 'Stopped.' -ForegroundColor Green }
}

function Start-Server {
  if (Get-ServerProc) {
    Write-Host 'Server already running. Use restart, or stop first.' -ForegroundColor Yellow
    Show-Status
    return
  }
  if (-not $Quiet) { Show-Config }

  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $logFile = "$Logs\server-$stamp.log"
  New-Item -ItemType Directory -Force -Path $Logs | Out-Null

  $bindHost = '127.0.0.1'
  $extraArgs = @()
  if ($Lan) {
    $bindHost = '0.0.0.0'
    $keyInfo  = Get-OrCreate-ApiKey
    $extraArgs += @('--api-key-file', $keyInfo.Path)
    Ensure-FirewallRule | Out-Null
  }
  if ($Profiles[$Profile].Mmproj) {
    if (-not (Test-Path $MmprojPath)) {
      Write-Host "ERROR: mmproj file not found at $MmprojPath" -ForegroundColor Red
      Write-Host "Download with:" -ForegroundColor Yellow
      Write-Host "  Invoke-WebRequest -Uri 'https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/resolve/main/mmproj-BF16.gguf?download=true' -OutFile '$MmprojPath'" -ForegroundColor Cyan
      return
    }
    $extraArgs += @('--mmproj', $MmprojPath)
    # Default is GPU offload, which we want for usable image processing speed.
    # The vision profile sized N=35 to leave room for mmproj on GPU.
  }

  $launchArgs = @(
    '-hf', $ModelHf,
    '--alias', $ModelAlias,
    '--host', $bindHost, '--port', $cfg.Port,
    '-c', $cfg.Ctx,
    '-ngl', '999', '--n-cpu-moe', $cfg.NCpuMoe,
    '--flash-attn', 'auto',
    '--cache-type-k', 'q8_0', '--cache-type-v', 'q8_0',
    '-t', '8', '-tb', '8',
    '-b', $cfg.BatchSize, '-ub', $cfg.UbatchSize,
    '--jinja', '--parallel', '1'
  ) + $extraArgs

  Write-Host ""
  Write-Host "Log: $logFile" -ForegroundColor DarkGray
  if ($Profiles[$Profile].Mmproj) {
    Write-Host "Multimodal: mmproj-BF16 (903 MB on GPU)" -ForegroundColor Magenta
  }
  if ($Lan) {
    $lanIp = Get-LanIp
    Write-Host ("Binding: 0.0.0.0:{0}  (LAN endpoint http://{1}:{0}/v1)" -f $cfg.Port, $lanIp) -ForegroundColor Cyan
    Write-Host ("API key: {0}\.apikey  (clients must send 'Authorization: Bearer <key>')" -f $Root) -ForegroundColor Yellow
  } else {
    Write-Host ("Endpoint: http://127.0.0.1:{0}/v1  (localhost only)" -f $cfg.Port) -ForegroundColor Cyan
  }
  Write-Host ""

  if ($Background) {
    $proc = Start-Process -FilePath $ExePath -ArgumentList $launchArgs `
      -RedirectStandardOutput $logFile -RedirectStandardError "$logFile.err" `
      -WindowStyle Hidden -PassThru
    Write-Host ("Started PID {0} in background." -f $proc.Id) -ForegroundColor Green

    # Wait up to 60s for ready
    $deadline = (Get-Date).AddSeconds(120)
    Write-Host -NoNewline 'Waiting for ready'
    while ((Get-Date) -lt $deadline) {
      if ($proc.HasExited) {
        Write-Host ""
        Write-Host ("FAILED: process exited with code {0}" -f $proc.ExitCode) -ForegroundColor Red
        Write-Host ("Log: $logFile") -ForegroundColor DarkGray
        return
      }
      $logContent = ''
      if (Test-Path $logFile) { $logContent = Get-Content $logFile -Raw -ErrorAction SilentlyContinue }
      if (Test-Path "$logFile.err") { $logContent += "`n" + (Get-Content "$logFile.err" -Raw -ErrorAction SilentlyContinue) }
      if ($logContent -match 'server is listening') {
        Write-Host ""
        Write-Host 'READY' -ForegroundColor Green
        Start-Sleep -Seconds 1
        Show-Status
        return
      }
      if ($logContent -match '(?i)out of memory|cuda error|failed to allocate') {
        Write-Host ""
        Write-Host 'FAILED to load (likely OOM). Try -Profile safe or -NCpuMoe 31' -ForegroundColor Red
        return
      }
      Write-Host -NoNewline '.'
      Start-Sleep -Milliseconds 500
    }
    Write-Host ""
    Write-Host 'TIMEOUT after 2 min. Check log.' -ForegroundColor Red
  } else {
    # Foreground: Ctrl+C closes server
    & $ExePath @launchArgs 2>&1 | Tee-Object -FilePath $logFile
  }
}

function Test-Health {
  if (-not (Get-ServerProc)) {
    Write-Host 'Server not running. Start it first.' -ForegroundColor Yellow
    return
  }
  $headers = @{ 'Content-Type' = 'application/json' }
  $keyFile = "$Root\.apikey"
  if (Test-Path $keyFile) {
    $key = (Get-Content $keyFile -Raw).Trim()
    $headers['Authorization'] = "Bearer $key"
  }
  $body = @{
    model = 'qwen3.6-35b-a3b'
    messages = @(@{role='user';content='Reply in one sentence to confirm you are working correctly.'})
    temperature = 0.3; max_tokens = 128; stream = $false
    chat_template_kwargs = @{ enable_thinking = $false }
  } | ConvertTo-Json -Depth 10 -Compress
  try {
    $t0 = Get-Date
    $r = Invoke-RestMethod "http://127.0.0.1:$($cfg.Port)/v1/chat/completions" `
      -Method Post -Headers $headers -Body $body -TimeoutSec 60
    $w = ((Get-Date) - $t0).TotalSeconds
    Write-Host 'OK' -ForegroundColor Green
    Write-Host ("  wall_time   : {0:N2}s" -f $w)
    Write-Host ("  gen_tok/s   : {0:N2}" -f $r.timings.predicted_per_second)
    Write-Host ("  prompt_tok/s: {0:N2}" -f $r.timings.prompt_per_second)
    Write-Host ("  response    : {0}" -f $r.choices[0].message.content)
  } catch {
    Write-Host 'FAILED: ' -NoNewline -ForegroundColor Red
    Write-Host $_.Exception.Message
  }
}

function Show-Help {
  Get-Help $PSCommandPath -Full | Out-String | Write-Host
}

# ===== Dispatch =====
switch ($Action) {
  'start'   { Start-Server }
  'stop'    { Stop-Server }
  'restart' { Stop-Server; Start-Sleep -Seconds 2; Start-Server }
  'status'  { Show-Status }
  'health'  { Test-Health }
  'config'  { Show-Config }
  'help'    { Show-Help }
}
