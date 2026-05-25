<#
.SYNOPSIS
Qwen3.6-35B-A3B 本地 llama-server 统一管理器。

.DESCRIPTION
管理本地 llama.cpp server 的生命周期（启动/停止/重启/状态/健康检查），支持预设 profile 和单参数覆盖。

.PARAMETER Action
要执行的操作：
  start     启动 server（默认；如已在运行则报错，要重启用 restart）
  stop      停止 server
  restart   停止后重启（用最新参数或当前 profile）
  status    查看运行状态、PID、VRAM 占用（不依赖 models.json）
  health    发一个测试请求，报告 gen tok/s；带 -Model 时严格匹配 server alias
  config    仅打印将要使用的参数，不启动
  validate  校验 models.json 是否结构合法、default 是否指向已知条目
  ui        启动聊天 Web UI（http://127.0.0.1:8090）
  help      显示用法

status / stop / help 在 models.json 缺失或损坏时仍可运行；其它子命令会显式报错。

.PARAMETER Model
要使用的模型 id（见 repo 根目录 models.json）。
解析优先级：-Model > $env:QWEN_MODEL > models.json 中的 default。
常用 id：
  unsloth-q4km        默认；unsloth UD-Q4_K_M（基线）
  hauhau-q4km         HauhauCS Uncensored Aggressive Q4_K_M
  hauhau-q4kp         HauhauCS Q4_K_P（更大；10G 显卡建议 -Profile conserve）
  hauhau-iq4nl        HauhauCS IQ4_NL（高压缩高质量）
  hauhau-iq2m         HauhauCS IQ2_M（6-8G 显卡可跑）

.PARAMETER AllowDifferentModel
仅作用于 health：默认情况下若 -Model 期望的 alias 不在 /v1/models 返回里，health 会失败退出（防止用错模型的绿色误判）。带此开关则降级为告警继续探测。

.PARAMETER Profile
不显式指定时按以下优先级解析：-Profile > 模型条目的 recommended_profile > balanced。
预设组合（按 n_layer=40 设计；Qwen3.6-35B-A3B 家族通用）：
  safe       N=31, ctx=16384 — 余量 ~540 MB，桌面应用波动大时用
  balanced   N=29, ctx=24576 — sweep 最优（默认；纯文本）
  longctx    N=30, ctx=32768 — 牺牲少量速度换最长 ctx
  conserve   N=33, ctx=8192  — 释放 ~1 GB VRAM，适合还想跑别的 GPU 任务
  vision     N=35, ctx=16384 + mmproj 加载 — 启用图像输入。
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
  # ValidateSet includes help-flag synonyms so `qwen --help` / `qwen -h` style
  # invocations don't fall over with a confusing ValidateSet error. The dispatcher
  # promotes any of these to $Help=true before acting on $Action.
  [Parameter(Position=0)]
  [ValidateSet('start','stop','restart','status','health','config','validate','help','ui',
               '--help','-help','--h','-h','-?','—help')]
  [string]$Action = 'start',

  [Parameter(Position=1)]
  [string]$Topic,         # only meaningful when Action='help'; e.g. `qwen help profiles`

  [string]$Model,         # model id from models.json (see Resolve-Model)

  # Default $null so we can tell whether the caller explicitly chose a profile.
  # When null, the resolved model's recommended_profile is used (or 'balanced' as fallback).
  [ValidateSet('safe','balanced','longctx','conserve','vision')]
  [string]$Profile,

  [ValidateRange(0,40)] [int]$NCpuMoe,
  [ValidateRange(1024, 262144)] [int]$Ctx,
  [ValidateRange(64, 4096)] [int]$UbatchSize,
  [ValidateRange(64, 8192)] [int]$BatchSize,
  [ValidateRange(1, 65535)] [int]$Port,

  [switch]$Lan,                  # bind to 0.0.0.0 + use api-key (LAN/WSL access)
  [switch]$Background,
  [switch]$Quiet,
  [switch]$AllowDifferentModel,  # health: probe whatever the server runs even if it differs
  # Per-action help: `qwen <action> -h` (or -Help, -?) shows help for that action.
  # PowerShell does not natively accept `--help`; use `-h` / `-Help` / `-?`.
  [Alias('h','?')]
  [switch]$Help,
  # Help language: -En forces English, -Zh forces Chinese (overrides env var).
  # Default: read $env:QWEN_HELP_LANG (set once in your PowerShell profile to persist);
  # falls back to English if unset. So `$env:QWEN_HELP_LANG = 'zh'` once, then plain
  # `qwen help` yields Chinese without per-call flags.
  [switch]$En,
  [switch]$Zh
)

# ===== Paths (no I/O) =====
$Root      = Split-Path -Parent $PSScriptRoot   # repo root (parent of scripts/)
$Bin       = "$Root\bin"
$Logs      = "$Root\logs"
$Models    = "$Root\models"
$ExePath   = "$Bin\llama-server.exe"

$env:LLAMA_CACHE = $Models
$env:PATH        = "$Bin;$env:PATH"

# Lib is dot-sourced unconditionally (it's a pure function library — no I/O at load time).
# Model resolution is deferred to the actions that actually need it (see Resolve-LaunchContext)
# so help/status/stop keep working even if models.json is missing or malformed.
. "$PSScriptRoot\_lib.ps1"

function Invoke-WithCleanErrors {
  param([scriptblock]$Block)
  try { & $Block } catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host  '       (Run `qwen validate` to inspect models.json.)' -ForegroundColor DarkGray
    exit 1
  }
}

# ===== Profile presets =====
$Profiles = @{
  safe     = @{ NCpuMoe = 31; Ctx = 16384 }
  balanced = @{ NCpuMoe = 29; Ctx = 24576 }   # sweep optimum (text-only)
  longctx  = @{ NCpuMoe = 30; Ctx = 32768 }
  conserve = @{ NCpuMoe = 33; Ctx = 8192  }
  vision   = @{ NCpuMoe = 35; Ctx = 16384; Mmproj = $true }
}

# ===== Always-available infra config (no model needed) =====
$cfg = @{
  UbatchSize = 512
  BatchSize  = 2048
  Port       = 8080
}
foreach ($k in @('UbatchSize','BatchSize','Port')) {
  if ($PSBoundParameters.ContainsKey($k)) { $cfg[$k] = $PSBoundParameters[$k] }
}

# ===== Lazy launch-context resolution =====
# Returns @{ Model=<hashtable>; ProfileName=<string>; ProfileSource=<string>;
#            NCpuMoe=<int>; Ctx=<int>; Mmproj=<bool>; MmprojPath=<string|null> }
# Only called by actions that need launch config (start/restart/config/health/validate)
# so a broken models.json never blocks help/status/stop.
function Resolve-LaunchContext {
  $modelCfg = Resolve-Model -Explicit $Model -Root $Root

  # Profile precedence: explicit -Profile > model.recommended_profile > 'balanced'
  if ($Profile) {
    $profName   = $Profile
    $profSource = 'explicit -Profile'
  } elseif ($modelCfg.recommended_profile) {
    $profName   = [string]$modelCfg.recommended_profile
    $profSource = "model.recommended_profile ($($modelCfg.id))"
  } else {
    $profName   = 'balanced'
    $profSource = 'default (model has no recommended_profile)'
  }
  if (-not $Profiles.ContainsKey($profName)) {
    throw "Resolved profile '$profName' is not a known profile. Known: $($Profiles.Keys -join ', ')"
  }
  $prof = $Profiles[$profName]

  # NCpuMoe / Ctx: profile defaults, overridden by explicit CLI params.
  # $script:PSBoundParameters is the *script-level* binding table — inside a function
  # plain $PSBoundParameters refers to the function's own (empty) bindings.
  $nCpuMoe = if ($script:PSBoundParameters.ContainsKey('NCpuMoe')) { $script:NCpuMoe } else { $prof.NCpuMoe }
  $ctx     = if ($script:PSBoundParameters.ContainsKey('Ctx'))     { $script:Ctx }     else { $prof.Ctx }

  # Enforce model's architectural bound on --n-cpu-moe (N must be in [0, n_layer]).
  # Reject early rather than letting llama-server fail at load time with a less obvious error.
  $nLayer = $modelCfg.n_layer -as [int]
  if (-not $nLayer -or $nLayer -le 0) {
    throw "Model '$($modelCfg.id)' is missing a valid n_layer in models.json (got '$($modelCfg.n_layer)'). Add a numeric n_layer matching the model's architecture."
  }
  if ($nCpuMoe -gt $nLayer) {
    $src = if ($PSBoundParameters.ContainsKey('NCpuMoe')) { "-NCpuMoe $nCpuMoe" } else { "profile '$profName' default ($nCpuMoe)" }
    throw "NCpuMoe=$nCpuMoe exceeds model '$($modelCfg.id)' n_layer=$nLayer (source: $src). Pick a profile or -NCpuMoe value in [0..$nLayer]."
  }

  $mmprojPath = $null
  if ($prof.Mmproj) {
    $mmprojPath = Get-ModelMmprojPath -Model $modelCfg -Root $Root  # may be null if model has no mmproj
  }

  return @{
    Model         = $modelCfg
    ProfileName   = $profName
    ProfileSource = $profSource
    NCpuMoe       = $nCpuMoe
    Ctx           = $ctx
    Mmproj        = [bool]$prof.Mmproj
    MmprojPath    = $mmprojPath
  }
}

