# Builds the release: dist\Prune-<version>.zip (portable) and, when Inno
# Setup 6 is installed, dist\Prune-<version>-Setup.exe. Both hold Prune.exe,
# its libraries, PruneVision.exe, the adb folder and the user guide.
# The version comes from apps\declutter\pubspec.yaml.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$app = Join-Path $root 'apps\declutter'
$release = Join-Path $app 'build\windows\x64\runner\Release'
$dist = Join-Path $root 'dist'
$stage = Join-Path $dist 'Prune'

$match = Select-String -Path (Join-Path $app 'pubspec.yaml') -Pattern '^version:\s*(\d+\.\d+\.\d+)'
if (-not $match) { throw 'No version found in pubspec.yaml' }
$version = $match.Matches[0].Groups[1].Value

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
Copy-Item (Join-Path $root 'docs\USER_GUIDE.md') (Join-Path $stage 'Read me first.txt')

$zip = Join-Path $dist "Prune-$version.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
# Windows' own tar (bsdtar) writes standard zip paths; PowerShell 5's
# Compress-Archive writes backslashes that some unzip tools mishandle.
& "$env:WINDIR\System32\tar.exe" -a -c -f $zip -C $dist Prune
if ($LASTEXITCODE -ne 0) { throw 'Zip failed' }
Remove-Item -Recurse -Force $stage
$mb = [math]::Round((Get-Item $zip).Length / 1MB, 1)
Write-Output "Built $zip ($mb MB)"

# The installer too, when Inno Setup 6 is installed.
$setup = Join-Path $dist "Prune-$version-Setup.exe"
$iscc = @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe") |
  Where-Object { Test-Path $_ } | Select-Object -First 1
if ($iscc) {
  & $iscc /Q "/DAppVersion=$version" "/DRelease=$release" (Join-Path $PSScriptRoot 'prune.iss')
  if ($LASTEXITCODE -ne 0) { throw 'Installer build failed' }
  $mb = [math]::Round((Get-Item $setup).Length / 1MB, 1)
  Write-Output "Built $setup ($mb MB)"
} else {
  Write-Output "Inno Setup 6 not found: skipped $(Split-Path $setup -Leaf)"
}
