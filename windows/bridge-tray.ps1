$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$iconRoot = Join-Path $PSScriptRoot 'bridge-icons'
$script:icons = @{}
foreach ($name in @('off', 'on', 'checking', 'error')) {
  $path = Join-Path $iconRoot ("bridge-$name.ico")
  if (-not (Test-Path -LiteralPath $path)) { throw "Bridge tray icon is missing: $path" }
  $script:icons[$name] = New-Object System.Drawing.Icon($path)
}

# A second launch raises the existing window instead of adding another tray icon.
$created = $false
$mutex = [System.Threading.Mutex]::new($true, 'Local\CodexChatGPTBridgeTray', [ref]$created)
if (-not $created) {
  try {
    $other = [System.Threading.EventWaitHandle]::OpenExisting('Local\CodexChatGPTBridgeTrayShow')
    $null = $other.Set()
    $other.Dispose()
  } catch { }
  $mutex.Dispose()
  exit 0
}
$showSignal = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::AutoReset, 'Local\CodexChatGPTBridgeTrayShow')
$exitSignal = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::AutoReset, 'Local\CodexChatGPTBridgeTrayExit')
$script:trayPidPath = Join-Path $env:LOCALAPPDATA 'devspace-bridge\tray-process.json'
$script:trayStartTicks = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
try {
  $null = New-Item -ItemType Directory -Path (Split-Path -Parent $script:trayPidPath) -Force
  [IO.File]::WriteAllText($script:trayPidPath, (@{ pid = $PID; startTicks = $script:trayStartTicks } | ConvertTo-Json -Compress))
} catch { }