# ===== Helpers =====
function Get-ServerProc {
  # Scope to processes whose executable lives under our repo's bin\ directory.
  # This avoids killing unrelated llama-server instances from other repos, benchmarks,
  # or manual sessions while remaining independent of port-binding state (safe during startup).
  Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path -like "$Bin\*" } |
    Select-Object -First 1
}

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
  param([hashtable]$Ctx = (Resolve-LaunchContext))
  $m = $Ctx.Model
  Write-Host ("Model id       : {0}" -f $m.id) -ForegroundColor Cyan
  Write-Host ("  -hf          : {0}" -f $m.hf) -ForegroundColor DarkGray
  Write-Host ("  --alias      : {0}" -f $m.alias) -ForegroundColor DarkGray
  Write-Host ("Profile        : {0}" -f $Ctx.ProfileName) -ForegroundColor Cyan
  Write-Host ("  source       : {0}" -f $Ctx.ProfileSource) -ForegroundColor DarkGray
  Write-Host ("Effective config:") -ForegroundColor Cyan
  Write-Host ("  --n-cpu-moe  : {0}" -f $Ctx.NCpuMoe)
  Write-Host ("  -c           : {0}" -f $Ctx.Ctx)
  Write-Host ("  -ub          : {0}" -f $cfg.UbatchSize)
  Write-Host ("  -b           : {0}" -f $cfg.BatchSize)
  Write-Host ("  --port       : {0}" -f $cfg.Port)
  # VRAM estimates from sweep at ctx=16384 (ctx delta is ~25 MiB per 8k, negligible)
  $vramTable = @{ 40=8230; 35=8706; 34=9175; 33=9266; 32=9399; 31=9682; 30=9752; 29=9808; 28=9988; 27=10030 }
  $n = $Ctx.NCpuMoe
  if ($vramTable.ContainsKey($n)) {
    $estIdle = $vramTable[$n]
  } else {
    $keys = $vramTable.Keys | Sort-Object
    $lo = ($keys | Where-Object { $_ -le $n } | Select-Object -Last 1)
    $hi = ($keys | Where-Object { $_ -ge $n } | Select-Object -First 1)
    if ($lo -and $hi -and $lo -ne $hi) {
      $estIdle = [int]($vramTable[$lo] + ($vramTable[$hi] - $vramTable[$lo]) * ($n - $lo) / ($hi - $lo))
    } else {
      $estIdle = if ($lo) { $vramTable[$lo] } else { $vramTable[$hi] }
    }
  }
  $ctxDelta = [math]::Max(0, [int](($Ctx.Ctx - 16384) / 8192 * 25))
  $estIdle += $ctxDelta
  if ($Ctx.Mmproj) {
    $estIdle += 903
    Write-Host ("Mmproj         : enabled (+903 MiB GPU)") -ForegroundColor Magenta
  }
  Write-Host ("Estimated idle VRAM : ~{0} MiB (based on 2026-05-23 sweep, unsloth-q4km baseline)" -f $estIdle) -ForegroundColor DarkGray
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
  param([hashtable]$PreResolvedCtx)   # set by restart to avoid re-resolving after Stop-Server
  if (Get-ServerProc) {
    Write-Host 'Server already running. Use restart, or stop first.' -ForegroundColor Yellow
    Show-Status
    return
  }
  $launch = if ($PreResolvedCtx) { $PreResolvedCtx } else { Resolve-LaunchContext }
  if (-not $Quiet) { Show-Config -Ctx $launch }

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
  $mmprojPath = $launch.MmprojPath
  if ($launch.Mmproj) {
    if (-not $mmprojPath) {
      Write-Host "ERROR: model '$($launch.Model.id)' has no mmproj entry in models.json" -ForegroundColor Red
      return
    }
    if (-not (Test-Path $mmprojPath)) {
      if ($launch.Model.mmproj_url) {
        try {
          $mmprojPath = Get-ModelMmprojPath -Model $launch.Model -Root $Root -AutoDownload
        } catch {
          Write-Host "ERROR downloading mmproj: $($_.Exception.Message)" -ForegroundColor Red
          return
        }
      } else {
        Write-Host "ERROR: mmproj file not found at $mmprojPath and no mmproj_url in models.json" -ForegroundColor Red
        return
      }
    }
    $extraArgs += @('--mmproj', $mmprojPath)
  }

  $launchArgs = @(
    '-hf', $launch.Model.hf,
    '--alias', $launch.Model.alias,
    '--host', $bindHost, '--port', $cfg.Port,
    '-c', $launch.Ctx,
    '-ngl', '999', '--n-cpu-moe', $launch.NCpuMoe,
    '--flash-attn', 'auto',
    '--cache-type-k', 'q8_0', '--cache-type-v', 'q8_0',
    '-t', '8', '-tb', '8',
    '-b', $cfg.BatchSize, '-ub', $cfg.UbatchSize,
    '--jinja', '--parallel', '1'
  ) + $extraArgs

  Write-Host ""
  Write-Host "Log: $logFile" -ForegroundColor DarkGray
  if ($launch.Mmproj) {
    Write-Host ("Multimodal: {0}" -f (Split-Path $mmprojPath -Leaf)) -ForegroundColor Magenta
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
    exit 2
  }
  # Only resolve the expected alias if the caller explicitly cared (via -Model or env var).
  # No expectation means "probe whatever is running" — a pure liveness check.
  $expectedAlias = $null
  if ($Model -or $env:QWEN_MODEL) {
    try {
      $expected = Resolve-Model -Explicit $Model -Root $Root
      $expectedAlias = $expected.alias
    } catch {
      Write-Host ("ERROR: cannot resolve expected model: $($_.Exception.Message)") -ForegroundColor Red
      exit 2
    }
  }

  $headers = @{ 'Content-Type' = 'application/json' }
  $keyFile = "$Root\.apikey"
  if (Test-Path $keyFile) {
    $key = (Get-Content $keyFile -Raw).Trim()
    $headers['Authorization'] = "Bearer $key"
  }

  # Ask the server which alias it actually serves.
  try {
    $modelsResp = Invoke-RestMethod "http://127.0.0.1:$($cfg.Port)/v1/models" -Method Get -Headers $headers -TimeoutSec 10
    $served = @($modelsResp.data.id)
  } catch {
    Write-Host ("FAILED: could not query /v1/models ($($_.Exception.Message))") -ForegroundColor Red
    exit 2
  }
  if (-not $served -or $served.Count -eq 0) {
    Write-Host 'FAILED: server returned no models on /v1/models' -ForegroundColor Red
    exit 2
  }

  $aliasToSend = $served | Select-Object -First 1
  if ($expectedAlias) {
    if ($served -contains $expectedAlias) {
      $aliasToSend = $expectedAlias
    } elseif ($AllowDifferentModel) {
      Write-Host ("WARNING: expected '$expectedAlias' but server serves '$aliasToSend' (-AllowDifferentModel set; probing anyway).") -ForegroundColor Yellow
    } else {
      Write-Host ("FAILED: expected alias '$expectedAlias' not served. Server serves: $($served -join ', ')") -ForegroundColor Red
      Write-Host  '       (Re-run with -AllowDifferentModel to probe whatever is running.)' -ForegroundColor DarkGray
      exit 1
    }
  }

  $body = @{
    model = $aliasToSend
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
    Write-Host ("  model       : {0}" -f $aliasToSend)
    Write-Host ("  wall_time   : {0:N2}s" -f $w)
    Write-Host ("  gen_tok/s   : {0:N2}" -f $r.timings.predicted_per_second)
    Write-Host ("  prompt_tok/s: {0:N2}" -f $r.timings.prompt_per_second)
    Write-Host ("  response    : {0}" -f $r.choices[0].message.content)
  } catch {
    Write-Host 'FAILED: ' -NoNewline -ForegroundColor Red
    Write-Host $_.Exception.Message
    exit 1
  }
}

