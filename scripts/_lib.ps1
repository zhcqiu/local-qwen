# Shared helpers for the qwen scripts. Dot-source from a sibling script:
#   . "$PSScriptRoot\_lib.ps1"

function Get-RepoRoot {
  # scripts/_lib.ps1 -> scripts/ -> repo root
  return (Split-Path -Parent $PSScriptRoot)
}

function Get-ModelRegistry {
  param([string]$Root = (Get-RepoRoot))
  $path = Join-Path $Root 'models.json'
  if (-not (Test-Path $path)) {
    throw "models.json not found at $path"
  }
  $raw = Get-Content $path -Raw
  try {
    $reg = $raw | ConvertFrom-Json -ErrorAction Stop
  } catch {
    throw "models.json at $path is not valid JSON: $($_.Exception.Message)"
  }
  if (-not $reg.default)              { throw "models.json is missing 'default' field." }
  if (-not $reg.models)               { throw "models.json is missing 'models' object." }
  return $reg
}

function Resolve-ModelId {
  # Precedence: explicit CLI -Model > $env:QWEN_MODEL > registry default
  param(
    [string]$Explicit,
    $Registry
  )
  if ($Explicit)                  { return $Explicit }
  if ($env:QWEN_MODEL)            { return $env:QWEN_MODEL }
  return $Registry.default
}

function Get-ModelConfig {
  # Returns a hashtable for the resolved model with all keys flattened.
  # Throws if the id is unknown.
  param(
    [string]$ModelId,
    $Registry
  )
  $entry = $Registry.models.$ModelId
  if (-not $entry) {
    $known = ($Registry.models | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name) -join ', '
    throw "Unknown model id '$ModelId'. Known ids: $known"
  }
  # Convert PSCustomObject -> hashtable for convenient access; add id for callers.
  $h = @{ id = $ModelId }
  foreach ($p in $entry.PSObject.Properties) { $h[$p.Name] = $p.Value }
  return $h
}

function Resolve-Model {
  # One-shot helper: load registry, resolve id, return config + id.
  param([string]$Explicit, [string]$Root = (Get-RepoRoot))
  $reg = Get-ModelRegistry -Root $Root
  $id  = Resolve-ModelId -Explicit $Explicit -Registry $reg
  return (Get-ModelConfig -ModelId $id -Registry $reg)
}

function Get-ModelMmprojPath {
  # Returns absolute path where the mmproj file for this model is (or will be) stored.
  # Downloads if missing and mmproj_url is set. Returns $null if model has no mmproj.
  # Download is atomic: writes to <file>.part, validates status + non-empty size,
  # then renames into place. Partial downloads never become the canonical file.
  param($Model, [string]$Root = (Get-RepoRoot), [switch]$AutoDownload)
  if (-not $Model.mmproj_file) { return $null }
  $abs = Join-Path $Root $Model.mmproj_file
  if (Test-Path $abs) { return $abs }
  if (-not $AutoDownload) { return $abs }   # caller can decide what to do
  if (-not $Model.mmproj_url) {
    throw "mmproj missing for $($Model.id) and no mmproj_url defined."
  }
  $dir = Split-Path $abs -Parent
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $tmp = "$abs.part"
  # Clean up any stray partial from a prior interrupted run.
  if (Test-Path $tmp) { Remove-Item -Force $tmp }
  Write-Host "Downloading mmproj for $($Model.id) -> $abs" -ForegroundColor Yellow
  try {
    $resp = Invoke-WebRequest -Uri $Model.mmproj_url -OutFile $tmp -PassThru -UseBasicParsing -ErrorAction Stop
    if ($resp.StatusCode -ne 200) {
      throw "HTTP $($resp.StatusCode) from $($Model.mmproj_url)"
    }
    $size = (Get-Item $tmp).Length
    # Any real mmproj is many MB; <1 MB usually means an error page or a redirect HTML body.
    if ($size -lt 1MB) {
      throw "downloaded file is only $size bytes (< 1 MB); likely an error page rather than a GGUF"
    }
    # Optional integrity check: caller can declare expected size in models.json.
    if ($Model.mmproj_size_bytes) {
      $expected = [int64]$Model.mmproj_size_bytes
      if ($size -ne $expected) {
        throw "size mismatch: got $size bytes, expected $expected"
      }
    }
    Move-Item -Force -Path $tmp -Destination $abs
  } catch {
    if (Test-Path $tmp) { Remove-Item -Force $tmp -ErrorAction SilentlyContinue }
    throw "mmproj download failed: $($_.Exception.Message)"
  }
  return $abs
}
