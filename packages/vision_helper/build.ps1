# Builds PruneVision.exe with the C# compiler that ships with Windows.
# No SDK or download needed: the Windows OCR / face APIs are described by the
# .winmd files every Windows 10/11 install has in System32\WinMetadata.
$ErrorActionPreference = 'Stop'
$fw = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319"
$md = "$env:WINDIR\System32\WinMetadata"
$out = Join-Path $PSScriptRoot 'bin'
New-Item -ItemType Directory -Force $out | Out-Null

$refs = @(
  "$md\Windows.Foundation.winmd",
  "$md\Windows.Globalization.winmd",
  "$md\Windows.Graphics.winmd",
  "$md\Windows.Media.winmd",
  "$md\Windows.Storage.winmd",
  "$fw\System.Runtime.dll",
  "$fw\System.Runtime.InteropServices.WindowsRuntime.dll"
) | ForEach-Object { "/r:$_" }

& "$fw\csc.exe" /nologo /optimize+ /platform:x64 /target:exe `
  "/out:$out\PruneVision.exe" @refs (Join-Path $PSScriptRoot 'PruneVision.cs')
if ($LASTEXITCODE -ne 0) { throw "Build failed" }
Write-Output "Built $out\PruneVision.exe"