function Test-RegistryConfig {
  try {
    $reg = Get-ModelRegistry -Root $Root
  } catch {
    Write-Host ("FAILED to load models.json: $($_.Exception.Message)") -ForegroundColor Red
    exit 1
  }
  $ids = @($reg.models | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)
  Write-Host ("models.json loaded; default='$($reg.default)'; {0} entries: {1}" -f $ids.Count, ($ids -join ', ')) -ForegroundColor Green
  $bad = 0
  foreach ($id in $ids) {
    $entry = $reg.models.$id
    $issues = @()
    if (-not $entry.hf)    { $issues += 'missing .hf' }
    if (-not $entry.alias) { $issues += 'missing .alias' }
    # n_layer must be a positive integer — it's the upper bound on --n-cpu-moe.
    $nLayer = $entry.n_layer -as [int]
    if (-not $nLayer -or $nLayer -le 0) {
      $issues += "n_layer must be a positive integer (got '$($entry.n_layer)')"
    }
    # recommended_profile (if set) must be a known profile AND its NCpuMoe must fit n_layer.
    if ($entry.recommended_profile) {
      $rp = [string]$entry.recommended_profile
      if (-not $Profiles.ContainsKey($rp)) {
        $issues += "recommended_profile '$rp' not a known profile"
      } elseif ($nLayer -and $Profiles[$rp].NCpuMoe -gt $nLayer) {
        $issues += "recommended_profile '$rp' (NCpuMoe=$($Profiles[$rp].NCpuMoe)) exceeds n_layer=$nLayer"
      }
    }
    if ($issues.Count -gt 0) {
      Write-Host ("  [bad]  {0}: {1}" -f $id, ($issues -join '; ')) -ForegroundColor Red
      $bad++
    } else {
      Write-Host ("  [ok]   {0}: alias={1}; n_layer={2}; rec_profile={3}" -f $id, $entry.alias, $nLayer, ($entry.recommended_profile)) -ForegroundColor DarkGray
    }
  }
  if (-not ($ids -contains $reg.default)) {
    Write-Host ("FAILED: default '$($reg.default)' is not in the models list.") -ForegroundColor Red
    $bad++
  }
  # Aliases are used as identity by llama-server (/v1/models) and the UI's back-resolution.
  # Duplicate aliases make it impossible to know which model variant is actually loaded.
  $aliasSeen = @{}
  foreach ($id in $ids) {
    $alias = [string]$reg.models.$id.alias
    if (-not $alias) { continue }
    if ($aliasSeen.ContainsKey($alias)) {
      Write-Host ("FAILED: alias '$alias' is shared by '$id' and '$($aliasSeen[$alias])'. Aliases must be unique.") -ForegroundColor Red
      $bad++
    } else {
      $aliasSeen[$alias] = $id
    }
  }
  if ($bad -gt 0) { exit 1 } else { Write-Host 'OK: registry is valid.' -ForegroundColor Green }
}

function Resolve-HelpLang {
  # Precedence: -En / -Zh flag > $env:QWEN_HELP_LANG > English fallback.
  param([switch]$En, [switch]$Zh)
  if ($En -and $Zh) {
    Write-Host 'ERROR: cannot pass both -En and -Zh.' -ForegroundColor Red
    exit 1
  }
  if ($En) { return 'en' }
  if ($Zh) { return 'zh' }
  $envLang = $env:QWEN_HELP_LANG
  if ($envLang) {
    $envLang = $envLang.ToLower()
    if ($envLang -in @('zh','cn','chinese','zh-cn')) { return 'zh' }
    if ($envLang -in @('en','en-us','english'))      { return 'en' }
    Write-Host "WARNING: ignoring unrecognized `$env:QWEN_HELP_LANG='$envLang' (use 'en' or 'zh')." -ForegroundColor Yellow
  }
  return 'en'
}

function Show-Help {
  param([string]$Topic, [switch]$En, [switch]$Zh)
  $lang = Resolve-HelpLang -En:$En -Zh:$Zh
  $isZh = ($lang -eq 'zh')
  $t = if ($Topic) { $Topic.ToLower() } else { '' }

  # `qwen help lang [zh|en]` — show current default and how to persist a choice.
  if ($t -eq 'lang') {
    Show-HelpLangCommand -IsZh:$isZh
    return
  }

  switch ($t) {
    ''         { if ($isZh) { Show-HelpOverviewZh } else { Show-HelpOverview } }
    'overview' { if ($isZh) { Show-HelpOverviewZh } else { Show-HelpOverview } }
    'actions'  { if ($isZh) { Show-HelpActionsZh }  else { Show-HelpActions } }
    # Per-action help (routed from `qwen <action> -h` too):
    'start'    { if ($isZh) { Show-HelpStartZh }    else { Show-HelpStart } }
    'stop'     { if ($isZh) { Show-HelpStopZh }     else { Show-HelpStop } }
    'restart'  { if ($isZh) { Show-HelpRestartZh }  else { Show-HelpRestart } }
    'status'   { if ($isZh) { Show-HelpStatusZh }   else { Show-HelpStatus } }
    'health'   { if ($isZh) { Show-HelpHealthZh }   else { Show-HelpHealth } }
    'config'   { if ($isZh) { Show-HelpConfigZh }   else { Show-HelpConfig } }
    'validate' { if ($isZh) { Show-HelpValidateZh } else { Show-HelpValidate } }
    'ui'       { if ($isZh) { Show-HelpUiZh }      else { Show-HelpUi } }
    # Cross-cutting topics:
    'models'   { if ($isZh) { Show-HelpModelsZh }   else { Show-HelpModels } }
    'profiles' { if ($isZh) { Show-HelpProfilesZh } else { Show-HelpProfiles } }
    'lan'      { if ($isZh) { Show-HelpLanZh }      else { Show-HelpLan } }
    'examples' { if ($isZh) { Show-HelpExamplesZh } else { Show-HelpExamples } }
    'help'     { if ($isZh) { Show-HelpOverviewZh } else { Show-HelpOverview } }
    'all'      { Get-Help $PSCommandPath -Full | Out-String | Write-Host }
    default {
      Write-Host "Unknown help topic: '$Topic'" -ForegroundColor Red
      Write-Host 'Available: start stop restart status health config validate ui  (actions)' -ForegroundColor DarkGray
      Write-Host '           models profiles lan examples lang actions overview all  (topics)' -ForegroundColor DarkGray
      exit 1
    }
  }
}

function Show-HelpLangCommand {
  param([switch]$IsZh)
  $current = Resolve-HelpLang
  if ($IsZh) {
    Write-Host '帮助语言设置' -ForegroundColor Cyan
    Write-Host ''
    Write-Host ("  当前生效语言   : {0}" -f $current)
    Write-Host ("  环境变量值     : `$env:QWEN_HELP_LANG = '{0}'" -f $env:QWEN_HELP_LANG)
    Write-Host ''
    Write-Host '一次性切换（仅当前命令）：' -ForegroundColor Yellow
    Write-Host '  qwen help -Zh                 # 中文'
    Write-Host '  qwen help -En                 # 英文'
    Write-Host ''
    Write-Host '当前 shell 持久（关掉就失效）：' -ForegroundColor Yellow
    Write-Host "  `$env:QWEN_HELP_LANG = 'zh'    # 中文"
    Write-Host "  `$env:QWEN_HELP_LANG = 'en'    # 英文"
    Write-Host ''
    Write-Host '全局持久（推荐 — 加进 PowerShell profile）：' -ForegroundColor Yellow
    Write-Host '  notepad $PROFILE              # 打开你的 profile'
    Write-Host '  # 加入这一行：'
    Write-Host "  `$env:QWEN_HELP_LANG = 'zh'"
    Write-Host '  # 然后:  . $PROFILE           # 重新加载'
    Write-Host ''
    Write-Host '解析优先级：-En / -Zh > `$env:QWEN_HELP_LANG > 英文兜底。'
  } else {
    Write-Host 'Help language settings' -ForegroundColor Cyan
    Write-Host ''
    Write-Host ("  Effective language     : {0}" -f $current)
    Write-Host ("  Environment variable   : `$env:QWEN_HELP_LANG = '{0}'" -f $env:QWEN_HELP_LANG)
    Write-Host ''
    Write-Host 'One-off override (this command only):' -ForegroundColor Yellow
    Write-Host '  qwen help -Zh                 # Chinese'
    Write-Host '  qwen help -En                 # English'
    Write-Host ''
    Write-Host 'Persist for this shell only (gone when you close it):' -ForegroundColor Yellow
    Write-Host "  `$env:QWEN_HELP_LANG = 'zh'    # Chinese"
    Write-Host "  `$env:QWEN_HELP_LANG = 'en'    # English"
    Write-Host ''
    Write-Host 'Persist globally (recommended — add to your PowerShell profile):' -ForegroundColor Yellow
    Write-Host '  notepad $PROFILE              # open your profile'
    Write-Host '  # Add this line:'
    Write-Host "  `$env:QWEN_HELP_LANG = 'zh'"
    Write-Host '  # Then:   . $PROFILE          # reload'
    Write-Host ''
    Write-Host 'Resolution precedence: -En / -Zh > $env:QWEN_HELP_LANG > English fallback.'
  }
}

