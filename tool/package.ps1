# Builds the portable beta: dist\Prune-beta.zip, holding Prune.exe, its
# libraries, PruneVision.exe, the adb folder and the tester guide.
# Unzip anywhere and run Prune.exe; nothing is installed.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$app = Join-Path $root 'apps\declutter'
$release = Join-Path $app 'build\windows\x64\runner\Release'
$dist = Join-Path $root 'dist'
$stage = Join-Path $dist 'Prune'

& (Join-Path $root 'packages\vision_helper\build.ps1')

Push-Location $app
try {
  flutter build windows --release
  if ($LASTEXITCODE -ne 0) { throw 'Flutter build failed' }
} finally { Pop-Location }

foreach ($need in 'Prune.exe', 'PruneVision.exe', 'adb\adb.exe', 'adb\AdbWinApi.dll', 'adb\AdbWinUsbApi.dll') {
  if (-not (Test-Path (Join-Path $release $need))) { throw "Missing from the build: $need" }
}

if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item -Recurse (Join-Path $release '*') $stage
Copy-Item (Join-Path $root 'docs\BETA_GUIDE.md') (Join-Path $stage 'Read me first.txt')

$zip = Join-Path $dist 'Prune-beta.zip'
if (Test-Path $zip) { Remove-Item -Force $zip }
# Windows' own tar (bsdtar) writes standard zip paths; PowerShell 5's
# Compress-Archive writes backslashes that some unzip tools mishandle.
& "$env:WINDIR\System32\tar.exe" -a -c -f $zip -C $dist Prune
if ($LASTEXITCODE -ne 0) { throw 'Zip failed' }
Remove-Item -Recurse -Force $stage
$mb = [math]::Round((Get-Item $zip).Length / 1MB, 1)
Write-Output "Built $zip ($mb MB)"
