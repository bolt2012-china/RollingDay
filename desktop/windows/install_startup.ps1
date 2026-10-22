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

# Copy tray icon beside the installed script (widget resolves schedule.ico via $PSScriptRoot).
$IcoSource = Join-Path $PSScriptRoot 'schedule.ico'
$IcoTarget = Join-Path $AppDir 'schedule.ico'
if (Test-Path $IcoSource) {
  Copy-Item -Force $IcoSource $IcoTarget
} else {
  Write-Warning "schedule.ico not found beside install_startup.ps1; widget will generate a fallback icon on first run."
}

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
# -STA is required for NotifyIcon / WinForms tray message pump.
$Shortcut.Arguments = "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Target`""
$Shortcut.WorkingDirectory = $AppDir
$Shortcut.Description = 'RollingDay always-on-top schedule widget'
if (Test-Path $IcoTarget) {
  $Shortcut.IconLocation = "$IcoTarget,0"
}
$Shortcut.Save()

Write-Host "Installed RollingDay widget:"
Write-Host "  script: $Target"
Write-Host "  icon:   $IcoTarget"
Write-Host "  config: $ConfigPath"
Write-Host "  startup shortcut: $ShortcutPath"
Write-Host "  (shortcut uses -STA for system tray)"
if (-not $Gist) {
  Write-Host "Edit config.json and set gist to owner/gist_id before first launch."
}