$script:controller = Join-Path $PSScriptRoot 'bridge-control.ps1'
$settingsPath = Join-Path $env:LOCALAPPDATA 'codex-bridge-desktop\settings.json'
if (-not (Test-Path -LiteralPath $settingsPath)) { throw 'Run the installer before starting the bridge tray.' }
$settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
$script:projectRoot = [IO.Path]::GetFullPath([string]$settings.projectRoot).TrimEnd('\')
$script:chatGptProjectUrl = 'https://chatgpt.com/'
$script:powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$env:PSModulePath = "$env:USERPROFILE\Documents\WindowsPowerShell\Modules;$env:ProgramFiles\WindowsPowerShell\Modules;$env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules"
$script:active = $null
$script:state = 'Checking'
$script:health = 'Not checked'
$script:hasError = $false
$script:url = ''
$script:startedAt = $null
$script:exitRequested = $false
$script:stopRequested = $false
$script:allowClose = $false
$script:nextRefresh = (Get-Date).AddSeconds(30)
$script:autoOffOptions = [ordered]@{ '5m' = 5; '10m' = 10; '15m' = 15; '30m' = 30; '1h' = 60; '2h' = 120; '8h' = 480; 'never' = 0 }
$script:settingsPath = Join-Path $env:LOCALAPPDATA 'devspace-bridge\tray-settings.json'
$script:autoOffChoice = '1h'
try {
  $saved = Get-Content -LiteralPath $script:settingsPath -Raw -ErrorAction Stop | ConvertFrom-Json
  if ($script:autoOffOptions.Contains([string]$saved.autoOff)) { $script:autoOffChoice = [string]$saved.autoOff }
} catch { }
$script:autoOffDeadline = $null
$script:timedRunStart = $null
$script:lastTraffic = $null
$script:lifetimeStatsPath = Join-Path $env:LOCALAPPDATA 'devspace-bridge\tray-token-stats.json'
$script:lifetimeSentBytes = [long]0
$script:lastCountedRun = ''
$script:lastCountedSentBytes = [long]0
$script:trackingStartedAt = (Get-Date).ToString('yyyy-MM-dd')
try {
  $savedStats = Get-Content -LiteralPath $script:lifetimeStatsPath -Raw -ErrorAction Stop | ConvertFrom-Json
  $script:lifetimeSentBytes = [math]::Max(0, [long]$savedStats.lifetimeSentBytes)
  $script:lastCountedRun = [string]$savedStats.lastRunId
  $script:lastCountedSentBytes = [math]::Max(0, [long]$savedStats.lastRunSentBytes)
  if ($savedStats.trackingStartedAt) { $script:trackingStartedAt = [string]$savedStats.trackingStartedAt }
} catch { }
$script:sessionPath = Join-Path $env:LOCALAPPDATA 'devspace-bridge\tray-session.json'
$script:recoveryArmed = $false
$script:retriesUsed = 0
$script:recoveryDue = $null
$script:recoveryExhausted = $false
$script:lastHealthyUrl = ''
try {
  $session = Get-Content -LiteralPath $script:sessionPath -Raw -ErrorAction Stop | ConvertFrom-Json
  if ($session.armed) {
    $script:recoveryArmed = $true
    $script:retriesUsed = [math]::Max(0, [math]::Min(3, [int]$session.retriesUsed))
    $script:recoveryExhausted = [bool]$session.exhausted
    $script:timedRunStart = [string]$session.runStart
    $script:lastHealthyUrl = [string]$session.lastHealthyUrl
    if ($session.deadline) { $script:autoOffDeadline = [datetime]::Parse([string]$session.deadline).ToLocalTime() }
  }
} catch { }

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Codex ChatGPT Bridge'
$form.Size = New-Object System.Drawing.Size(620, 750)
$form.MinimumSize = New-Object System.Drawing.Size(620, 750)
$form.StartPosition = 'CenterScreen'
$form.ShowInTaskbar = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$form.Icon = $script:icons['off']

function New-Label([string]$text, [int]$x, [int]$y, [int]$width, [int]$height) {
  $label = New-Object System.Windows.Forms.Label
  $label.Text = $text
  $label.Location = New-Object System.Drawing.Point($x, $y)
  $label.Size = New-Object System.Drawing.Size($width, $height)
  $form.Controls.Add($label)
  return $label
}

$title = New-Label 'Codex ChatGPT Bridge' 20 16 560 36
$title.Font = New-Object System.Drawing.Font('Segoe UI', 17, [System.Drawing.FontStyle]::Bold)
$projectLink = New-Object System.Windows.Forms.LinkLabel
$projectLink.Text = 'Open ChatGPT'
$projectLink.Location = New-Object System.Drawing.Point(390, 27)
$projectLink.Size = New-Object System.Drawing.Size(205, 25)
$form.Controls.Add($projectLink)
$null = New-Label 'Bridge' 22 65 110 25
$stateLabel = New-Label 'Checking...' 145 65 425 25
$null = New-Label 'Allowed files' 22 100 110 25
$rootLabel = New-Label $script:projectRoot 145 100 425 25
$null = New-Label 'Health' 22 135 110 25
$healthLabel = New-Label 'Not checked' 145 135 425 25
$null = New-Label 'MCP address' 22 170 110 25
$urlBox = New-Object System.Windows.Forms.TextBox
$urlBox.Location = New-Object System.Drawing.Point(145, 168)
$urlBox.Size = New-Object System.Drawing.Size(430, 28)
$urlBox.ReadOnly = $true
$urlBox.Text = 'Bridge is off'
$form.Controls.Add($urlBox)
$null = New-Label 'Started' 22 210 110 25
$startedLabel = New-Label '-' 145 210 425 25
$null = New-Label 'Uptime' 22 240 110 25
$uptimeLabel = New-Label '-' 145 240 425 25
$null = New-Label 'Processes' 22 270 110 25
$processLabel = New-Label '-' 145 270 425 25
$null = New-Label 'Auto off after' 22 305 115 25
$autoOffBox = New-Object System.Windows.Forms.ComboBox
$autoOffBox.DropDownStyle = 'DropDownList'
$autoOffBox.Location = New-Object System.Drawing.Point(145, 301)
$autoOffBox.Size = New-Object System.Drawing.Size(120, 28)
$null = $autoOffBox.Items.AddRange([string[]]@($script:autoOffOptions.Keys))
$autoOffBox.SelectedItem = $script:autoOffChoice
$form.Controls.Add($autoOffBox)
$remainingLabel = New-Label 'Starts when the bridge turns on' 285 305 290 25
$null = New-Label 'Recovery' 22 335 110 25
$recoveryLabel = New-Label 'Idle' 145 335 425 25
$null = New-Label 'Sent' 22 375 110 25
$sentLabel = New-Label '-' 145 375 425 25
$null = New-Label 'Received' 22 405 110 25
$receivedLabel = New-Label '-' 145 405 425 25
$null = New-Label 'Requests' 22 435 110 25
$requestsLabel = New-Label '-' 145 435 425 25
$null = New-Label 'Tokens Saved' 22 465 145 25
$tokensLabel = New-Label '-' 180 465 395 25
$null = New-Label 'Lifetime Tokens Saved' 22 495 175 25
$lifetimeLabel = New-Label '-' 200 495 375 25

$trafficNote = New-Label "Traffic estimate only (sent bytes / 4, including overhead). Lifetime tracked since $($script:trackingStartedAt); earlier use unavailable." 22 525 560 40
$trafficNote.ForeColor = [System.Drawing.Color]::DimGray

$onButton = New-Object System.Windows.Forms.Button
$onButton.Text = 'Turn on'
$onButton.Location = New-Object System.Drawing.Point(22, 575)
$onButton.Size = New-Object System.Drawing.Size(115, 36)
$form.Controls.Add($onButton)
$offButton = New-Object System.Windows.Forms.Button
$offButton.Text = 'Turn off'
$offButton.Location = New-Object System.Drawing.Point(147, 575)
$offButton.Size = New-Object System.Drawing.Size(115, 36)
$form.Controls.Add($offButton)
$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = 'Refresh'
$refreshButton.Location = New-Object System.Drawing.Point(272, 575)
$refreshButton.Size = New-Object System.Drawing.Size(100, 36)
$form.Controls.Add($refreshButton)
$doctorButton = New-Object System.Windows.Forms.Button
$doctorButton.Text = 'Health check'
$doctorButton.Location = New-Object System.Drawing.Point(382, 575)
$doctorButton.Size = New-Object System.Drawing.Size(115, 36)
$form.Controls.Add($doctorButton)
$copyButton = New-Object System.Windows.Forms.Button
$copyButton.Text = 'Copy URL'
$copyButton.Location = New-Object System.Drawing.Point(507, 575)
$copyButton.Size = New-Object System.Drawing.Size(90, 36)
$form.Controls.Add($copyButton)

$activityLabel = New-Label 'Activity' 22 625 550 24
$activityBox = New-Object System.Windows.Forms.TextBox
$activityBox.Location = New-Object System.Drawing.Point(22, 650)
$activityBox.Size = New-Object System.Drawing.Size(575, 62)
$activityBox.Multiline = $true
$activityBox.ReadOnly = $true
$activityBox.ScrollBars = 'Vertical'
$activityBox.Text = 'Starting tray app. The bridge stays off until you turn it on.'
$form.Controls.Add($activityBox)

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$openItem = $menu.Items.Add('Open details')
$openProjectItem = $menu.Items.Add('Open ChatGPT')
$null = $menu.Items.Add('-')
$onItem = $menu.Items.Add('Turn on')
$offItem = $menu.Items.Add('Turn off')
$refreshItem = $menu.Items.Add('Refresh status')
$doctorItem = $menu.Items.Add('Health check')
$null = $menu.Items.Add('-')
$exitItem = $menu.Items.Add('Exit tray app')
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = $script:icons['checking']
$notify.Text = 'Codex ChatGPT Bridge: checking'
$notify.ContextMenuStrip = $menu
$notify.Visible = $true

function Set-Activity([string]$message) {
  $activityBox.Text = ('{0:HH:mm:ss}  {1}' -f (Get-Date), $message)
}

function Format-Bytes([long]$bytes) {
  if ($bytes -ge 1048576) { return ('{0:N0} bytes ({1:N2} MB)' -f $bytes, ($bytes / 1048576.0)) }
  if ($bytes -ge 1024) { return ('{0:N0} bytes ({1:N1} KB)' -f $bytes, ($bytes / 1024.0)) }
  return ('{0:N0} bytes' -f $bytes)
}

function Save-LifetimeStats {
  try {
    $directory = Split-Path -Parent $script:lifetimeStatsPath
    $null = New-Item -ItemType Directory -Path $directory -Force
    $value = @{
      version = 1
      lifetimeSentBytes = $script:lifetimeSentBytes
      lastRunId = $script:lastCountedRun
      lastRunSentBytes = $script:lastCountedSentBytes
      trackingStartedAt = $script:trackingStartedAt
    } | ConvertTo-Json -Compress
    $tempPath = "$script:lifetimeStatsPath.$PID.tmp"
    [IO.File]::WriteAllText($tempPath, $value)
    Move-Item -LiteralPath $tempPath -Destination $script:lifetimeStatsPath -Force
  } catch { Set-Activity "Could not save lifetime traffic estimate: $($_.Exception.Message)" }
}

function Update-Traffic($traffic, [string]$runId = '') {
  if ($null -ne $traffic) {
    $script:lastTraffic = $traffic
    if ($runId) {
      $sentBytes = [math]::Max(0, [long]$traffic.sentBytes)
      $sameRun = $script:lastCountedRun -eq $runId
      $delta = if ($sameRun) { [math]::Max(0, $sentBytes - $script:lastCountedSentBytes) } else { $sentBytes }
      if ($delta -gt 0 -or -not $sameRun -or $sentBytes -lt $script:lastCountedSentBytes) {
        $script:lifetimeSentBytes += $delta
        $script:lastCountedRun = $runId
        $script:lastCountedSentBytes = $sentBytes
        Save-LifetimeStats
      }
    }
  }
  $lifetimeLabel.Text = ('~{0:N0} tokens (rough)' -f [math]::Round(([double]$script:lifetimeSentBytes / 4)))
  if ($null -eq $script:lastTraffic) {
    $sentLabel.Text = 'Unavailable'; $receivedLabel.Text = 'Unavailable'
    $requestsLabel.Text = 'Unavailable'; $tokensLabel.Text = 'Unavailable'
    return
  }
  $sentLabel.Text = Format-Bytes ([long]$script:lastTraffic.sentBytes)
  $receivedLabel.Text = Format-Bytes ([long]$script:lastTraffic.receivedBytes)
  $requestsLabel.Text = ('{0:N0}' -f [long]$script:lastTraffic.requests)
  $tokensLabel.Text = ('~{0:N0} tokens (rough)' -f [math]::Round(([double]$script:lastTraffic.sentBytes / 4)))
}

function Save-Session {
  try {
    $directory = Split-Path -Parent $script:sessionPath
    $null = New-Item -ItemType Directory -Path $directory -Force
    $value = @{
      armed = $script:recoveryArmed
      deadline = if ($script:autoOffDeadline) { $script:autoOffDeadline.ToString('o') } else { $null }
      retriesUsed = $script:retriesUsed
      exhausted = $script:recoveryExhausted
      runStart = $script:timedRunStart
      lastHealthyUrl = $script:lastHealthyUrl
    } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($script:sessionPath, $value)
  } catch { Set-Activity "Could not save recovery state: $($_.Exception.Message)" }
}

function Cancel-Session {
  $script:recoveryArmed = $false
  $script:autoOffDeadline = $null
  $script:timedRunStart = $null
  $script:retriesUsed = 0
  $script:recoveryDue = $null
  $script:recoveryExhausted = $false
  $script:lastHealthyUrl = ''
  $recoveryLabel.Text = 'Idle'
  $remainingLabel.Text = if ($script:autoOffChoice -eq 'never') { 'No automatic turnoff' } else { 'Starts when the bridge turns on' }
  Save-Session
}

function Start-AutoOffCountdown {
  if ($script:autoOffChoice -eq 'never') { $script:autoOffDeadline = $null; $remainingLabel.Text = 'No automatic turnoff'; return }
  $script:autoOffDeadline = (Get-Date).AddMinutes([int]$script:autoOffOptions[$script:autoOffChoice])
}

function Begin-Session($StartedAt = $null) {
  $script:recoveryArmed = $true
  $script:retriesUsed = 0
  $script:recoveryDue = $null
  $script:recoveryExhausted = $false
  $script:timedRunStart = $null
  Start-AutoOffCountdown
  if ($StartedAt -and $script:autoOffChoice -ne 'never') {
    $script:autoOffDeadline = ([datetime]::Parse([string]$StartedAt)).ToLocalTime().AddMinutes([int]$script:autoOffOptions[$script:autoOffChoice])
  }
  $recoveryLabel.Text = 'Ready (3 retries available)'
  Save-Session
}

function Sync-HealthyRun($status) {
  $runStart = [string]$status.startedAt
  if ($script:timedRunStart -ne $runStart) {
    $script:timedRunStart = $runStart
    $script:lastTraffic = $null
  }
  $script:retriesUsed = 0
  $script:recoveryDue = $null
  $script:recoveryExhausted = $false
  $script:lastHealthyUrl = [string]$status.mcpUrl
  $recoveryLabel.Text = 'Healthy (3 retries available)'
  Save-Session
}

function Schedule-Recovery {
  if (-not $script:recoveryArmed -or $script:exitRequested -or $script:stopRequested -or $script:recoveryExhausted) { return }
  if ($script:autoOffDeadline -and (Get-Date) -ge $script:autoOffDeadline) { Request-Off; return }
  if ($script:retriesUsed -ge 3) {
    $script:recoveryExhausted = $true
    $script:recoveryDue = $null
    $script:hasError = $true
    $script:health = 'Recovery stopped'
    $recoveryLabel.Text = 'Stopped after 3 retries; turn on manually'
    Set-Activity 'Bridge recovery stopped after 3 failed retries.'
    Save-Session
    Update-Controls
    return
  }
  if ($script:recoveryDue) { return }
  $delay = 10 * ($script:retriesUsed + 1)
  $script:recoveryDue = (Get-Date).AddSeconds($delay)
  $recoveryLabel.Text = "Retry $($script:retriesUsed + 1)/3 in $delay seconds"
  Set-Activity "Bridge is unhealthy. Recovery retry $($script:retriesUsed + 1)/3 scheduled."
  Update-Controls
}

function Show-Details {
  $form.ShowInTaskbar = $true
  $form.Show()
  $form.WindowState = 'Normal'
  $form.Activate()
}

function Open-BridgeProject {
  try {
    Start-Process -FilePath $script:chatGptProjectUrl
    Set-Activity 'ChatGPT opened. Choose your own project before starting a bridge chat.'
  } catch { Set-Activity "Could not open ChatGPT: $($_.Exception.Message)" }
}

function Update-Controls {
  $busy = $null -ne $script:active
  $onButton.Enabled = -not $busy -and $script:state -ne 'On' -and (-not $script:recoveryArmed -or $script:recoveryExhausted) -and -not $script:exitRequested
  $offButton.Enabled = -not $busy -and $script:state -ne 'Off' -and -not $script:exitRequested
  $refreshButton.Enabled = -not $busy -and -not $script:exitRequested
  $doctorButton.Enabled = -not $busy -and -not $script:exitRequested
  $copyButton.Enabled = -not [string]::IsNullOrWhiteSpace($script:url)
  $onItem.Enabled = $onButton.Enabled
  $offItem.Enabled = -not $script:exitRequested
  $refreshItem.Enabled = $refreshButton.Enabled
  $doctorItem.Enabled = $doctorButton.Enabled
  $stateLabel.Text = if ($busy) { 'Working: ' + $script:active.Action } else { $script:state }
  $stateLabel.ForeColor = if ($script:hasError) { [System.Drawing.Color]::Firebrick } elseif ($script:state -eq 'On') { [System.Drawing.Color]::ForestGreen } else { [System.Drawing.Color]::DimGray }
  $healthLabel.Text = $script:health
  $urlBox.Text = if ($script:url) { $script:url } else { 'Bridge is off' }
  $iconState = if ($busy -or $script:state -eq 'Recovering') { 'checking' } elseif ($script:hasError) { 'error' } elseif ($script:state -eq 'On') { 'on' } else { 'off' }
  $notify.Icon = $script:icons[$iconState]
  $form.Icon = $script:icons[$iconState]
  $notify.Text = 'Codex ChatGPT Bridge: ' + $(if ($busy) { 'working' } elseif ($script:hasError) { 'needs attention' } else { $script:state })
}

function Start-BridgeAction([string]$action, [switch]$Recovery) {
  if ($script:active) { return }
  $base = Join-Path $env:TEMP ('codex-bridge-tray-' + [guid]::NewGuid().ToString('N'))
  $outFile = $base + '.out'
  $errFile = $base + '.err'
  try {
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Action {1}' -f $script:controller, $action
    $process = Start-Process -FilePath $script:powerShell -ArgumentList $arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $script:active = [pscustomobject]@{ Action = $action; Recovery = [bool]$Recovery; Process = $process; OutFile = $outFile; ErrFile = $errFile }
    Set-Activity "$action in progress..."
    Update-Controls
  } catch {
    $script:hasError = $true
    Set-Activity "Could not run $action`: $($_.Exception.Message)"
    foreach ($path in @($outFile, $errFile)) { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
    if ($action -in @('On', 'Recover') -and $script:recoveryArmed) { Schedule-Recovery }
    Update-Controls
  }
}

function Complete-BridgeAction {
  $job = $script:active
  if (-not $job -or -not $job.Process.HasExited) { return }
  $recoveryNeeded = $false
  $job.Process.WaitForExit()
  $rawExitCode = $job.Process.ExitCode
  $exitCode = if ($null -eq $rawExitCode) { 1 } else { [int]$rawExitCode }
  $output = [string]$(if (Test-Path -LiteralPath $job.OutFile) { Get-Content -LiteralPath $job.OutFile -Raw } else { '' })
  $errorText = [string]$(if (Test-Path -LiteralPath $job.ErrFile) { Get-Content -LiteralPath $job.ErrFile -Raw } else { '' })
  if ($null -eq $output) { $output = '' }
  if ($null -eq $errorText) { $errorText = '' }
  $job.Process.Dispose()
  foreach ($path in @($job.OutFile, $job.ErrFile)) { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
  $script:active = $null

  # Older wrappers can inherit Doctor's exit 1 for an intentionally stopped
  # bridge even when Status returned a complete, usable report.
  if ($job.Action -eq 'Status' -and $exitCode -ne 0 -and -not $errorText.Trim()) {
    try {
      $statusProbe = $output | ConvertFrom-Json
      if ($statusProbe.desiredState -in @('running', 'stopped') -and
          -not [string]::IsNullOrWhiteSpace([string]$statusProbe.projectRoot) -and
          $null -ne $statusProbe.allowedRoots) {
        $exitCode = 0
      }
    } catch { }
  }
  if ($job.Action -eq 'Off' -and $exitCode -ne 0 -and -not $errorText.Trim() -and
      $output.Trim() -eq 'Bridge is off. No bridge or tunnel process remains.') {
    $exitCode = 0
  }

  if ($exitCode -ne 0) {
    $script:hasError = $true
    $script:health = 'Needs attention'
    $message = if ($errorText.Trim()) { $errorText.Trim() } else { "$($job.Action) failed (exit $exitCode). Output: $($output.Trim())" }
    Set-Activity $message
    if ($job.Action -in @('On', 'Recover')) {
      $script:state = 'Recovering'; $script:url = ''
      if ($message -match 'security warnings|outside the approved project scope|not ready') {
        $script:recoveryExhausted = $true
        $script:recoveryDue = $null
        $recoveryLabel.Text = 'Stopped: scope or readiness needs attention'
        Save-Session
      } elseif (-not $script:stopRequested -and -not $script:exitRequested) { Schedule-Recovery }
    } elseif ($job.Action -eq 'Status' -and $job.Recovery) {
      Schedule-Recovery
    }
    if ($script:exitRequested -and $job.Action -eq 'Off') {
      $script:exitRequested = $false
      Show-Details
    }
  } else {
    try {
      switch ($job.Action) {
        'Status' {
          $status = $output | ConvertFrom-Json
          $intentRunning = $status.desiredState -eq 'running'
          $healthy = $intentRunning -and [bool]$status.runtimeHealthy -and -not [string]::IsNullOrWhiteSpace([string]$status.mcpUrl)
          $scopeOkay = ([string]$status.projectRoot).Equals($script:projectRoot, [StringComparison]::OrdinalIgnoreCase) -and
            @($status.allowedRoots).Count -eq 1 -and
            ([string]@($status.allowedRoots)[0]).Equals($script:projectRoot, [StringComparison]::OrdinalIgnoreCase)
          $warnings = @($status.securityWarnings | Where-Object { $_ })
          if ($healthy -and $scopeOkay -and $warnings.Count -eq 0) {
            if (-not $script:recoveryArmed -and -not $script:stopRequested -and -not $script:exitRequested) { Begin-Session $status.startedAt }
            $script:state = 'On'
            $script:health = 'Healthy'
            $script:hasError = $false
            $script:url = [string]$status.mcpUrl
            Sync-HealthyRun $status
          } elseif ($intentRunning) {
            $script:state = 'Recovering'
            $script:url = ''
            if (-not $script:recoveryArmed -and -not $script:stopRequested -and -not $script:exitRequested) { Begin-Session $status.startedAt }
            if (-not $scopeOkay -or $warnings.Count -gt 0 -or -not [bool]$status.restartReady) {
              $script:recoveryExhausted = $true
              $script:recoveryDue = $null
              $script:hasError = $true
              $script:health = 'Recovery blocked'
              $recoveryLabel.Text = 'Stopped: security or readiness issue'
              Save-Session
            } elseif (-not $script:recoveryExhausted) {
              $script:health = 'Unhealthy; retry pending'
              if ($job.Recovery) { $recoveryNeeded = $true }
              else { Schedule-Recovery }
            }
          } else {
            $script:state = 'Off'
            $script:url = ''
            $script:health = 'Off; ready to start'
            Cancel-Session
          }
          $rootLabel.Text = (@($status.allowedRoots) -join '; ')
          $script:startedAt = if ($status.startedAt) { [datetime]::Parse([string]$status.startedAt) } else { $null }
          $startedLabel.Text = if ($script:startedAt) { $script:startedAt.ToString('yyyy-MM-dd HH:mm:ss') } else { '-' }
          $processLabel.Text = if ($script:state -eq 'On') { "Bridge $($status.devspaceProcessId)  |  Tunnel $($status.tunnelProcessId)" } else { '-' }
          Update-Traffic $status.traffic "$($status.startedAt)|$($status.tunnelProcessId)"
          $trafficNote.Text = if ($script:state -eq 'Off') { "Last observed run. Lifetime tracked since $($script:trackingStartedAt); earlier use unavailable. Traffic estimate only." } else { "Traffic estimate only (sent bytes / 4, including overhead). Lifetime tracked since $($script:trackingStartedAt); earlier use unavailable." }
          if ($script:state -eq 'On' -or $script:state -eq 'Off') { Set-Activity "Status refreshed. Bridge is $($script:state)." }
        }
        'Doctor' {
          $doctor = $output | ConvertFrom-Json
          $warnings = @($doctor.securityWarnings | Where-Object { $_ })
          $issues = @($doctor.readinessIssues | Where-Object { $_ })
          if ($warnings.Count -gt 0) { $script:hasError = $true; $script:health = 'Security warning'; Set-Activity ($warnings -join '; ') }
          elseif ($issues.Count -gt 0) { $script:hasError = $true; $script:health = 'Needs attention'; Set-Activity ($issues -join '; ') }
          elseif ($doctor.runtimeHealthy) { $script:hasError = $false; $script:health = 'Healthy'; Set-Activity 'Health check passed.' }
          else { $script:hasError = $false; $script:health = 'Off; ready to start'; Set-Activity 'Bridge is off and ready to start.' }
        }
        { $_ -in @('On', 'Recover') } {
          if ($output -notmatch 'Bridge is on and healthy') { throw 'Start did not confirm a healthy bridge.' }
          $oldUrl = $script:lastHealthyUrl
          $script:state = 'On'
          $script:health = 'Healthy'
          $script:hasError = $false
          if ($output -match '(https://\S+/mcp)') { $script:url = $Matches[1] }
          $script:lastHealthyUrl = $script:url
          $script:retriesUsed = 0
          $script:recoveryDue = $null
          $script:recoveryExhausted = $false
          $recoveryLabel.Text = 'Healthy (3 retries available)'
          $script:lastTraffic = $null
          Update-Traffic $null
          Save-Session
          if ($job.Action -eq 'On') {
            Set-Activity 'Bridge is healthy. Check that the ChatGPT app uses the MCP address shown above; Quick Tunnel URLs can change on each start.'
            $notify.ShowBalloonTip(10000, 'Check ChatGPT connection', 'The bridge is on. A new Quick Tunnel address may require updating the ChatGPT app connection.', [System.Windows.Forms.ToolTipIcon]::Info)
          } elseif ($job.Recovery -and $oldUrl -and $oldUrl -ne $script:url) {
            Set-Activity 'Bridge recovered with a new URL. Update the ChatGPT app connection.'
            $notify.ShowBalloonTip(10000, 'Bridge URL changed', 'Update the ChatGPT app connection to the new MCP address.', [System.Windows.Forms.ToolTipIcon]::Warning)
          } else { Set-Activity 'Bridge started and passed its health check.' }
        }
        'Off' {
          if ($output -notmatch 'Bridge is off') { throw 'Shutdown did not confirm the bridge is off.' }
          $script:state = 'Off'
          $script:health = 'Off; ready to start'
          $script:hasError = $false
          $script:url = ''
          $script:startedAt = $null
          $startedLabel.Text = '-'
          $uptimeLabel.Text = '-'
          $processLabel.Text = '-'
          Cancel-Session
          $trafficNote.Text = "Last observed run. Lifetime tracked since $($script:trackingStartedAt); earlier use unavailable. Traffic estimate only."
          Set-Activity 'Bridge and tunnel stopped.'
          if ($script:exitRequested) {
            $script:allowClose = $true
            $form.Close()
            return
          }
        }
      }
    } catch {
      $script:hasError = $true
      $script:health = 'Needs attention'
      Set-Activity "Could not read $($job.Action) response: $($_.Exception.Message)"
      if ($job.Action -in @('On', 'Recover') -and -not $script:stopRequested -and -not $script:exitRequested) {
        $script:state = 'Recovering'
        $script:url = ''
        Schedule-Recovery
      } elseif ($job.Action -eq 'Status' -and $job.Recovery) {
        Schedule-Recovery
      }
    }
  }
  Update-Controls
  if ($script:exitRequested -or $script:stopRequested) {
    $script:stopRequested = $false
    if ($script:exitRequested -and $job.Action -in @('Status', 'Doctor') -and (Test-BridgeAlreadyStopped)) {
      $script:allowClose = $true
      $form.Close()
      return
    }
    if ($job.Action -ne 'Off') { Start-BridgeAction 'Off' }
  } elseif ($recoveryNeeded -and $script:recoveryArmed -and $script:retriesUsed -lt 3) {
    $script:retriesUsed++
    $recoveryLabel.Text = "Retry $($script:retriesUsed)/3 in progress"
    Save-Session
    Start-BridgeAction 'Recover' -Recovery
  } elseif ($job.Action -in @('On', 'Recover', 'Off')) {
    $script:nextRefresh = (Get-Date).AddSeconds(3)
  } else {
    $script:nextRefresh = (Get-Date).AddSeconds(30)
  }
}

function Request-Off {
  Cancel-Session
  if ($script:active) {
    $script:stopRequested = $true
    Set-Activity 'Turn off queued after the current action.'
  } else { Start-BridgeAction 'Off' }
}

function Test-BridgeAlreadyStopped {
  try {
    $stateRoot = Join-Path $env:LOCALAPPDATA 'devspace-bridge'
    $desiredPath = Join-Path $stateRoot 'desired-state.json'
    $runtimePath = Join-Path $stateRoot 'state.json'
    $desired = Get-Content -LiteralPath $desiredPath -Raw -ErrorAction Stop | ConvertFrom-Json
    return $desired.state -eq 'stopped' -and -not (Test-Path -LiteralPath $runtimePath)
  } catch { return $false }
}

function Request-Exit {
  if ($script:exitRequested) { return }
  $readOnlyAction = -not $script:active -or $script:active.Action -in @('Status', 'Doctor')
  if ($readOnlyAction -and (Test-BridgeAlreadyStopped)) {
    $script:exitRequested = $true
    $script:stopRequested = $false
    Cancel-Session
    $script:allowClose = $true
    $form.Close()
    return
  }
  $script:exitRequested = $true
  $script:stopRequested = $true
  Cancel-Session
  Set-Activity 'Closing the bridge before exit...'
  Update-Controls
  if (-not $script:active) { Start-BridgeAction 'Off' }
}

$onButton.Add_Click({ Begin-Session; Start-BridgeAction 'On' })
$offButton.Add_Click({ Request-Off })
$refreshButton.Add_Click({ Start-BridgeAction 'Status' })
$doctorButton.Add_Click({ Start-BridgeAction 'Doctor' })
$copyButton.Add_Click({ if ($script:url) { [System.Windows.Forms.Clipboard]::SetText($script:url); Set-Activity 'MCP address copied.' } })
$autoOffBox.Add_SelectedIndexChanged({
  $choice = [string]$autoOffBox.SelectedItem
  if (-not $script:autoOffOptions.Contains($choice)) { return }
  $script:autoOffChoice = $choice
  try {
    $directory = Split-Path -Parent $script:settingsPath
    $null = New-Item -ItemType Directory -Path $directory -Force
    [IO.File]::WriteAllText($script:settingsPath, (@{ autoOff = $choice } | ConvertTo-Json -Compress))
  } catch { Set-Activity "Could not save auto-off choice: $($_.Exception.Message)" }
  if ($script:recoveryArmed) { Start-AutoOffCountdown; Save-Session } else { $remainingLabel.Text = if ($choice -eq 'never') { 'No automatic turnoff' } else { 'Starts when the bridge turns on' } }
})
$openItem.Add_Click({ Show-Details })
$openProjectItem.Add_Click({ Open-BridgeProject })
$projectLink.Add_LinkClicked({ Open-BridgeProject })
$onItem.Add_Click({ Begin-Session; Start-BridgeAction 'On' })
$offItem.Add_Click({ Request-Off })
$refreshItem.Add_Click({ Start-BridgeAction 'Status' })
$doctorItem.Add_Click({ Start-BridgeAction 'Doctor' })
$exitItem.Add_Click({ Request-Exit })
$notify.Add_DoubleClick({ Show-Details })
$form.Add_Shown({ $form.Hide(); $form.ShowInTaskbar = $false })
$form.Add_FormClosing({
  param($sender, $eventArgs)
  if (-not $script:allowClose) {
    $eventArgs.Cancel = $true
    Request-Exit
  }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
  try {
    if ($showSignal.WaitOne(0)) { Show-Details }
    if ($exitSignal.WaitOne(0)) { Request-Exit }
    if ($script:startedAt -and $script:state -eq 'On') {
      $uptimeLabel.Text = ((Get-Date) - $script:startedAt).ToString('d\.hh\:mm\:ss')
    }
    if ($script:recoveryArmed) {
      if ($script:autoOffChoice -eq 'never') { $remainingLabel.Text = 'No automatic turnoff' }
      elseif ($script:autoOffDeadline) {
        $timeLeft = $script:autoOffDeadline - (Get-Date)
        if ($timeLeft.TotalSeconds -le 0) {
          $script:autoOffDeadline = $null
          $remainingLabel.Text = 'Turning off now...'
          Request-Off
        } else { $remainingLabel.Text = ('Turns off in {0:dd\:hh\:mm\:ss}' -f $timeLeft) }
      }
    }
    if ($script:active) { Complete-BridgeAction }
    elseif ($script:recoveryDue -and (Get-Date) -ge $script:recoveryDue -and $script:recoveryArmed -and -not $script:recoveryExhausted) {
      $script:recoveryDue = $null
      # Another controller or the operator may have restored health while this
      # countdown was pending. Check the current state before restarting it.
      Start-BridgeAction 'Status' -Recovery
    }
    elseif (-not $script:exitRequested -and (Get-Date) -ge $script:nextRefresh) { Start-BridgeAction 'Status' }
  } catch {
    $failure = "Tray update failed: $($_.Exception.Message) $($_.ScriptStackTrace)"
    Set-Activity $failure
    try { [IO.File]::AppendAllText((Join-Path $env:TEMP 'codex-bridge-tray-errors.log'), $failure + [Environment]::NewLine) } catch { }
  }
})
if (-not (Test-Path -LiteralPath $script:lifetimeStatsPath)) { Save-LifetimeStats }
Update-Controls

try {
  # Starting the tray does not start the public bridge.
  Start-BridgeAction 'Status'
  $timer.Start()
  [System.Windows.Forms.Application]::Run($form)
} finally {
  $timer.Stop()
  $notify.Visible = $false
  $notify.Dispose()
  $form.Dispose()
  foreach ($icon in $script:icons.Values) { $icon.Dispose() }
  $showSignal.Dispose()
  $exitSignal.Dispose()
  try {
    $record = Get-Content -LiteralPath $script:trayPidPath -Raw -ErrorAction Stop | ConvertFrom-Json
    if ([int]$record.pid -eq $PID -and [long]$record.startTicks -eq $script:trayStartTicks) {
      Remove-Item -LiteralPath $script:trayPidPath -ErrorAction SilentlyContinue
    }
  } catch { }
  $mutex.ReleaseMutex()
  $mutex.Dispose()
}
