param(
  [ValidateSet('On', 'Recover', 'Off', 'Status', 'Doctor')]
  [string]$Action = 'Status'
)

$ErrorActionPreference = 'Stop'
$settingsPath = Join-Path $env:LOCALAPPDATA 'codex-bridge-desktop\settings.json'
if (-not (Test-Path -LiteralPath $settingsPath)) {
  throw 'Run the installer to choose an approved project folder first.'
}
$settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
$approvedRoot = [IO.Path]::GetFullPath([string]$settings.projectRoot).TrimEnd('\')
$rootItem = Get-Item -LiteralPath $approvedRoot -ErrorAction Stop
if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
  throw 'The approved project root must be a real directory, not a link.'
}
$driveRoot = [IO.Path]::GetPathRoot($approvedRoot).TrimEnd('\')
$profileRoot = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')
if ($approvedRoot.Equals($driveRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $approvedRoot.Equals($profileRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $profileRoot.StartsWith($approvedRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
  throw 'Choose a narrow project folder, not a drive root or the whole user profile.'
}

$controller = Join-Path $env:USERPROFILE '.codex\skills\codex-chatgpt-bridge\scripts\bridge_controller.ps1'
if (-not (Test-Path -LiteralPath $controller)) {
  throw "Bridge controller is missing: $controller"
}
$bridge = Join-Path $env:USERPROFILE '.codex\skills\codex-chatgpt-bridge\scripts\local_bridge.ps1'
if (-not (Test-Path -LiteralPath $bridge)) {
  throw "Bridge runtime script is missing: $bridge"
}

function Invoke-Controller {
  param(
    [string]$Operation,
    [string[]]$ExtraArgs = @(),
    [switch]$AllowUnhealthy
  )

  $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $controller -Action $Operation @ExtraArgs
  $exitCode = $LASTEXITCODE
  try {
    $result = ($output | Out-String) | ConvertFrom-Json
  } catch {
    throw "The bridge controller did not return valid JSON for $Operation."
  }
  if ($exitCode -ne 0 -and -not $AllowUnhealthy) {
    throw "Bridge $Operation failed: $($result.message)"
  }
  return $result
}

function Assert-BridgeProfile {
  param([string]$ExpectedProjectRoot)
  $profilePath = Join-Path $env:LOCALAPPDATA 'devspace-bridge\controller-profile.json'
  $profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
  $roots = @($profile.allowedRoots)
  if (-not $profile.projectRoot.Equals($ExpectedProjectRoot, [StringComparison]::OrdinalIgnoreCase) -or
      $roots.Count -ne 1 -or
      -not ([string]$roots[0]).Equals($ExpectedProjectRoot, [StringComparison]::OrdinalIgnoreCase) -or
      $profile.tunnel -ne 'cloudflare') {
    throw 'Bridge profile is outside the approved project scope.'
  }
  $doctor = Invoke-Controller -Operation Doctor -AllowUnhealthy
  if (@($doctor.securityWarnings).Count -gt 0) {
    throw "Bridge security warnings: $($doctor.securityWarnings -join ', ')"
  }
  if (-not $doctor.restartReady) {
    throw "Bridge is not ready: $($doctor.readinessIssues -join ', ')"
  }
  return $doctor
}

function Clear-StaleQuickTunnelUrl {
  $profilePath = Join-Path $env:LOCALAPPDATA 'devspace-bridge\controller-profile.json'
  $profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
  if ($profile.tunnel -ne 'cloudflare' -or -not $profile.publicBaseUrl) { return }

  # A Quick Tunnel gets a fresh address on every start. The controller otherwise
  # retains the previous address and rejects the healthy new runtime as a mismatch.
  $profile.publicBaseUrl = $null
  $tempPath = "$profilePath.$([guid]::NewGuid().ToString('N')).tmp"
  try {
    [IO.File]::WriteAllText($tempPath, ($profile | ConvertTo-Json -Depth 10))
    Move-Item -LiteralPath $tempPath -Destination $profilePath -Force
  } finally {
    Remove-Item -LiteralPath $tempPath -ErrorAction SilentlyContinue
  }
}

function Get-TunnelTraffic {
  param($RuntimeState)
  if (-not $RuntimeState -or -not $RuntimeState.tunnelProcessId) { return $null }
  try {
    $null = Get-Process -Id ([int]$RuntimeState.tunnelProcessId) -ErrorAction Stop
    $logPath = [string]$RuntimeState.logs.tunnel
    $logRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'devspace-bridge\logs'))
    $fullLogPath = [IO.Path]::GetFullPath($logPath)
    if (-not $fullLogPath.StartsWith($logRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return $null }
    $log = Get-Content -LiteralPath $fullLogPath -TotalCount 100 -ErrorAction Stop
    $port = $null
    foreach ($line in $log) {
      if ($line -match 'Starting metrics server on 127\.0\.0\.1:(\d+)/metrics') { $port = [int]$Matches[1] }
    }
    if (-not $port) { return $null }
    $metrics = (Invoke-WebRequest -Uri "http://127.0.0.1:$port/metrics" -UseBasicParsing -TimeoutSec 2).Content
    $sent = [double]0; $received = [double]0; $requests = [double]0
    $foundSent = $false; $foundReceived = $false
    foreach ($line in ($metrics -split "`n")) {
      if ($line -match '^quic_client_sent_bytes(?:\{[^}]*\})?\s+([0-9]+(?:\.[0-9]+)?)') {
        $sent += [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture); $foundSent = $true
      } elseif ($line -match '^quic_client_receive_bytes(?:\{[^}]*\})?\s+([0-9]+(?:\.[0-9]+)?)') {
        $received += [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture); $foundReceived = $true
      } elseif ($line -match '^cloudflared_tunnel_total_requests\s+([0-9]+(?:\.[0-9]+)?)') {
        $requests = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
      }
    }
    if (-not $foundSent -or -not $foundReceived) { return $null }
    return [pscustomobject]@{ sentBytes = [long]$sent; receivedBytes = [long]$received; requests = [long]$requests }
  } catch { return $null }
}

$startAttempted = $false
try {
  switch ($Action) {
    'On' {
      $projectRoot = $approvedRoot
      $status = Invoke-Controller -Operation Status
      if ($status.runtimeState) {
        $savedRoots = @($status.profile.allowedRoots)
        if (-not $status.profile.projectRoot.Equals($projectRoot, [StringComparison]::OrdinalIgnoreCase) -or
            $savedRoots.Count -ne 1 -or
            -not ([string]$savedRoots[0]).Equals($projectRoot, [StringComparison]::OrdinalIgnoreCase)) {
          $null = Invoke-Controller -Operation Off
        }
      }
      $startAttempted = $true
      $null = Invoke-Controller -Operation Configure -ExtraArgs @(
        '-ProjectRoot', $projectRoot,
        '-AllowedRoots', $projectRoot,
        '-Tunnel', 'cloudflare',
        '-InstallCloudflared'
      )
      Clear-StaleQuickTunnelUrl
      $null = Assert-BridgeProfile -ExpectedProjectRoot $projectRoot
      $result = Invoke-Controller -Operation On
      if ($result.status -ne 'success' -or -not $result.data.health.healthy) {
        throw 'Bridge On did not pass its health check.'
      }
      Write-Host 'Bridge is on and healthy.'
      Write-Host "ChatGPT MCP URL: $($result.data.runtime.mcpUrl)"
      Write-Host 'The temporary URL may change next time. Use bridge.cmd off when finished.'
    }
    'Recover' {
      $null = Assert-BridgeProfile -ExpectedProjectRoot $approvedRoot
      $result = Invoke-Controller -Operation Restart
      if ($result.status -ne 'success' -or -not $result.data.health.healthy) {
        throw 'Bridge recovery did not pass its health check.'
      }
      Write-Host 'Bridge is on and healthy.'
      Write-Host "ChatGPT MCP URL: $($result.data.runtime.mcpUrl)"
    }
    'Off' {
      $result = Invoke-Controller -Operation Off
      $remaining = @($result.data.remainingDevspace).Count +
        @($result.data.remainingTunnel).Count +
        @($result.data.remainingPortOwners).Count
      if ($result.status -ne 'success' -or $remaining -gt 0) {
        throw 'Bridge shutdown could not confirm that all managed processes stopped.'
      }
      Write-Host 'Bridge is off. No bridge or tunnel process remains.'
    }
    'Status' {
      $result = Invoke-Controller -Operation Status
      $doctor = Invoke-Controller -Operation Doctor -AllowUnhealthy
      [pscustomobject]@{
        desiredState = $result.desiredState.state
        projectRoot = $result.profile.projectRoot
        allowedRoots = @($result.profile.allowedRoots)
        tunnel = $result.profile.tunnel
        mcpUrl = if ($result.runtimeState) { $result.runtimeState.mcpUrl } else { $null }
        startedAt = if ($result.runtimeState) { $result.runtimeState.startedAt } else { $null }
        devspaceProcessId = if ($result.runtimeState) { $result.runtimeState.devspaceProcessId } else { $null }
        tunnelProcessId = if ($result.runtimeState) { $result.runtimeState.tunnelProcessId } else { $null }
        traffic = Get-TunnelTraffic -RuntimeState $result.runtimeState
        runtimeHealthy = [bool]$doctor.runtimeHealthy
        restartReady = [bool]$doctor.restartReady
        securityWarnings = @($doctor.securityWarnings)
        readinessIssues = @($doctor.readinessIssues)
      } | ConvertTo-Json -Depth 5
    }
    'Doctor' {
      $result = Invoke-Controller -Operation Doctor -AllowUnhealthy
      [pscustomobject]@{
        runtimeHealthy = $result.runtimeHealthy
        restartReady = $result.restartReady
        securityWarnings = @($result.securityWarnings)
        readinessIssues = @($result.readinessIssues)
      } | ConvertTo-Json -Depth 5
    }
  }
} catch {
  [Console]::Error.WriteLine($_.Exception.Message)
  if ($startAttempted) {
    # Close any partial runtime while preserving the controller's running intent for bounded recovery.
    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bridge -Action Stop
  }
  exit 1
}

# Doctor intentionally exits 1 while the bridge is stopped. Status consumes that
# report as data, so do not let its native exit code become this script's result.
exit 0