# --- English ---

function Show-HelpOverview {
  Write-Host 'qwen — local llama-server manager for the Qwen3.6-35B-A3B family' -ForegroundColor Cyan
  Write-Host ''
  Write-Host 'USAGE' -ForegroundColor Yellow
  Write-Host '  qwen <action> [options]                # run an action'
  Write-Host '  qwen <action> -h                       # help for that action'
  Write-Host '  qwen help <topic>                      # cross-cutting topic page'
  Write-Host '  qwen help                              # this overview'
  Write-Host ''
  Write-Host '  (-h / -Help / -? / --help / --h all accepted.)'
  Write-Host ''
  Write-Host 'ACTIONS' -ForegroundColor Yellow
  Write-Host '  start     Launch llama-server (default action)'
  Write-Host '  stop      Stop the running server (only one runs at a time)'
  Write-Host '  restart   Stop + start; re-reads -Model / -Profile / overrides'
  Write-Host '  status    PID, uptime, VRAM, listen address'
  Write-Host '  health    Probe /v1/models + send a tiny chat completion'
  Write-Host '  config    Print resolved launch params; do not start'
  Write-Host '  validate  Lint models.json (entries, n_layer, recommended_profile)'
  Write-Host '  ui        Launch the chat web UI (http://127.0.0.1:8090)'
  Write-Host '  help      Show help (this page, or `qwen help <topic>`)'
  Write-Host ''
  Write-Host 'COMMON RECIPES' -ForegroundColor Yellow
  Write-Host '  qwen start                          # default model + default profile'
  Write-Host '  qwen start -Model hauhau-q4km       # switch model (see: qwen help models)'
  Write-Host '  qwen start -Profile longctx         # switch profile (see: qwen help profiles)'
  Write-Host '  qwen restart -Background            # detach from terminal'
  Write-Host '  qwen status                          # is it running?'
  Write-Host '  qwen health                          # is it responding correctly?'
  Write-Host '  qwen config -Profile vision         # preview without starting'
  Write-Host '  qwen ui                             # open chat UI in browser'
  Write-Host ''
  Write-Host 'HELP TOPICS' -ForegroundColor Yellow
  Write-Host '  qwen help models       Listing & switching models (models.json)'
  Write-Host '  qwen help profiles     Profile cheat sheet (VRAM / ctx tradeoff)'
  Write-Host '  qwen help health       What health checks; mismatch semantics'
  Write-Host '  qwen help lan          Exposing on LAN / WSL with API key'
  Write-Host '  qwen help examples     More command patterns'
  Write-Host '  qwen help lang         How to set the help language (English / Chinese)'
  Write-Host '  qwen help all          Full PowerShell Get-Help dump (verbose)'
  Write-Host ''
  Write-Host 'Tip: `$env:QWEN_HELP_LANG = "zh"` in your $PROFILE persists Chinese output.' -ForegroundColor DarkGray
}

function Show-HelpActions {
  Write-Host 'qwen — actions' -ForegroundColor Cyan
  Write-Host ''
  Write-Host '  start        Launch llama-server with the resolved model + profile.'
  Write-Host '               Foreground by default; -Background detaches.'
  Write-Host '               Fails if a server is already running (use restart).'
  Write-Host ''
  Write-Host '  stop         Stop the running llama-server.'
  Write-Host '               Works even if models.json is missing or broken.'
  Write-Host ''
  Write-Host '  restart      stop + (2s wait) + start.'
  Write-Host '               Re-resolves -Model / -Profile / -NCpuMoe / -Ctx each time.'
  Write-Host ''
  Write-Host '  status       PID, start time, uptime, CPU time, working set,'
  Write-Host '               VRAM used/free, listen address. No models.json access.'
  Write-Host ''
  Write-Host '  health       GET /v1/models then POST a small chat completion.'
  Write-Host '               With -Model: fail-closed if server runs a different alias.'
  Write-Host '               With -Model -AllowDifferentModel: warn-and-probe instead.'
  Write-Host '               Without -Model: pure liveness probe (whatever is running).'
  Write-Host ''
  Write-Host '  config       Print the launch context that WOULD be used + VRAM estimate.'
  Write-Host '               Shows: model id, hf, alias, profile name, profile source,'
  Write-Host '               effective NCpuMoe / Ctx / batch sizes / port.'
  Write-Host ''
  Write-Host '  validate     Load models.json and lint every entry. Exit 1 on any issue.'
  Write-Host '               Checks: hf, alias, n_layer (positive int), recommended_profile'
  Write-Host '               is known + its NCpuMoe fits n_layer, default points to an id.'
  Write-Host ''
  Write-Host '  help         This help. Topics: overview, actions, models, profiles,'
  Write-Host '               health, lan, examples, all.'
}

function Show-HelpModels {
  Write-Host 'qwen — model selection' -ForegroundColor Cyan
  Write-Host ''
  Write-Host 'Models are defined in models.json at the repo root. Resolution order:'
  Write-Host '  1. -Model <id>            command-line flag (highest priority)'
  Write-Host '  2. $env:QWEN_MODEL        environment variable (persists for shell)'
  Write-Host '  3. "default" in models.json (fallback)'
  Write-Host ''
  Write-Host 'Seeded entries:' -ForegroundColor Yellow
  try {
    $reg = Get-ModelRegistry -Root $Root
    $ids = @($reg.models | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)
    foreach ($id in $ids) {
      $e = $reg.models.$id
      $marker = if ($id -eq $reg.default) { ' (default)' } else { '' }
      Write-Host ("  {0,-18} {1}  rec_profile={2}{3}" -f $id, $e.alias, $e.recommended_profile, $marker)
    }
  } catch {
    Write-Host "  (could not read models.json: $($_.Exception.Message))" -ForegroundColor DarkGray
  }
  Write-Host ''
  Write-Host 'Examples:' -ForegroundColor Yellow
  Write-Host '  qwen start                              # default model'
  Write-Host '  qwen start -Model hauhau-q4km           # one-off switch'
  Write-Host '  $env:QWEN_MODEL = "hauhau-iq4nl"        # persist for this shell'
  Write-Host '  qwen restart -Background                #   ↳ picks up env var'
  Write-Host '  qwen config -Model hauhau-iq2m          # preview without launching'
  Write-Host ''
  Write-Host 'To add a model: append an entry to models.json with at least these fields:'
  Write-Host '  { "hf": "...", "alias": "...", "n_layer": <int>, "recommended_profile": "..." }'
  Write-Host 'Then run `qwen validate` to confirm.'
}

function Show-HelpProfiles {
  Write-Host 'qwen — profiles (VRAM / context tradeoff)' -ForegroundColor Cyan
  Write-Host ''
  Write-Host 'Profiles are preset --n-cpu-moe + --ctx-size combinations tuned for'
  Write-Host 'Qwen3.6-35B-A3B (n_layer=40). Switch via the -Profile flag — no need'
  Write-Host 'to edit models.json.'
  Write-Host ''
  Write-Host 'Profile resolution order:' -ForegroundColor Yellow
  Write-Host '  1. -Profile <name>                    explicit CLI flag'
  Write-Host '  2. model.recommended_profile          per-model default from models.json'
  Write-Host '  3. "balanced"                          ultimate fallback'
  Write-Host ''
  Write-Host 'Presets:' -ForegroundColor Yellow
  Write-Host '  safe       N=31, ctx=16384   ~540 MB headroom; for busy desktops'
  Write-Host '  balanced   N=29, ctx=24576   sweep optimum (text-only)  [default]'
  Write-Host '  longctx    N=30, ctx=32768   slightly slower, longest context'
  Write-Host '  conserve   N=33, ctx=8192    frees ~1 GB VRAM for other apps'
  Write-Host '  vision     N=35, ctx=16384   + mmproj loaded; enables image input'
  Write-Host ''
  Write-Host 'Examples:' -ForegroundColor Yellow
  Write-Host '  qwen start -Profile safe                        # switch profile'
  Write-Host '  qwen start -Profile balanced -NCpuMoe 30 -Ctx 16384   # override on top'
  Write-Host '  qwen config -Profile vision                     # preview, no launch'
  Write-Host '  qwen restart -Profile longctx -Background       # restart on new profile'
  Write-Host ''
  Write-Host 'Constraints:'
  Write-Host '  -NCpuMoe must be in [0, model.n_layer] (currently 0..40 for all models).'
  Write-Host '  Values are validated before launch; invalid combos are rejected with a'
  Write-Host '  clear error rather than failing at llama-server startup.'
  Write-Host ''
  Write-Host 'To make one profile a model''s default, set its `recommended_profile` field'
  Write-Host 'in models.json (so you don''t have to repeat -Profile each time).'
}

