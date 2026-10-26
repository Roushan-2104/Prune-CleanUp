# Draws Prune's icon (a branch with a violet band where the side shoot is
# cut) on a paper tile, at every size Windows asks for, and writes:
#   design/logo/prune-icon-1024.png      the master, for anything else
#   apps/declutter/windows/runner/resources/app_icon.ico
# Each size is drawn on its own, with heavier strokes when small, so the
# 16 px taskbar icon stays readable.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = Split-Path $PSScriptRoot -Parent

$ink = [System.Drawing.Color]::FromArgb(255, 0x2B, 0x2A, 0x27)
$stamp = [System.Drawing.Color]::FromArgb(255, 0x5B, 0x3C, 0x8C)
$paper = [System.Drawing.Color]::FromArgb(255, 0xFB, 0xFA, 0xF6)
$edge = [System.Drawing.Color]::FromArgb(255, 0xDD, 0xD8, 0xCC)

function P([double]$x, [double]$y, [double]$s) { New-Object System.Drawing.PointF ([float]($x * $s)), ([float]($y * $s)) }

# A leaf from base (bx,by) to tip (tx,ty), w = half its width.
function Leaf($g, $brush, [double]$bx, [double]$by, [double]$tx, [double]$ty, [double]$w, [double]$s) {
  $dx = $tx - $bx; $dy = $ty - $by; $len = [math]::Sqrt($dx * $dx + $dy * $dy)
  $nx = -$dy / $len * $w; $ny = $dx / $len * $w
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $path.AddBezier((P $bx $by $s), (P ($bx + 0.30 * $dx + $nx) ($by + 0.30 * $dy + $ny) $s),
    (P ($bx + 0.75 * $dx + 0.8 * $nx) ($by + 0.75 * $dy + 0.8 * $ny) $s), (P $tx $ty $s))
  $path.AddBezier((P $tx $ty $s), (P ($bx + 0.75 * $dx - 0.8 * $nx) ($by + 0.75 * $dy - 0.8 * $ny) $s),
    (P ($bx + 0.30 * $dx - $nx) ($by + 0.30 * $dy - $ny) $s), (P $bx $by $s))
  $g.FillPath($brush, $path)
  $path.Dispose()
}

function Draw([int]$size) {
  $bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'
  $g.PixelOffsetMode = 'HighQuality'
  $g.Clear([System.Drawing.Color]::Transparent)
  $s = [double]$size
  $bold = if ($size -le 20) { 1.7 } elseif ($size -le 32) { 1.35 } elseif ($size -le 48) { 1.15 } else { 1.0 }

  # Paper tile with a rounded corner, so the ink mark reads on dark taskbars too.
  $m = [math]::Max(0.5, $s * 0.03); $r = $s * 0.2; $wd = $s - 2 * $m
  $tile = New-Object System.Drawing.Drawing2D.GraphicsPath
  $tile.AddArc($m, $m, 2 * $r, 2 * $r, 180, 90)
  $tile.AddArc($m + $wd - 2 * $r, $m, 2 * $r, 2 * $r, 270, 90)
  $tile.AddArc($m + $wd - 2 * $r, $m + $wd - 2 * $r, 2 * $r, 2 * $r, 0, 90)
  $tile.AddArc($m, $m + $wd - 2 * $r, 2 * $r, 2 * $r, 90, 90)
  $tile.CloseFigure()
  $g.FillPath((New-Object System.Drawing.SolidBrush $paper), $tile)
  $g.DrawPath((New-Object System.Drawing.Pen $edge, ([float][math]::Max(1, $s / 128))), $tile)

  # Small sizes: the mark fills more of the tile.
  if ($size -le 24) {
    $k = 1.12
    $g.TranslateTransform([float](-($k - 1) * $s / 2), [float](-($k - 1) * $s / 2))
    $g.ScaleTransform([float]$k, [float]$k)
  }

  $inkBrush = New-Object System.Drawing.SolidBrush $ink
  $stem = New-Object System.Drawing.Pen $ink, ([float]($s * 0.055 * $bold))
  $stem.StartCap = 'Flat'; $stem.EndCap = 'Round'

  # Main stem, bottom left curving up to the top leaf.
  $g.DrawBezier($stem, (P 0.17 0.84 $s), (P 0.33 0.74 $s), (P 0.46 0.63 $s), (P 0.56 0.47 $s))
  # Side shoot to the right, cut square at its end.
  $shoot = New-Object System.Drawing.Pen $ink, ([float]($s * 0.05 * $bold))
  $shoot.StartCap = 'Round'; $shoot.EndCap = 'Flat'
  $g.DrawLine($shoot, (P 0.42 0.685 $s), (P 0.80 0.505 $s))

  Leaf $g $inkBrush 0.55 0.48 0.79 0.15 (0.095 * [math]::Min($bold, 1.2)) $s   # top leaf
  Leaf $g $inkBrush 0.45 0.60 0.30 0.33 (0.075 * [math]::Min($bold, 1.2)) $s   # left leaf
  if ($size -gt 20) { Leaf $g $inkBrush 0.69 0.565 0.86 0.83 (0.07 * [math]::Min($bold, 1.2)) $s }  # leaf on the shoot

  # The violet band across the shoot: what Prune marks to remove.
  $band = New-Object System.Drawing.Pen $stamp, ([float]($s * 0.055 * $bold))
  $band.StartCap = 'Flat'; $band.EndCap = 'Flat'
  if ($size -le 24) { $g.DrawLine($band, (P 0.56 0.47 $s), (P 0.67 0.71 $s)) }
  else { $g.DrawLine($band, (P 0.575 0.51 $s), (P 0.655 0.68 $s)) }

  $g.Dispose()
  return $bmp
}

function PngBytes($bmp) {
  $ms = New-Object System.IO.MemoryStream
  $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
  return $ms.ToArray()
}

$logoDir = Join-Path $root 'design\logo'
New-Item -ItemType Directory -Force $logoDir | Out-Null
$master = Draw 1024
$master.Save((Join-Path $logoDir 'prune-icon-1024.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$master.Dispose()
foreach ($n in 16, 32, 48) {
  $b = Draw $n; $b.Save((Join-Path $logoDir "prune-icon-$n.png"), [System.Drawing.Imaging.ImageFormat]::Png); $b.Dispose()
}

# .ico with PNG images (Windows Vista and later read these).
$sizes = 16, 20, 24, 32, 40, 48, 64, 256
$images = foreach ($n in $sizes) { $b = Draw $n; , (PngBytes $b); $b.Dispose() }
$ico = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter $ico
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
  $n = $sizes[$i]; $len = $images[$i].Length
  $w.Write([byte]($n % 256)); $w.Write([byte]($n % 256)); $w.Write([byte]0); $w.Write([byte]0)
  $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$len); $w.Write([uint32]$offset)
  $offset += $len
}
foreach ($img in $images) { $w.Write([byte[]]$img) }
$w.Flush()
$icoPath = Join-Path $root 'apps\declutter\windows\runner\resources\app_icon.ico'
[System.IO.File]::WriteAllBytes($icoPath, $ico.ToArray())
Write-Output "Wrote $icoPath and design\logo\prune-icon-*.png"
