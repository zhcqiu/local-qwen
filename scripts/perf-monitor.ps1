# Sample VRAM, RAM, GPU util every 2 seconds for $DurationSec seconds.
# Run this DURING a chat completion to capture the peak working set.
# Output: logs\04-performance-baseline.txt + a CSV.

param(
  [int]$DurationSec = 60
)

$LogDir = "$(Split-Path -Parent $PSScriptRoot)\logs"
$Stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$Csv    = "$LogDir\perf-$Stamp.csv"
$Txt    = "$LogDir\04-performance-baseline.txt"

"timestamp,gpu_mem_used_MiB,gpu_mem_free_MiB,gpu_util_pct,gpu_temp_C,ram_used_MB,ram_free_MB" | Out-File $Csv -Encoding utf8

$end = (Get-Date).AddSeconds($DurationSec)
while ((Get-Date) -lt $end) {
  $smi = (& nvidia-smi --query-gpu=memory.used,memory.free,utilization.gpu,temperature.gpu --format=csv,noheader,nounits) -split ','
  $os  = Get-CimInstance Win32_OperatingSystem
  $ramFree = [math]::Round($os.FreePhysicalMemory / 1024, 0)
  $ramUsed = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1024, 0)
  $line = "{0},{1},{2},{3},{4},{5},{6}" -f (Get-Date -Format 'HH:mm:ss'), $smi[0].Trim(), $smi[1].Trim(), $smi[2].Trim(), $smi[3].Trim(), $ramUsed, $ramFree
  $line | Tee-Object -FilePath $Csv -Append
  Start-Sleep -Seconds 2
}

# Aggregate
$rows = Import-Csv $Csv
$peakVram = ($rows | Measure-Object gpu_mem_used_MiB -Maximum).Maximum
$peakUtil = ($rows | Measure-Object gpu_util_pct -Maximum).Maximum
$peakRam  = ($rows | Measure-Object ram_used_MB -Maximum).Maximum
$maxTemp  = ($rows | Measure-Object gpu_temp_C -Maximum).Maximum

@"
=== Performance baseline $Stamp ===
duration_sec  : $DurationSec
peak VRAM     : $peakVram MiB
peak GPU util : $peakUtil %
peak GPU temp : $maxTemp C
peak sys RAM  : $peakRam MB
csv           : $Csv
"@ | Tee-Object -FilePath $Txt