function Show-HelpHealth {
  Write-Host 'qwen — health check semantics' -ForegroundColor Cyan
  Write-Host ''
  Write-Host '`qwen health` performs:'
  Write-Host '  1. GET /v1/models    — fail if server unreachable or returns no models'
  Write-Host '  2. POST /v1/chat/completions with a one-sentence prompt'
  Write-Host '  3. Print wall_time / gen_tok_per_sec / prompt_tok_per_sec / response'
  Write-Host ''
  Write-Host 'Model expectation behavior:'
  Write-Host '  Without -Model        Probe whatever the server is running (liveness only).'
  Write-Host '  With -Model X         FAIL-CLOSED: if X is not in /v1/models, exit 1 with'
  Write-Host '                        a clear "expected vs served" error. This is the'
  Write-Host '                        only way to verify the *intended* model is loaded.'
  Write-Host '  With -Model X -AllowDifferentModel'
  Write-Host '                        Diagnostic mode — warn about the mismatch and probe'
  Write-Host '                        the server''s actual alias anyway. Use to debug a'
  Write-Host '                        running server that you didn''t start.'
  Write-Host ''
  Write-Host 'Exit codes:'
  Write-Host '  0  ok                    1  request failed / model mismatch'
  Write-Host '  2  server unreachable    (also: cannot resolve -Model)'
  Write-Host ''
  Write-Host 'Examples:' -ForegroundColor Yellow
  Write-Host '  qwen health                                # any model'
  Write-Host '  qwen health -Model hauhau-q4km             # require hauhau is running'
  Write-Host '  qwen health -Model hauhau-q4km -AllowDifferentModel   # probe anyway'
}

function Show-HelpLan {
  Write-Host 'qwen — LAN / WSL access' -ForegroundColor Cyan
  Write-Host ''
  Write-Host 'Default mode binds 127.0.0.1 only (local-only, no auth). To expose on LAN:'
  Write-Host ''
  Write-Host '  qwen start -Lan'
  Write-Host ''
  Write-Host 'This:'
  Write-Host '  • Binds the server on 0.0.0.0 instead of 127.0.0.1'
  Write-Host '  • Generates a 32-byte API key at <repo>\.apikey (current-user ACL)'
  Write-Host '  • Passes --api-key-file to llama-server (key never in process command line)'
  Write-Host '  • Tries to create a Windows Firewall inbound rule (requires admin first'
  Write-Host '    time; if it fails, the script prints the exact command to run elevated)'
  Write-Host ''
  Write-Host 'Clients must send `Authorization: Bearer <key-from-.apikey>`.'
  Write-Host '/v1/models is NOT auth-protected by llama.cpp (this is upstream behavior).'
  Write-Host ''
  Write-Host '`qwen status` prints the LAN endpoint (LAN IP + port) when bound on 0.0.0.0.'
  Write-Host ''
  Write-Host 'WSL: use the Windows-host LAN IP (not 127.0.0.1) — see status output.'
}

function Show-HelpExamples {
  Write-Host 'qwen — common command patterns' -ForegroundColor Cyan
  Write-Host ''
  Write-Host '# Daily use'
  Write-Host '  qwen start                                # foreground, default model + profile'
  Write-Host '  qwen start -Background                    # detached'
  Write-Host '  qwen status'
  Write-Host '  qwen health'
  Write-Host '  qwen stop'
  Write-Host ''
  Write-Host '# Switching models / profiles'
  Write-Host '  qwen start -Model hauhau-q4km'
  Write-Host '  qwen restart -Model hauhau-iq2m -Profile longctx'
  Write-Host '  qwen config -Model hauhau-q4kp            # what would it use?'
  Write-Host ''
  Write-Host '# Persistent model selection for this shell'
  Write-Host '  $env:QWEN_MODEL = "hauhau-q4km"'
  Write-Host '  qwen restart -Background'
  Write-Host ''
  Write-Host '# Fine-grained tuning on top of a profile'
  Write-Host '  qwen start -Profile balanced -NCpuMoe 30 -Ctx 16384'
  Write-Host ''
  Write-Host '# LAN exposure with auto-generated API key'
  Write-Host '  qwen start -Lan -Background'
  Write-Host ''
  Write-Host '# Verify the intended model is what is actually loaded'
  Write-Host '  qwen health -Model hauhau-q4km            # fails if server runs unsloth'
  Write-Host ''
  Write-Host '# Maintenance'
  Write-Host '  qwen validate                             # lint models.json'
  Write-Host '  qwen config -Profile vision               # preview before -Background'
}

# --- English per-action ---

function Show-HelpStart {
  Write-Host 'qwen start — launch llama-server' -ForegroundColor Cyan
  Write-Host ''
  Write-Host '  qwen start [-Model <id>] [-Profile <name>] [-NCpuMoe <n>] [-Ctx <n>]'
  Write-Host '             [-Port <n>] [-Background] [-Lan] [-Quiet]'
  Write-Host ''
  Write-Host 'Resolves the model (see: qwen help models) and profile (see: qwen help profiles),'
  Write-Host 'then runs llama-server. Foreground by default; use -Background to detach.'
  Write-Host 'Fails fast if another server is already running (use restart instead).'
  Write-Host ''
  Write-Host 'Flags:' -ForegroundColor Yellow
  Write-Host '  -Model <id>       Pick a model from models.json (default: registry default).'
  Write-Host '  -Profile <name>   safe | balanced | longctx | conserve | vision.'
  Write-Host '                    If omitted, uses model.recommended_profile, then balanced.'
  Write-Host '  -NCpuMoe <int>    Override profile''s --n-cpu-moe. Must be in [0..n_layer].'
  Write-Host '  -Ctx <int>        Override profile''s --ctx-size.'
  Write-Host '  -Port <int>       Listen port (default 8080).'
  Write-Host '  -Background       Detach from terminal; print PID; wait for ready signal.'
  Write-Host '  -Lan              Bind 0.0.0.0 + auto-generate API key (see: qwen help lan).'
  Write-Host '  -Quiet            Suppress the pre-launch config dump.'
  Write-Host ''
  Write-Host 'Examples:' -ForegroundColor Yellow
  Write-Host '  qwen start'
  Write-Host '  qwen start -Model hauhau-q4km -Background'
  Write-Host '  qwen start -Profile vision'
  Write-Host '  qwen start -Profile balanced -NCpuMoe 30 -Ctx 16384'
  Write-Host '  qwen start -Lan -Background'
}

function Show-HelpStop {
  Write-Host 'qwen stop — stop the running llama-server' -ForegroundColor Cyan
  Write-Host ''
  Write-Host '  qwen stop'
  Write-Host ''
  Write-Host 'Sends Stop-Process to the llama-server PID, waits up to 10 s for exit.'
  Write-Host 'Safe to call when nothing is running (no-op + "No server running." message).'
  Write-Host 'Works even if models.json is missing or corrupted.'
}

function Show-HelpRestart {
  Write-Host 'qwen restart — stop + relaunch' -ForegroundColor Cyan
  Write-Host ''
  Write-Host '  qwen restart [same flags as `qwen start`]'
  Write-Host ''
  Write-Host 'Equivalent to `qwen stop` + 2-second wait + `qwen start <flags>`.'
  Write-Host 'Re-resolves -Model / -Profile / -NCpuMoe / -Ctx every time, so this is the'
  Write-Host 'normal way to switch between models or profiles on a live server.'
  Write-Host ''
  Write-Host 'Examples:' -ForegroundColor Yellow
  Write-Host '  qwen restart -Background'
  Write-Host '  qwen restart -Model hauhau-q4km -Profile longctx -Background'
}

function Show-HelpStatus {
  Write-Host 'qwen status — show server state' -ForegroundColor Cyan
  Write-Host ''
  Write-Host '  qwen status'
  Write-Host ''
  Write-Host 'Prints: PID, start time, uptime, CPU time, working set, VRAM used/free,'
  Write-Host '        listening address (and LAN endpoint + API key path when -Lan).'
  Write-Host ''
  Write-Host 'Does NOT read models.json — safe to use even if the registry is broken.'
}

function Show-HelpConfig {
  Write-Host 'qwen config — preview launch parameters' -ForegroundColor Cyan
  Write-Host ''
  Write-Host '  qwen config [-Model <id>] [-Profile <name>] [-NCpuMoe <n>] [-Ctx <n>]'
  Write-Host ''
  Write-Host 'Resolves the model and profile that a `qwen start` with the same flags would'
  Write-Host 'use, prints the full effective config plus a VRAM estimate. Does not launch.'
  Write-Host ''
  Write-Host 'Output includes:'
  Write-Host '  • Model id, -hf, --alias'
  Write-Host '  • Profile name and source (explicit / recommended / fallback)'
  Write-Host '  • --n-cpu-moe, -c, -ub, -b, --port'
  Write-Host '  • Estimated idle VRAM (MiB) vs 10 GiB budget, with color-coded headroom warning'
  Write-Host ''
  Write-Host 'Examples:' -ForegroundColor Yellow
  Write-Host '  qwen config                                # what would `qwen start` do?'
  Write-Host '  qwen config -Model hauhau-q4kp             # safe to inspect before launch'
  Write-Host '  qwen config -Profile vision'
}

