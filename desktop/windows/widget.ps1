Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase

$ErrorActionPreference = 'Stop'
$ConfigDir = Join-Path $env:APPDATA 'RollingDay'
$ConfigPath = if ($env:ROLLINGDAY_CONFIG) { $env:ROLLINGDAY_CONFIG } else { Join-Path $ConfigDir 'config.json' }
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null

function Load-Config {
  if (-not (Test-Path $ConfigPath)) {
    @{
      gist = 'owner/gist_id'
      timezone = 'China Standard Time'
      width = 300
      height = 380
    } | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 $ConfigPath
  }
  return Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Resolve-Gist($gist) {
  $value = [string]$gist
  $value = $value.Trim() -replace '^https://gist.github.com/', ''
  $parts = @($value -split '/' | Where-Object { $_ })
  if ($parts.Count -ge 2) { return @{ owner = $parts[0]; id = $parts[1] } }
  if ($parts.Count -eq 1) { return @{ owner = ''; id = $parts[0] } }
  return @{ owner = ''; id = '' }
}

function Get-TimeZoneInfo($name) {
  try { return [System.TimeZoneInfo]::FindSystemTimeZoneById($name) } catch {}
  if ($name -eq 'Asia/Shanghai') {
    try { return [System.TimeZoneInfo]::FindSystemTimeZoneById('China Standard Time') } catch {}
  }
  return [System.TimeZoneInfo]::Local
}

function New-Client($token) {
  $client = New-Object Net.WebClient
  $client.Encoding = [Text.Encoding]::UTF8
  $client.Headers.Add('User-Agent', 'RollingDay')
  if ($token) {
    $client.Headers.Add('Authorization', "Bearer $token")
    $client.Headers.Add('Accept', 'application/vnd.github+json')
  }
  return $client
}

$Config = Load-Config
$Gist = Resolve-Gist $Config.gist
$Timezone = Get-TimeZoneInfo $Config.timezone
$Width = if ($Config.width) { [int]$Config.width } else { 300 }
$Height = if ($Config.height) { [int]$Config.height } else { 380 }
$TokenFile = if ($Config.token_file) { [string]$Config.token_file } else { Join-Path $ConfigDir 'token.dat' }

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$w = New-Object Windows.Window -Property @{
  WindowStyle = 'None'
  AllowsTransparency = $true
  Topmost = $true
  ShowInTaskbar = $false
  Width = $Width
  Height = $Height
  Background = [Windows.Media.Brushes]::Transparent
}
$wa = [Windows.SystemParameters]::WorkArea
$w.Left = $wa.Right - $Width - 10
$w.Top = $wa.Top + 10
$bd = New-Object Windows.Controls.Border -Property @{
  CornerRadius = 8
  Padding = 8
  Background = (New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(200, 17, 17, 17)))
}
$dp = New-Object Windows.Controls.DockPanel
$bd.Child = $dp
$w.Content = $bd
$hd = New-Object Windows.Controls.TextBlock -Property @{
  Foreground = '#77ddcc'
  FontWeight = 'Bold'
  TextWrapping = 'Wrap'
  FontFamily = 'Microsoft YaHei'
  FontSize = 13
  Margin = '0,0,0,6'
}
[Windows.Controls.DockPanel]::SetDock($hd, 'Top')
[void]$dp.Children.Add($hd)
$sv = New-Object Windows.Controls.ScrollViewer -Property @{ VerticalScrollBarVisibility = 'Hidden' }
$sp = New-Object Windows.Controls.StackPanel
$sv.Content = $sp
[void]$dp.Children.Add($sv)

function Add-Line($text, $color, $bold = $false, $background = $null) {
  $tb = New-Object Windows.Controls.TextBlock -Property @{
    Text = $text
    Foreground = $color
    TextWrapping = 'Wrap'
    FontFamily = 'Microsoft YaHei'
    FontSize = 12
    Margin = '0,1,0,1'
    Padding = '3,1,3,1'
  }
  if ($bold) { $tb.FontWeight = 'Bold' }
  if ($background) { $tb.Background = $background }
  [void]$sp.Children.Add($tb)
}

