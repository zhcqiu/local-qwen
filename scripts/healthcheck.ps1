# Health check: hits llama-server at 127.0.0.1:8080 and runs a short Chinese chat completion.
# Saves JSON to logs\03-health-check.json and prints token/sec from server's response metadata.
#
# The request always targets whichever alias the server actually serves (queried via /v1/models).
# -Model and $env:QWEN_MODEL only affect the expected alias used for the mismatch warning;
# they do NOT override what gets sent to the server. This avoids false failures when the
# caller's local config drifts from the running server.

param(
  [string]$Model,
  [string]$Endpoint = 'http://127.0.0.1:8080'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_lib.ps1"

$ExpectedAlias = $null
$ExpectedId    = $null
if ($Model -or $env:QWEN_MODEL) {
  $ModelCfg = Resolve-Model -Explicit $Model
  $ExpectedAlias = $ModelCfg.alias
  $ExpectedId    = $ModelCfg.id
  Write-Host "Expected : $ExpectedId  (alias: $ExpectedAlias)" -ForegroundColor Cyan
}

$LogDir = "$(Get-RepoRoot)\logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

Write-Host "GET $Endpoint/v1/models" -ForegroundColor DarkGray
$models = Invoke-RestMethod -Uri "$Endpoint/v1/models" -Method Get
$models | ConvertTo-Json -Depth 6 | Out-File "$LogDir\03-models.json" -Encoding utf8
$serverAliases = @($models.data.id)
Write-Host ("  served   : " + ($serverAliases -join ', ')) -ForegroundColor Green

# Pick the alias to send. If the user passed -Model and it matches a served alias, prefer that
# (handles future multi-slot setups). Otherwise just use whatever the server exposes first.
if ($ExpectedAlias -and ($serverAliases -contains $ExpectedAlias)) {
  $Alias = $ExpectedAlias
} else {
  $Alias = $serverAliases | Select-Object -First 1
  if ($ExpectedAlias -and $ExpectedAlias -ne $Alias) {
    Write-Host ("  WARNING: expected alias '$ExpectedAlias' not served. Using '$Alias' instead.") -ForegroundColor Yellow
    Write-Host  "           (server may be running a different model than your local -Model / `$env:QWEN_MODEL.)" -ForegroundColor Yellow
  }
}
Write-Host ("  using    : $Alias") -ForegroundColor Green
Write-Host ""

$Body = @{
  model       = $Alias
  messages    = @(@{ role = 'user'; content = '用中文用三句话解释 MoE 模型为什么适合消费级显卡本地运行。' })
  temperature = 0.3
  max_tokens  = 256
  stream      = $false
} | ConvertTo-Json -Depth 10

Write-Host "POST $Endpoint/v1/chat/completions" -ForegroundColor DarkGray
$t0 = Get-Date
$resp = Invoke-RestMethod -Uri "$Endpoint/v1/chat/completions" -Method Post -ContentType 'application/json' -Body $Body
$wall = (Get-Date) - $t0

$resp | ConvertTo-Json -Depth 10 | Out-File "$LogDir\03-health-check.json" -Encoding utf8

Write-Host ""
Write-Host "=== RESPONSE ===" -ForegroundColor Cyan
Write-Host $resp.choices[0].message.content
Write-Host ""
Write-Host "=== STATS ===" -ForegroundColor Cyan
Write-Host ("wall_time           : {0:N2} s" -f $wall.TotalSeconds)
Write-Host ("prompt_tokens       : {0}" -f $resp.usage.prompt_tokens)
Write-Host ("completion_tokens   : {0}" -f $resp.usage.completion_tokens)
if ($resp.timings) {
  Write-Host ("prompt_per_token_ms : {0:N2}" -f $resp.timings.prompt_per_token_ms)
  Write-Host ("prompt_tok_per_sec  : {0:N2}" -f $resp.timings.prompt_per_second)
  Write-Host ("predict_per_token_ms: {0:N2}" -f $resp.timings.predicted_per_token_ms)
  Write-Host ("gen_tok_per_sec     : {0:N2}" -f $resp.timings.predicted_per_second)
}