function Show-HelpValidate {
  Write-Host 'qwen validate — lint models.json' -ForegroundColor Cyan
  Write-Host ''
  Write-Host '  qwen validate'
  Write-Host ''
  Write-Host 'Reads models.json and checks every entry. Exits 1 on any issue.'
  Write-Host ''
  Write-Host 'Per entry, validates:'
  Write-Host '  • .hf and .alias are present'
  Write-Host '  • .n_layer is a positive integer'
  Write-Host '  • .recommended_profile (if set) is a known profile AND its --n-cpu-moe'
  Write-Host '    preset is <= .n_layer'
  Write-Host ''
  Write-Host 'And globally:'
  Write-Host '  • "default" points to an existing entry'
  Write-Host ''
  Write-Host 'Run this after editing models.json to catch typos before a launch attempt.'
}

function Show-HelpUi {
  Write-Host 'qwen ui — launch the chat web UI' -ForegroundColor Cyan
  Write-Host ''
  Write-Host '  qwen ui [-Port <n>] [-Background]'
  Write-Host ''
  Write-Host 'Starts a FastAPI control plane on localhost that:'
  Write-Host '  • Serves a chat UI at http://127.0.0.1:<port>  (default: 8090)'
  Write-Host '  • Proxies /v1/* to llama-server at 127.0.0.1:8080'
  Write-Host '  • Exposes /api/* endpoints for model/profile switching'
  Write-Host ''
  Write-Host 'OPTIONS'
  Write-Host '  -Port <n>       UI port (default 8090). llama-server stays on 8080.'
  Write-Host '  -Background     Detach from terminal; log goes to logs\qwen-ui.log.'
  Write-Host ''
  Write-Host 'REQUIRES'
  Write-Host '  Python 3.8+ in PATH. A venv is created at web\.venv on first run.'
  Write-Host '  llama-server should already be running (qwen start) before opening the UI.'
  Write-Host ''
  Write-Host 'EXAMPLES'
  Write-Host '  qwen start -Background              # start llama-server first'
  Write-Host '  qwen ui                             # open UI in browser (foreground)'
  Write-Host '  qwen ui -Background                 # detach'
  Write-Host '  qwen ui -Port 9000                  # custom port'
  Write-Host ''
  Write-Host 'LLAMA-SERVER PORT'
  Write-Host '  If llama-server is on a port other than 8080, set before launching:'
  Write-Host '  $env:QWEN_LLAMA_PORT = 9090; qwen ui'
}

# --- Chinese (-Zh) ---

function Show-HelpStartZh {
  Write-Host 'qwen start — 启动 llama-server' -ForegroundColor Cyan
  Write-Host ''
  Write-Host '  qwen start [-Model <id>] [-Profile <name>] [-NCpuMoe <n>] [-Ctx <n>]'
  Write-Host '             [-Port <n>] [-Background] [-Lan] [-Quiet]'
  Write-Host ''
  Write-Host '解析模型（详见: qwen help models -Zh）和 profile（详见: qwen help profiles -Zh），'
  Write-Host '然后启动 llama-server。默认前台运行；-Background 脱离终端。'
  Write-Host '如已有 server 在跑会快速失败（请用 restart）。'
  Write-Host ''
  Write-Host '参数：' -ForegroundColor Yellow
  Write-Host '  -Model <id>       从 models.json 选模型（默认：registry default）。'
  Write-Host '  -Profile <name>   safe | balanced | longctx | conserve | vision。'
  Write-Host '                    不传则用 model.recommended_profile，兜底 balanced。'
  Write-Host '  -NCpuMoe <int>    覆盖 profile 的 --n-cpu-moe。必须 ∈ [0..n_layer]。'
  Write-Host '  -Ctx <int>        覆盖 profile 的 --ctx-size。'
  Write-Host '  -Port <int>       监听端口（默认 8080）。'
  Write-Host '  -Background       脱离终端；打印 PID；等 ready 信号。'
  Write-Host '  -Lan              绑 0.0.0.0 + 自动生成 API key（详见: qwen help lan -Zh）。'
  Write-Host '  -Quiet            不打印启动前的配置 dump。'
  Write-Host ''
  Write-Host '样例：' -ForegroundColor Yellow
  Write-Host '  qwen start'
  Write-Host '  qwen start -Model hauhau-q4km -Background'
  Write-Host '  qwen start -Profile vision'
  Write-Host '  qwen start -Profile balanced -NCpuMoe 30 -Ctx 16384'
  Write-Host '  qwen start -Lan -Background'
}

function Show-HelpStopZh {
  Write-Host 'qwen stop — 停止运行中的 llama-server' -ForegroundColor Cyan
  Write-Host ''
  Write-Host '  qwen stop'
  Write-Host ''
  Write-Host '向 llama-server PID 发 Stop-Process，最多等 10 秒退出。'
  Write-Host '没在跑也安全调用（no-op + 提示 "No server running."）。'
  Write-Host '即使 models.json 缺失/损坏也可用。'
}

function Show-HelpRestartZh {
  Write-Host 'qwen restart — stop + 重启' -ForegroundColor Cyan
  Write-Host ''
  Write-Host '  qwen restart [跟 qwen start 一样的参数]'
  Write-Host ''
  Write-Host '等价于 `qwen stop` + 2 秒等待 + `qwen start <flags>`。'
  Write-Host '每次都重新解析 -Model / -Profile / -NCpuMoe / -Ctx，所以这是在跑着的'
  Write-Host 'server 上切换模型或 profile 的常规方式。'
  Write-Host ''
  Write-Host '样例：' -ForegroundColor Yellow
  Write-Host '  qwen restart -Background'
  Write-Host '  qwen restart -Model hauhau-q4km -Profile longctx -Background'
}

function Show-HelpStatusZh {
  Write-Host 'qwen status — 查看 server 状态' -ForegroundColor Cyan
  Write-Host ''
  Write-Host '  qwen status'
  Write-Host ''
  Write-Host '打印：PID、启动时间、运行时长、CPU 时间、工作集、VRAM 占用、监听地址'
  Write-Host '      （带 -Lan 启动时还会显示 LAN endpoint 和 .apikey 路径）。'
  Write-Host ''
  Write-Host '不读 models.json — registry 损坏时也能用。'
}

function Show-HelpConfigZh {
  Write-Host 'qwen config — 预览启动参数' -ForegroundColor Cyan
  Write-Host ''
  Write-Host '  qwen config [-Model <id>] [-Profile <name>] [-NCpuMoe <n>] [-Ctx <n>]'
  Write-Host ''
  Write-Host '解析「相同参数下 `qwen start` 会用什么 config」，打印完整生效参数 + VRAM 估算。'
  Write-Host '不启动。'
  Write-Host ''
  Write-Host '输出包含：'
  Write-Host '  • Model id, -hf, --alias'
  Write-Host '  • Profile 名 + 来源（explicit / recommended / fallback）'
  Write-Host '  • --n-cpu-moe, -c, -ub, -b, --port'
  Write-Host '  • 估算 idle VRAM (MiB) vs 10 GiB 余量，带颜色标记的余量警告'
  Write-Host ''
  Write-Host '样例：' -ForegroundColor Yellow
  Write-Host '  qwen config                                # 启动时会用什么？'
  Write-Host '  qwen config -Model hauhau-q4kp             # 启动前先看一眼'
  Write-Host '  qwen config -Profile vision'
}

function Show-HelpValidateZh {
  Write-Host 'qwen validate — 校验 models.json' -ForegroundColor Cyan
  Write-Host ''
  Write-Host '  qwen validate'
  Write-Host ''
  Write-Host '读 models.json 并 lint 每个条目。任何问题 exit 1。'
  Write-Host ''
  Write-Host '每个条目检查：'
  Write-Host '  • .hf 和 .alias 存在'
  Write-Host '  • .n_layer 是正整数'
  Write-Host '  • .recommended_profile（如有）是已知 profile 且对应 --n-cpu-moe 不超过 .n_layer'
  Write-Host ''
  Write-Host '全局检查：'
  Write-Host '  • "default" 指向已存在条目'
  Write-Host ''
  Write-Host '改完 models.json 跑一次这个能在启动前抓出拼写错误。'
}

