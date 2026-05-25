<#
.SYNOPSIS
    Launch the qwen-ui chat interface (FastAPI + uvicorn).

.DESCRIPTION
    Creates a Python venv on first run, installs requirements, then starts
    uvicorn on localhost. The control plane proxies to llama-server on :8080.

.PARAMETER Port
    Port for the web UI (default: 8090).

.PARAMETER Background
    Start as a background process (detached, logs to logs\qwen-ui.log).

.PARAMETER NoBrowser
    Do not open the browser automatically.
#>
[CmdletBinding()]
param(
    [int]   $Port       = 8090,
    [switch]$Background,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$webDir   = Join-Path $repoRoot 'web'
$venvDir  = Join-Path $webDir '.venv'
$python   = Join-Path $venvDir 'Scripts' 'python.exe'
$pip      = Join-Path $venvDir 'Scripts' 'pip.exe'
$uvi      = Join-Path $venvDir 'Scripts' 'uvicorn.exe'
$req      = Join-Path $webDir 'requirements.txt'

if (-not (Test-Path $python)) {
    Write-Host "Setting up Python venv at $venvDir ..."
    python -m venv $venvDir
    & $pip install -q -r $req
    Write-Host "Done."
}

$url = "http://127.0.0.1:$Port"
Write-Host "qwen-ui  ->  $url"

if (-not $NoBrowser) {
    try { Start-Process $url } catch {}
}

if ($Background) {
    $logDir  = Join-Path $repoRoot 'logs'
    New-Item -ItemType Directory -Force $logDir | Out-Null
    $logFile = Join-Path $logDir 'qwen-ui.log'
    Start-Process -FilePath $uvi `
        -ArgumentList "app:app", "--host", "127.0.0.1", "--port", "$Port" `
        -WorkingDirectory $webDir `
        -RedirectStandardOutput $logFile `
        -WindowStyle Hidden
    Write-Host "Running in background.  Log: $logFile"
} else {
    Push-Location $webDir
    try {
        & $uvi app:app --host 127.0.0.1 --port $Port
    } finally {
        Pop-Location
    }
}
