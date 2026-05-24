# Health check: hits llama-server at 127.0.0.1:8080 and runs a short Chinese chat completion
# Saves JSON to logs\03-health-check.json and prints token/sec from server's response metadata.

$ErrorActionPreference = 'Stop'
$Endpoint = 'http://127.0.0.1:8080'
$LogDir = "$(Split-Path -Parent $PSScriptRoot)\logs"

Write-Host "GET $Endpoint/v1/models" -ForegroundColor DarkGray
$models = Invoke-RestMethod -Uri "$Endpoint/v1/models" -Method Get
$models | ConvertTo-Json -Depth 6 | Out-File "$LogDir\03-models.json" -Encoding utf8
Write-Host ("  available: " + ($models.data.id -join ', ')) -ForegroundColor Green
Write-Host ""

$Body = @{
  model       = 'qwen3.6-35b-a3b'
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