function Show-HelpUiZh {
  Write-Host 'qwen ui — 启动聊天 Web UI' -ForegroundColor Cyan
  Write-Host ''
  Write-Host '  qwen ui [-Port <n>] [-Background]'
  Write-Host ''
  Write-Host '在本地启动 FastAPI 控制台，功能：'
  Write-Host '  • 在 http://127.0.0.1:<port> 提供聊天界面（默认 8090）'
  Write-Host '  • 将 /v1/* 代理到 llama-server（127.0.0.1:8080）'
  Write-Host '  • /api/* 提供模型/profile 切换接口'
  Write-Host ''
  Write-Host '参数' -ForegroundColor Yellow
  Write-Host '  -Port <n>       UI 端口（默认 8090）。llama-server 仍在 8080。'
  Write-Host '  -Background     后台运行；日志写到 logs\qwen-ui.log。'
  Write-Host ''
  Write-Host '前置条件' -ForegroundColor Yellow
  Write-Host '  PATH 中需有 Python 3.8+。首次运行会在 web\.venv 创建虚拟环境。'
  Write-Host '  建议先 qwen start 把 llama-server 跑起来再打开 UI。'
  Write-Host ''
  Write-Host '示例' -ForegroundColor Yellow
  Write-Host '  qwen start -Background              # 先启 llama-server'
  Write-Host '  qwen ui                             # 在浏览器打开 UI（前台）'
  Write-Host '  qwen ui -Background                 # 后台运行'
  Write-Host '  qwen ui -Port 9000                  # 自定义端口'
  Write-Host ''
  Write-Host 'llama-server 端口' -ForegroundColor Yellow
  Write-Host '  若 llama-server 不在 8080，启动前设置：'
  Write-Host '  $env:QWEN_LLAMA_PORT = 9090; qwen ui'
}

# --- Chinese topic pages ---

function Show-HelpOverviewZh {
  Write-Host 'qwen — Qwen3.6-35B-A3B 家族本地 llama-server 管理器' -ForegroundColor Cyan
  Write-Host ''
  Write-Host '用法' -ForegroundColor Yellow
  Write-Host '  qwen <action> [options]                # 跑一个动作'
  Write-Host '  qwen <action> -h                       # 该动作的帮助'
  Write-Host '  qwen help <topic>                      # 跨动作的主题页'
  Write-Host '  qwen help                              # 本概览'
  Write-Host ''
  Write-Host '  (-h / -Help / -? / --help / --h 均可。)'
  Write-Host ''
  Write-Host '动作' -ForegroundColor Yellow
  Write-Host '  start     启动 llama-server（默认动作）'
  Write-Host '  stop      停止运行中的 server（同一时间只能跑一个）'
  Write-Host '  restart   stop + start；每次重新解析 -Model / -Profile / 覆盖参数'
  Write-Host '  status    PID、运行时长、VRAM 占用、监听地址'
  Write-Host '  health    GET /v1/models + 发一个小的 chat completion'
  Write-Host '  config    打印将要使用的启动参数，不启动'
  Write-Host '  validate  校验 models.json（entries、n_layer、recommended_profile）'
  Write-Host '  ui        启动聊天 Web UI（http://127.0.0.1:8090）'
  Write-Host '  help      显示帮助（本页，或 `qwen help <topic> -Zh`）'
  Write-Host ''
  Write-Host '常用命令' -ForegroundColor Yellow
  Write-Host '  qwen start                          # 默认模型 + 默认 profile'
  Write-Host '  qwen start -Model hauhau-q4km       # 切换模型（详见: qwen help models -Zh）'
  Write-Host '  qwen start -Profile longctx         # 切换 profile（详见: qwen help profiles -Zh）'
  Write-Host '  qwen restart -Background            # 后台运行'
  Write-Host '  qwen status                          # 是否在跑'
  Write-Host '  qwen health                          # 是否能正常响应'
  Write-Host '  qwen config -Profile vision         # 仅预览参数，不启动'
  Write-Host ''
  Write-Host '帮助主题' -ForegroundColor Yellow
  Write-Host '  qwen help models -Zh       模型列表与切换（models.json）'
  Write-Host '  qwen help profiles -Zh     Profile cheat sheet（VRAM / 上下文权衡）'
  Write-Host '  qwen help health -Zh       health 检查内容；mismatch 语义'
  Write-Host '  qwen help lan -Zh          LAN / WSL 暴露 + API key'
  Write-Host '  qwen help examples -Zh     更多命令样例'
  Write-Host '  qwen help lang -Zh         设置帮助语言（中/英）'
  Write-Host '  qwen help all              完整 Get-Help 输出（冗长）'
  Write-Host ''
  Write-Host '提示：把 `$env:QWEN_HELP_LANG = "zh"` 写进 $PROFILE，即可永久中文输出。' -ForegroundColor DarkGray
}

function Show-HelpActionsZh {
  Write-Host 'qwen — 动作详细说明' -ForegroundColor Cyan
  Write-Host ''
  Write-Host '  start        启动 llama-server，自动解析模型 + profile。'
  Write-Host '               默认前台运行；-Background 脱离终端。'
  Write-Host '               若已有 server 在跑会报错（请用 restart）。'
  Write-Host ''
  Write-Host '  stop         停止运行中的 llama-server。'
  Write-Host '               即使 models.json 缺失/损坏也能用。'
  Write-Host ''
  Write-Host '  restart      stop + 2 秒等待 + start。'
  Write-Host '               每次都重新解析 -Model / -Profile / -NCpuMoe / -Ctx。'
  Write-Host ''
  Write-Host '  status       PID、启动时间、CPU 时间、内存、VRAM、监听地址。'
  Write-Host '               不访问 models.json。'
  Write-Host ''
  Write-Host '  health       GET /v1/models + 发一个小 chat completion。'
  Write-Host '               带 -Model：若 server 实际 alias 不匹配则 fail-closed。'
  Write-Host '               带 -Model -AllowDifferentModel：降级为 warn-and-probe。'
  Write-Host '               不带 -Model：纯 liveness 探测（不管在跑什么）。'
  Write-Host ''
  Write-Host '  config       打印将要使用的启动 context + VRAM 估算。'
  Write-Host '               包含：model id、hf、alias、profile name、profile 来源、'
  Write-Host '               生效的 NCpuMoe / Ctx / batch sizes / port。'
  Write-Host ''
  Write-Host '  validate     加载 models.json 并 lint 每个条目；任何问题 exit 1。'
  Write-Host '               检查项：hf、alias、n_layer 为正整数、recommended_profile'
  Write-Host '               已知且 NCpuMoe 不超过 n_layer、default 指向已存在条目。'
  Write-Host ''
  Write-Host '  help         本帮助。主题：overview/actions/models/profiles/health/lan/'
  Write-Host '               examples/all。所有主题加 -Zh 切中文。'
}

function Show-HelpModelsZh {
  Write-Host 'qwen — 模型选择' -ForegroundColor Cyan
  Write-Host ''
  Write-Host '模型集中在仓库根目录 models.json 中。解析顺序：'
  Write-Host '  1. -Model <id>            命令行参数（最高优先级）'
  Write-Host '  2. $env:QWEN_MODEL        环境变量（在当前 shell 持久）'
  Write-Host '  3. models.json 的 "default" 字段（兜底）'
  Write-Host ''
  Write-Host '预置条目：' -ForegroundColor Yellow
  try {
    $reg = Get-ModelRegistry -Root $Root
    $ids = @($reg.models | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)
    foreach ($id in $ids) {
      $e = $reg.models.$id
      $marker = if ($id -eq $reg.default) { '（默认）' } else { '' }
      Write-Host ("  {0,-18} {1}  rec_profile={2}{3}" -f $id, $e.alias, $e.recommended_profile, $marker)
    }
  } catch {
    Write-Host "  （读 models.json 失败: $($_.Exception.Message)）" -ForegroundColor DarkGray
  }
  Write-Host ''
  Write-Host '样例：' -ForegroundColor Yellow
  Write-Host '  qwen start                              # 默认模型'
  Write-Host '  qwen start -Model hauhau-q4km           # 临时切换'
  Write-Host '  $env:QWEN_MODEL = "hauhau-iq4nl"        # 当前 shell 持久'
  Write-Host '  qwen restart -Background                #   ↳ 自动读取环境变量'
  Write-Host '  qwen config -Model hauhau-iq2m          # 仅预览，不启动'
  Write-Host ''
  Write-Host '添加新模型：在 models.json 追加一条，至少包含：'
  Write-Host '  { "hf": "...", "alias": "...", "n_layer": <int>, "recommended_profile": "..." }'
  Write-Host '然后 `qwen validate` 确认。'
}

