param(
  [string]$Gist = '',
  [string]$Timezone = 'China Standard Time',
  [int]$Width = 300,
  [int]$Height = 380
)

$ErrorActionPreference = 'Stop'
$Source = Join-Path $PSScriptRoot 'widget.ps1'
if (-not (Test-Path $Source)) {
  throw "widget.ps1 not found beside install_startup.ps1"
}

$AppDir = Join-Path $env:APPDATA 'RollingDay'
New-Item -ItemType Directory -Force -Path $AppDir | Out-Null

$Target = Join-Path $AppDir 'widget.ps1'
Copy-Item -Force $Source $Target

$ConfigPath = Join-Path $AppDir 'config.json'
if ($Gist -or -not (Test-Path $ConfigPath)) {
  @{
    gist = $(if ($Gist) { $Gist } else { 'owner/gist_id' })
    timezone = $Timezone
    width = $Width
    height = $Height
  } | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 $ConfigPath
}

$StartupDir = [Environment]::GetFolderPath('Startup')
$ShortcutPath = Join-Path $StartupDir 'RollingDay.lnk'
$Shell = New-Object -ComObject WScript.Shell
$Shortcut = $Shell.CreateShortcut($ShortcutPath)
$Shortcut.TargetPath = 'powershell.exe'
$Shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$Target`""
$Shortcut.WorkingDirectory = $AppDir
$Shortcut.Description = 'RollingDay always-on-top schedule widget'
$Shortcut.Save()

Write-Host "Installed RollingDay widget:"
Write-Host "  script: $Target"
Write-Host "  config: $ConfigPath"
Write-Host "  startup shortcut: $ShortcutPath"
if (-not $Gist) {
  Write-Host "Edit config.json and set gist to owner/gist_id before first launch."
}