function Read-GistFile($name, $token = $null) {
  if (-not $Gist.id -or $Gist.id -eq 'gist_id') {
    throw "请先编辑 $ConfigPath，设置 gist 为 owner/gist_id"
  }
  if ($Gist.owner) {
    $url = "https://gist.githubusercontent.com/$($Gist.owner)/$($Gist.id)/raw/$name?t=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
    try { return (New-Client $token).DownloadString($url) } catch {}
  }
  $api = "https://api.github.com/gists/$($Gist.id)"
  $gistObj = (New-Client $token).DownloadString($api) | ConvertFrom-Json
  if (-not $gistObj.files.$name) { throw "gist 中缺少 $name" }
  return $gistObj.files.$name.content
}

function Get-Token {
  if (Test-Path $TokenFile) {
    $secure = Get-Content $TokenFile | ConvertTo-SecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
  }
  $dialog = New-Object Windows.Window -Property @{
    Title = 'GitHub token'
    Width = 340
    Height = 140
    Topmost = $true
    WindowStartupLocation = 'CenterScreen'
    ResizeMode = 'NoResize'
  }
  $panel = New-Object Windows.Controls.StackPanel -Property @{ Margin = 8 }
  $dialog.Content = $panel
  [void]$panel.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = '输入 GitHub token（gist 权限，DPAPI 加密保存在本机）' }))
  $password = New-Object Windows.Controls.PasswordBox -Property @{ Margin = '0,6,0,6' }
  [void]$panel.Children.Add($password)
  $ok = New-Object Windows.Controls.Button -Property @{ Content = '保存'; IsDefault = $true; Width = 60 }
  $ok.Add_Click({ $dialog.DialogResult = $true })
  [void]$panel.Children.Add($ok)
  $password.Focus() | Out-Null
  if (-not $dialog.ShowDialog() -or -not $password.Password) { return $null }
  $password.SecurePassword | ConvertFrom-SecureString | Set-Content $TokenFile
  return $password.Password.Trim()
}

$script:lastW = [DateTime]::MinValue
$script:DONE = @{}
$script:pos = 0.0
$script:pause = $false

function Load-Schedule {
  try {
    $schedule = Read-GistFile 'schedule.json' | ConvertFrom-Json
    $now = [System.TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $Timezone)
    $today = $now.ToString('yyyy-MM-dd')
    $hm = $now.ToString('HH:mm')
    $sp.Children.Clear()
    $cur = $null
    $nx = $null
    foreach ($d in $schedule.days) {
      if ($d.date -lt $today) { continue }
      Add-Line $d.label '#88aaff' $true
      foreach ($b in $d.blocks) {
        $color = '#dddddd'
        $bg = $null
        if ($d.date -eq $today -and $b.start -le $hm -and $hm -lt $b.end) {
          $cur = $b
          $color = '#ffffff'
          $bg = '#14392f'
        } elseif ($d.date -eq $today -and $b.end -and $b.end -le $hm) {
          $color = '#777777'
        } elseif (-not $nx -and $b.kind -ne 'note') {
          $nx = $b
        }
        if ($b.kind -eq 'class' -and $color -eq '#dddddd') { $color = '#c8a8ff' }
        Add-Line ("{0}-{1} {2}" -f $b.start, $b.end, $b.title) $color $false $bg
      }
    }
    Add-Line '待办' '#88aaff' $true
    if (((Get-Date) - $script:lastW).TotalMinutes -gt 3) {
      try {
        $doneJson = Read-GistFile 'done.json' | ConvertFrom-Json
        $script:DONE = @{}
        foreach ($x in $doneJson.done) { $script:DONE[$x.id] = 1 }
      } catch {}
    }
    $priorityColors = @{ '高' = '#ff7777'; '中' = '#eebb55'; '低' = '#88cc88' }
    foreach ($t in $schedule.todos) {
      $color = $priorityColors[[string]$t.priority]
      if (-not $color) { $color = '#dddddd' }
      $done = $script:DONE.ContainsKey($t.id) -or $t.done
      $cb = New-Object Windows.Controls.CheckBox -Property @{
        IsChecked = $done
        Margin = '0,1,0,1'
        Foreground = $(if ($done) { '#777777' } else { $color })
      }
      $cb.Content = New-Object Windows.Controls.TextBlock -Property @{
        Text = ("[{0}] {1} {2}" -f $t.priority, $t.title, $t.due)
        TextWrapping = 'Wrap'
        FontFamily = 'Microsoft YaHei'
        FontSize = 12
      }
      if ($done) { $cb.Content.TextDecorations = [Windows.TextDecorations]::Strikethrough }
      $cb.Tag = $t
      $cb.Add_Click({ param($o, $e) Toggle-Done $o.Tag ([bool]$o.IsChecked) $o })
      [void]$sp.Children.Add($cb)
    }
    Add-Line ("更新于 " + $schedule.updated_at) '#666666'
    $hd.Text = $(if ($cur) { "现在：$($cur.title)（至 $($cur.end)）" } else { '现在：空闲' }) + $(if ($nx) { "`n下一项：$($nx.start) $($nx.title)" } else { '' })
  } catch {
    $hd.Text = "加载失败：$($_.Exception.Message)"
  }
}

