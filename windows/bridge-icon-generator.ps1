param(
  [Parameter(Mandatory = $true)][string]$OutputDirectory,
  [string]$PreviewPath
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function New-BridgeBitmap([string]$fillHex, [string]$outlineHex) {
  $bitmap = New-Object System.Drawing.Bitmap(64, 64, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $graphics.Clear([System.Drawing.Color]::Transparent)
  $fill = [System.Drawing.ColorTranslator]::FromHtml($fillHex)
  $outline = [System.Drawing.ColorTranslator]::FromHtml($outlineHex)
  $fillBrush = New-Object System.Drawing.SolidBrush($fill)
  $ringPen = New-Object System.Drawing.Pen($outline, 2.5)
  $bridgePen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 3.2)
  $bridgePen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $bridgePen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  $cablePen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 2.2)
  $deckPen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 4.2)
  $deckPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $deckPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  try {
    $graphics.FillEllipse($fillBrush, 2, 2, 60, 60)
    $graphics.DrawEllipse($ringPen, 3, 3, 58, 58)
    $graphics.DrawLine($bridgePen, 19, 23, 19, 44)
    $graphics.DrawLine($bridgePen, 45, 23, 45, 44)
    $graphics.DrawLine($bridgePen, 15, 23, 23, 23)
    $graphics.DrawLine($bridgePen, 41, 23, 49, 23)
    $graphics.DrawBezier($cablePen, 9, 35, 13, 28, 17, 23, 19, 23)
    $graphics.DrawBezier($cablePen, 19, 23, 27, 35, 37, 35, 45, 23)
    $graphics.DrawBezier($cablePen, 45, 23, 47, 23, 51, 28, 55, 35)
    foreach ($hanger in @(@(13, 31), @(26, 31), @(32, 33), @(38, 31), @(51, 31))) {
      $graphics.DrawLine($cablePen, $hanger[0], $hanger[1], $hanger[0], 43)
    }
    $graphics.DrawLine($deckPen, 10, 45, 54, 45)
    $graphics.DrawLine($cablePen, 13, 51, 51, 51)
    return $bitmap
  } finally {
    $fillBrush.Dispose()
    $ringPen.Dispose()
    $bridgePen.Dispose()
    $cablePen.Dispose()
    $deckPen.Dispose()
    $graphics.Dispose()
  }
}

function Save-BridgeIcon([System.Drawing.Bitmap]$source, [string]$path) {
  $images = New-Object System.Collections.ArrayList
  foreach ($size in @(16, 32, 64)) {
    $scaled = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($scaled)
    $memory = New-Object IO.MemoryStream
    try {
      $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
      $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
      $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
      $graphics.DrawImage($source, 0, 0, $size, $size)
      $scaled.Save($memory, [System.Drawing.Imaging.ImageFormat]::Png)
      $null = $images.Add($memory.ToArray())
    } finally {
      $memory.Dispose()
      $graphics.Dispose()
      $scaled.Dispose()
    }
  }

  $stream = [IO.File]::Create($path)
  $writer = New-Object IO.BinaryWriter($stream)
  try {
    $writer.Write([uint16]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]$images.Count)
    $offset = 6 + 16 * $images.Count
    for ($index = 0; $index -lt $images.Count; $index++) {
      $size = @(16, 32, 64)[$index]
      $bytes = [byte[]]$images[$index]
      $writer.Write([byte]$size)
      $writer.Write([byte]$size)
      $writer.Write([byte]0)
      $writer.Write([byte]0)
      $writer.Write([uint16]1)
      $writer.Write([uint16]32)
      $writer.Write([uint32]$bytes.Length)
      $writer.Write([uint32]$offset)
      $offset += $bytes.Length
    }
    foreach ($bytes in $images) { $writer.Write([byte[]]$bytes) }
  } finally { $writer.Dispose() }
}

$null = New-Item -ItemType Directory -Force -Path $OutputDirectory
$states = @(
  [pscustomobject]@{ Name = 'off'; Fill = '#64748B'; Outline = '#334155' },
  [pscustomobject]@{ Name = 'on'; Fill = '#16A34A'; Outline = '#166534' },
  [pscustomobject]@{ Name = 'checking'; Fill = '#D97706'; Outline = '#92400E' },
  [pscustomobject]@{ Name = 'error'; Fill = '#DC2626'; Outline = '#991B1B' }
)

$preview = $null
$previewGraphics = $null
$previewFont = $null
if ($PreviewPath) {
  $preview = New-Object System.Drawing.Bitmap(480, 130, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $previewGraphics = [System.Drawing.Graphics]::FromImage($preview)
  $previewGraphics.Clear([System.Drawing.Color]::White)
  $previewGraphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $previewFont = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
}

try {
  for ($index = 0; $index -lt $states.Count; $index++) {
    $state = $states[$index]
    $bitmap = New-BridgeBitmap $state.Fill $state.Outline
    try {
      $path = Join-Path $OutputDirectory ("bridge-$($state.Name).ico")
      Save-BridgeIcon $bitmap $path
      Write-Output $path
      if ($preview) {
        $x = 18 + $index * 120
        $previewGraphics.DrawImage($bitmap, $x, 12, 80, 80)
        $previewGraphics.DrawString($state.Name.ToUpperInvariant(), $previewFont, [System.Drawing.Brushes]::Black, $x, 99)
      }
    } finally { $bitmap.Dispose() }
  }
  if ($preview) { $preview.Save($PreviewPath, [System.Drawing.Imaging.ImageFormat]::Png) }
} finally {
  if ($previewFont) { $previewFont.Dispose() }
  if ($previewGraphics) { $previewGraphics.Dispose() }
  if ($preview) { $preview.Dispose() }
}
