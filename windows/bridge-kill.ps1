$ErrorActionPreference = 'Stop'
$hostPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Codex Bridge.exe'))
$trayPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'bridge-tray.ps1'))
$trayRecordPath = Join-Path $env:LOCALAPPDATA 'devspace-bridge\tray-process.json'
$control = Join-Path $PSScriptRoot 'bridge-control.ps1'
$powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Get-HostIds {
  @(
    Get-Process -Name 'Codex Bridge' -ErrorAction SilentlyContinue |
      Where-Object {
        try { $_.Path -and [IO.Path]::GetFullPath($_.Path).Equals($hostPath, [StringComparison]::OrdinalIgnoreCase) }
        catch { $false }
      } |
      ForEach-Object { $_.Id }
  )
}

function Get-TrayIds {
  $ids = @()
  try {
    $record = Get-Content -LiteralPath $trayRecordPath -Raw -ErrorAction Stop | ConvertFrom-Json
    $process = Get-Process -Id ([int]$record.pid) -ErrorAction Stop
    if ($process.ProcessName -eq 'powershell' -and
        $process.StartTime.ToUniversalTime().Ticks -eq [long]$record.startTicks) {
      $ids += $process.Id
    }
  } catch { }
  try {
    $ids += @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
      Where-Object {
        $_.CommandLine -match '[-]File' -and
        $_.CommandLine -match [regex]::Escape($trayPath)
      } | ForEach-Object { $_.ProcessId })
  } catch { }
  @($ids | Sort-Object -Unique)
}

function Stop-HungControllers {
  $scripts = @(
    (Join-Path $env:USERPROFILE '.codex\skills\codex-chatgpt-bridge\scripts\bridge_controller.ps1'),
    (Join-Path $env:USERPROFILE '.codex\skills\codex-chatgpt-bridge\scripts\local_bridge.ps1')
  )
  try {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
      Where-Object {
        $command = [string]$_.CommandLine
        if ($command -notmatch '[-]File') { return $false }
        foreach ($script in $scripts) {
          if ($command -match [regex]::Escape($script)) { return $true }
        }
        return $false
      } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  } catch { }
}

# Ask the tray to close normally first so it records an intentional Off state.
try {
  $signal = [System.Threading.EventWaitHandle]::OpenExisting('Local\CodexChatGPTBridgeTrayExit')
  $null = $signal.Set()
  $signal.Dispose()
} catch { }

$deadline = (Get-Date).AddSeconds(15)
do {
  $hosts = @(Get-HostIds)
  $trays = @(Get-TrayIds)
  if ($hosts.Count -eq 0 -and $trays.Count -eq 0) { break }
  Start-Sleep -Milliseconds 500
} while ((Get-Date) -lt $deadline)

# Forced fallback is limited to this EXE path and the verified tray process.
foreach ($id in @(Get-HostIds)) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500
foreach ($id in @(Get-TrayIds)) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }

$stopped = $false
$lastOutput = ''
for ($attempt = 1; $attempt -le 5; $attempt++) {
  $result = & $powerShell -NoProfile -ExecutionPolicy Bypass -File $control -Action Off 2>&1
  $lastOutput = ($result | Out-String).Trim()
  if ($LASTEXITCODE -eq 0 -and $lastOutput -match 'Bridge is off') {
    $stopped = $true
    break
  }
  if ($attempt -eq 2 -and $lastOutput -match 'Another bridge controller operation') {
    Stop-HungControllers
  }
  if ($attempt -lt 5) { Start-Sleep -Seconds 2 }
}
if (-not $stopped) { throw "The tray was closed, but bridge shutdown could not be confirmed. $lastOutput" }
if (@(Get-HostIds).Count -gt 0 -or @(Get-TrayIds).Count -gt 0) {
  throw 'Bridge shutdown succeeded, but a tray process remains.'
}
Write-Output 'Codex Bridge tray, local bridge, and tunnel are stopped.'