function Toggle-Done($todo, $checked, $checkbox) {
  $checkbox.Foreground = $(if ($checked) { '#777777' } else { '#dddddd' })
  $checkbox.Content.TextDecorations = $(if ($checked) { [Windows.TextDecorations]::Strikethrough } else { $null })
  try {
    $token = Get-Token
    if (-not $token) { throw '未提供 token' }
    $api = "https://api.github.com/gists/$($Gist.id)"
    $gistObj = (New-Client $token).DownloadString($api) | ConvertFrom-Json
    $list = @()
    if ($gistObj.files.'done.json') {
      try { $list = @(($gistObj.files.'done.json'.content | ConvertFrom-Json).done) } catch {}
    }
    $list = @($list | Where-Object { $_ -and $_.id -ne $todo.id })
    if ($checked) {
      $list += [pscustomobject]@{ id = $todo.id; title = $todo.title; at = [DateTime]::UtcNow.ToString('o') }
    }
    $inner = ConvertTo-Json -InputObject @{ done = @($list) } -Depth 5 -Compress
    $body = ConvertTo-Json -InputObject @{ files = @{ 'done.json' = @{ content = $inner } } } -Depth 5 -Compress
    $client = New-Client $token
    $client.Headers.Add('Content-Type', 'application/json; charset=utf-8')
    [void]$client.UploadData($api, 'PATCH', [Text.Encoding]::UTF8.GetBytes($body))
    $script:DONE = @{}
    foreach ($x in $list) { $script:DONE[$x.id] = 1 }
    $script:lastW = Get-Date
    $todo.done = $false
  } catch {
    $hd.Text = "勾选失败：$($_.Exception.Message)"
    $checkbox.IsChecked = -not $checked
    $checkbox.Foreground = $(if (-not $checked) { '#777777' } else { '#dddddd' })
    $checkbox.Content.TextDecorations = $(if (-not $checked) { [Windows.TextDecorations]::Strikethrough } else { $null })
  }
}

$w.Add_MouseLeftButtonDown({ $w.DragMove() })
$w.Add_MouseRightButtonUp({ $w.Close() })
$sv.Add_MouseEnter({ $script:pause = $true })
$sv.Add_MouseLeave({ $script:pause = $false })

$timerLoad = New-Object Windows.Threading.DispatcherTimer
$timerLoad.Interval = [TimeSpan]::FromSeconds(60)
$timerLoad.Add_Tick({ Load-Schedule })
$timerLoad.Start()

$timerScroll = New-Object Windows.Threading.DispatcherTimer
$timerScroll.Interval = [TimeSpan]::FromMilliseconds(40)
$timerScroll.Add_Tick({
  if ($script:pause) { return }
  $script:pos += 0.5
  if ($script:pos -gt $sv.ScrollableHeight + 60) { $script:pos = -80 }
  $sv.ScrollToVerticalOffset([Math]::Max(0, $script:pos))
})
$timerScroll.Start()

$w.Add_Loaded({ Load-Schedule })
[void]$w.ShowDialog()
