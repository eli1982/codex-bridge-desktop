param([string]$OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist\windows'))
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$source = Join-Path $repo 'windows'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) {
  $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $compiler)) { throw '.NET Framework 4.x C# compiler is required.' }
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$null = New-Item -ItemType Directory -Path (Join-Path $OutputDirectory 'bridge-icons') -Force
foreach ($name in @('bridge-control.ps1','bridge-kill.ps1','bridge-tray.ps1','bridge-tray.vbs','bridge.cmd')) {
  Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $OutputDirectory $name) -Force
}
Copy-Item -Path (Join-Path $source 'bridge-icons\*.ico') -Destination (Join-Path $OutputDirectory 'bridge-icons') -Force
& $compiler /nologo /target:winexe /platform:anycpu "/win32icon:$(Join-Path $source 'bridge-icons\bridge-on.ico')" "/out:$(Join-Path $OutputDirectory 'Codex Bridge.exe')" /reference:System.Windows.Forms.dll (Join-Path $source 'bridge-launcher.cs')
if ($LASTEXITCODE -ne 0) { throw 'Codex Bridge.exe build failed.' }
& $compiler /nologo /target:winexe /platform:anycpu "/win32icon:$(Join-Path $source 'bridge-icons\bridge-error.ico')" "/out:$(Join-Path $OutputDirectory 'Kill Codex Bridge.exe')" /reference:System.Windows.Forms.dll (Join-Path $source 'bridge-kill-launcher.cs')
if ($LASTEXITCODE -ne 0) { throw 'Kill Codex Bridge.exe build failed.' }
Write-Host "Built Windows package: $OutputDirectory"