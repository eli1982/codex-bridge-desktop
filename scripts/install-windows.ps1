param([string]$ProjectRoot)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$upstreamTag = 'v0.3.0'
$upstreamCommit = '351c66fef0390872443af1587a978e6f76f479b8'
$devspaceVersion = '1.0.2'
function Require-Command([string]$name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { throw "Missing $name. See README.md prerequisites." }
}
foreach ($name in @('git.exe','node.exe','npm.cmd','powershell.exe')) { Require-Command $name }
$nodeVersion = [version]((& node.exe -p 'process.versions.node').Trim())
if ($nodeVersion -lt [version]'20.12.0' -or $nodeVersion.Major -ge 27) { throw 'Node.js 20.12 through 26.x is required for pinned DevSpace 1.0.2.' }
if (-not $ProjectRoot) { $ProjectRoot = Read-Host 'Enter one project folder to expose when the bridge is on' }
$rootItem = Get-Item -LiteralPath $ProjectRoot -ErrorAction Stop
if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
  throw 'Choose a real project directory, not a file or link.'
}
$project = [IO.Path]::GetFullPath($rootItem.FullName).TrimEnd('\')
$driveRoot = [IO.Path]::GetPathRoot($project).TrimEnd('\')
$userRoot = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')
if ($project.Equals($driveRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $project.Equals($userRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $userRoot.StartsWith($project + '\', [StringComparison]::OrdinalIgnoreCase)) {
  throw 'Choose a narrow project folder, not a drive root or user-profile root.'
}
$settingsDir = Join-Path $env:LOCALAPPDATA 'codex-bridge-desktop'
$settingsPath = Join-Path $settingsDir 'settings.json'
$programDir = Join-Path $env:LOCALAPPDATA 'Programs\Codex Bridge'
$upstreamDir = Join-Path $settingsDir 'upstream-v0.3.0'
$installedSkill = Join-Path $env:USERPROFILE '.codex\skills\codex-chatgpt-bridge'
$installedVersion = ''
$npmRoot = (& npm.cmd root -g).Trim()
$packagePath = Join-Path $npmRoot '@waishnav\devspace\package.json'
if (Test-Path -LiteralPath $packagePath) {
  $installedVersion = [string](Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json).version
}
if ($installedVersion -and $installedVersion -ne $devspaceVersion) {
  throw "DevSpace $installedVersion is already installed. This beta requires $devspaceVersion; do not downgrade an existing install automatically."
}
if (-not $installedVersion) {
  & npm.cmd install -g "@waishnav/devspace@$devspaceVersion"
  if ($LASTEXITCODE -ne 0) { throw 'DevSpace installation failed.' }
}
$expectedCli = Join-Path $env:APPDATA 'npm\devspace.cmd'
if (-not (Test-Path -LiteralPath $expectedCli)) {
  throw 'The pinned Windows controller expects DevSpace at the standard per-user npm prefix. Check npm prefix before installing.'
}
$null = New-Item -ItemType Directory -Path $settingsDir -Force
if (-not (Test-Path -LiteralPath $upstreamDir)) {
  & git.exe clone --depth 1 --branch $upstreamTag https://github.com/Zhenyu98/codex-chatgpt-bridge.git $upstreamDir
  if ($LASTEXITCODE -ne 0) { throw 'Upstream skill clone failed.' }
}
$head = (& git.exe -C $upstreamDir rev-parse HEAD).Trim()
if ($head -ne $upstreamCommit) { throw 'Upstream revision differs from pinned commit. Installation stopped.' }
$sourceSkill = Join-Path $upstreamDir 'skills\codex-chatgpt-bridge'
$sourceSkillHash = (Get-FileHash (Join-Path $sourceSkill 'scripts\bridge_controller.ps1') -Algorithm SHA256).Hash
if (Test-Path -LiteralPath $installedSkill) {
  $existingHash = (Get-FileHash (Join-Path $installedSkill 'scripts\bridge_controller.ps1') -Algorithm SHA256).Hash
  if ($existingHash -ne $sourceSkillHash) { throw 'An incompatible bridge skill is installed. Back it up or remove it yourself before installing this beta.' }
} else {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $upstreamDir 'install.ps1')
  if ($LASTEXITCODE -ne 0) { throw 'Upstream skill installation failed.' }
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\build-windows.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Windows build failed.' }
$null = New-Item -ItemType Directory -Path $programDir -Force
if (Get-Process -Name 'Codex Bridge' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($programDir,[StringComparison]::OrdinalIgnoreCase) }) {
  throw 'Close the installed Codex Bridge tray before updating it.'
}
Copy-Item -Path (Join-Path $repo 'dist\windows\*') -Destination $programDir -Recurse -Force
[IO.File]::WriteAllText($settingsPath, (@{ projectRoot = $project } | ConvertTo-Json -Depth 3), [Text.UTF8Encoding]::new($false))
$desiredPath = Join-Path $env:LOCALAPPDATA 'devspace-bridge\desired-state.json'
if (Test-Path -LiteralPath $desiredPath) {
  $desired = Get-Content -LiteralPath $desiredPath -Raw | ConvertFrom-Json
  if ($desired.state -eq 'running') { throw 'Turn off the existing bridge before configuring this beta.' }
}
$controller = Join-Path $installedSkill 'scripts\bridge_controller.ps1'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $controller -Action Configure -ProjectRoot $project -AllowedRoots $project -Tunnel cloudflare | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Bridge profile configuration failed.' }
$doctorText = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $controller -Action Doctor
$doctor = ($doctorText | Out-String) | ConvertFrom-Json
if (@($doctor.securityWarnings | Where-Object { $_ }).Count -gt 0) { throw 'Bridge profile has security warnings. Installation stopped.' }
$shell = New-Object -ComObject WScript.Shell
$shortcutDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$shortcut = $shell.CreateShortcut((Join-Path $shortcutDir 'Codex Bridge.lnk'))
$shortcut.TargetPath = Join-Path $programDir 'Codex Bridge.exe'
$shortcut.WorkingDirectory = $programDir
$shortcut.IconLocation = (Join-Path $programDir 'bridge-icons\bridge-on.ico') + ',0'
$shortcut.Save()
Write-Host "Installed Codex Bridge for: $project"
Write-Host 'The bridge is OFF. Open Codex Bridge from Start and choose Turn on when ready.'