function Show-HelpProfilesZh {
  Write-Host 'qwen — Profiles（VRAM / 上下文权衡）' -ForegroundColor Cyan
  Write-Host ''
  Write-Host 'Profile 是预设的 --n-cpu-moe + --ctx-size 组合，按 Qwen3.6-35B-A3B'
  Write-Host '（n_layer=40）调优。命令行 -Profile 切换即可，不用改 models.json。'
  Write-Host ''
  Write-Host 'Profile 解析顺序：' -ForegroundColor Yellow
  Write-Host '  1. -Profile <name>                    命令行显式参数'
  Write-Host '  2. model.recommended_profile          模型条目里的默认 profile'
  Write-Host '  3. "balanced"                          兜底'
  Write-Host ''
  Write-Host '预设：' -ForegroundColor Yellow
  Write-Host '  safe       N=31, ctx=16384   余量 ~540 MB；桌面应用多时用'
  Write-Host '  balanced   N=29, ctx=24576   sweep 最优（纯文本）          [默认]'
  Write-Host '  longctx    N=30, ctx=32768   略慢但 ctx 最长'
  Write-Host '  conserve   N=33, ctx=8192    释放 ~1 GB VRAM 给其他 GPU 任务'
  Write-Host '  vision     N=35, ctx=16384   + mmproj 加载，启用图像输入'
  Write-Host ''
  Write-Host '样例：' -ForegroundColor Yellow
  Write-Host '  qwen start -Profile safe                        # 切换 profile'
  Write-Host '  qwen start -Profile balanced -NCpuMoe 30 -Ctx 16384   # 在 profile 上叠加覆盖'
  Write-Host '  qwen config -Profile vision                     # 仅预览'
  Write-Host '  qwen restart -Profile longctx -Background       # 切到新 profile 重启'
  Write-Host ''
  Write-Host '约束：-NCpuMoe 必须 ∈ [0, model.n_layer]（当前所有模型都是 0..40）。'
  Write-Host '超出会在启动前报错，而不是让 llama-server 自己挂掉。'
  Write-Host ''
  Write-Host '如果想给某个模型固定一个默认 profile（避免每次都打 -Profile），'
  Write-Host '把它的 `recommended_profile` 字段写进 models.json 即可。'
}

function Show-HelpHealthZh {
  Write-Host 'qwen — health 检查语义' -ForegroundColor Cyan
  Write-Host ''
  Write-Host '`qwen health` 执行：'
  Write-Host '  1. GET /v1/models    — server 不可达或返回空则失败'
  Write-Host '  2. POST /v1/chat/completions 发一句测试 prompt'
  Write-Host '  3. 打印 wall_time / gen_tok_per_sec / prompt_tok_per_sec / response'
  Write-Host ''
  Write-Host '模型期望行为：'
  Write-Host '  不带 -Model        探测当前在跑的模型（仅 liveness 检查）'
  Write-Host '  带 -Model X        FAIL-CLOSED：若 X 不在 /v1/models 里则 exit 1，'
  Write-Host '                     打印 expected vs served 的明确错误。'
  Write-Host '                     这是唯一能验证「你想要的模型确实加载了」的方式。'
  Write-Host '  带 -Model X -AllowDifferentModel'
  Write-Host '                     诊断模式 — 报警但继续探测 server 实际 alias。'
  Write-Host '                     适合调试别人启动的 server。'
  Write-Host ''
  Write-Host '退出码：'
  Write-Host '  0  ok                    1  请求失败 / 模型不匹配'
  Write-Host '  2  server 不可达         （或：无法解析 -Model）'
  Write-Host ''
  Write-Host '样例：' -ForegroundColor Yellow
  Write-Host '  qwen health                                # 任意模型'
  Write-Host '  qwen health -Model hauhau-q4km             # 必须是 hauhau 在跑'
  Write-Host '  qwen health -Model hauhau-q4km -AllowDifferentModel   # 不匹配也探测'
}

function Show-HelpLanZh {
  Write-Host 'qwen — LAN / WSL 访问' -ForegroundColor Cyan
  Write-Host ''
  Write-Host '默认绑定 127.0.0.1（仅本机，无鉴权）。LAN 暴露：'
  Write-Host ''
  Write-Host '  qwen start -Lan'
  Write-Host ''
  Write-Host '该模式会：'
  Write-Host '  • 改绑 0.0.0.0:8080'
  Write-Host '  • 在 <repo>\.apikey 生成 32-byte API key（仅当前用户可读）'
  Write-Host '  • 通过 --api-key-file 传给 llama-server（key 不进进程命令行）'
  Write-Host '  • 尝试创建 Windows 防火墙入站规则（首次需要 admin；失败时打印手动命令）'
  Write-Host ''
  Write-Host '客户端必须发 `Authorization: Bearer <.apikey 内容>` 头。'
  Write-Host '/v1/models 不需 key（这是 llama.cpp 上游行为）。'
  Write-Host ''
  Write-Host '绑定 0.0.0.0 后，`qwen status` 会打印 LAN endpoint（LAN IP + port）。'
  Write-Host ''
  Write-Host 'WSL：访问 Windows 主机的 LAN IP（不是 127.0.0.1）— 见 status 输出。'
}

function Show-HelpExamplesZh {
  Write-Host 'qwen — 常见命令样例' -ForegroundColor Cyan
  Write-Host ''
  Write-Host '# 日常使用'
  Write-Host '  qwen start                                # 前台，默认模型 + 默认 profile'
  Write-Host '  qwen start -Background                    # 后台'
  Write-Host '  qwen status'
  Write-Host '  qwen health'
  Write-Host '  qwen stop'
  Write-Host ''
  Write-Host '# 切换模型 / profile'
  Write-Host '  qwen start -Model hauhau-q4km'
  Write-Host '  qwen restart -Model hauhau-iq2m -Profile longctx'
  Write-Host '  qwen config -Model hauhau-q4kp            # 会用什么参数？'
  Write-Host ''
  Write-Host '# 当前 shell 持久化模型选择'
  Write-Host '  $env:QWEN_MODEL = "hauhau-q4km"'
  Write-Host '  qwen restart -Background'
  Write-Host ''
  Write-Host '# 在 profile 上叠加微调'
  Write-Host '  qwen start -Profile balanced -NCpuMoe 30 -Ctx 16384'
  Write-Host ''
  Write-Host '# LAN 暴露 + 自动生成 API key'
  Write-Host '  qwen start -Lan -Background'
  Write-Host ''
  Write-Host '# 验证想要的模型是否真的在跑'
  Write-Host '  qwen health -Model hauhau-q4km            # 若 server 跑的是 unsloth 则 fail'
  Write-Host ''
  Write-Host '# 维护'
  Write-Host '  qwen validate                             # 校验 models.json'
  Write-Host '  qwen config -Profile vision               # -Background 前预览'
}

# ===== Dispatch =====
# Promote help-flag synonyms in either the action or topic slot to -Help.
# Catches: qwen --help / qwen -h / qwen start --help / qwen start -h.
$helpLikeValues = @('--help','--h','-help','-h','-?','—help','help')
if ($Action -and ($helpLikeValues -contains $Action.ToLower()) -and $Action -ne 'help') {
  # User typed e.g. `qwen --help` — treat as overview.
  $Action = 'start'        # restore default so dispatch logic is simple
  $Help = $true
  # Clear $PSBoundParameters flag so the no-action-passed path triggers.
  $PSBoundParameters.Remove('Action') | Out-Null
}
if ($Topic -and ($helpLikeValues -contains $Topic.ToLower()) -and $Topic.ToLower() -ne 'help') {
  $Help = $true
  $Topic = $null
}

# -Help (-h / -?) on any action shows help for that action and exits.
# `qwen -h` alone (no action) shows the overview, not the default-action help.
if ($Help) {
  $actionPassed = $PSBoundParameters.ContainsKey('Action')
  if (-not $actionPassed) {
    $topicForHelp = ''   # overview
  } elseif ($Action -eq 'help' -and $Topic) {
    $topicForHelp = $Topic
  } else {
    $topicForHelp = $Action
  }
  Show-Help -Topic $topicForHelp -En:$En -Zh:$Zh
  return
}

switch ($Action) {
  'validate'{ Test-RegistryConfig }
  'start'   { Invoke-WithCleanErrors { Start-Server } }
  'stop'    { Stop-Server }
  'restart' { Invoke-WithCleanErrors {
    # Resolve and validate launch context BEFORE stopping the running server.
    # If models.json is bad, the model is unknown, or the profile is invalid,
    # the error is raised here and the current server is left untouched.
    $ctx = Resolve-LaunchContext
    Stop-Server
    Start-Sleep -Seconds 2
    Start-Server -PreResolvedCtx $ctx
  }}
  'status'  { Show-Status }
  'health'  { Invoke-WithCleanErrors { Test-Health } }
  'config'  { Invoke-WithCleanErrors { Show-Config } }
  'help'    { Show-Help -Topic $Topic -En:$En -Zh:$Zh }
  'ui'      {
    $uiArgs = @{}
    if ($PSBoundParameters.ContainsKey('Port'))       { $uiArgs['Port']       = $Port }
    if ($PSBoundParameters.ContainsKey('Background')) { $uiArgs['Background'] = $Background }
    & "$PSScriptRoot\qwen-ui.ps1" @uiArgs
  }
}
