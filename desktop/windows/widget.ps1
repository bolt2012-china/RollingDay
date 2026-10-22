Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms,System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

# NotifyIcon requires an STA thread; relaunch if needed.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
  Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @(
    '-NoProfile', '-STA', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
  ) -WindowStyle Hidden
  exit 0
}

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

# Icon lives beside this script (install copies schedule.ico into %APPDATA%\RollingDay).
$IcoPath = if ($Config.icon_path) { [string]$Config.icon_path } else { Join-Path $PSScriptRoot 'schedule.ico' }

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
$script:reallyExit = $false
$script:hidTipShown = $false
$script:ni = $null
$script:owner = $null

function New-ItemText($text, $color, $background = $null) {
  $tb = New-Object Windows.Controls.TextBlock -Property @{
    Text = $text
    Foreground = $color
    TextWrapping = 'Wrap'
    FontFamily = 'Microsoft YaHei'
    FontSize = 12
    Padding = '3,1,3,1'
  }
  if ($background) { $tb.Background = $background }
  return $tb
}

function Load-Schedule {
  try {
    $schedule = Read-GistFile 'schedule.json' | ConvertFrom-Json
    if (((Get-Date) - $script:lastW).TotalMinutes -gt 3) {
      try {
        $doneJson = Read-GistFile 'done.json' | ConvertFrom-Json
        $script:DONE = @{}
        foreach ($x in $doneJson.done) { $script:DONE[$x.id] = 1 }
      } catch {}
    }
    if (((Get-Date) - $script:editsW).TotalMinutes -gt 3) {
      try {
        $editsJson = Read-GistFile 'edits.json' | ConvertFrom-Json
        $script:EDITS = @($editsJson.edits | Where-Object { $_ })
      } catch {}
    }
    $script:S = $schedule
    # Don't rebuild the list under an active drag or an open swipe.
    if ($script:gs -or $script:openRow) { return }
    Render-Schedule $schedule
  } catch {
    $hd.Text = "加载失败：$($_.Exception.Message)"
  }
}

function Render-Schedule($schedule) {
    $now = [System.TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $Timezone)
    $today = $now.ToString('yyyy-MM-dd')
    $hm = $now.ToString('HH:mm')
    $script:openRow = $null
    $script:gs = $null
    $sp.Children.Clear()
    $editMap = RD-EditMap
    $cur = $null
    $nx = $null
    foreach ($d in $schedule.days) {
      if ($d.date -lt $today) { continue }
      Add-Line $d.label '#88aaff' $true
      foreach ($b in (RD-Overlay $d.blocks 'block' $editMap)) {
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
        $tb = New-ItemText ("{0}-{1} {2}" -f $b.start, $b.end, $b.title) $color $bg
        if ($b.pend) { $tb.FontStyle = 'Italic' }
        if ($b.id) { Add-Item $tb $b 'block' } else { $tb.Margin = '0,1,0,1'; [void]$sp.Children.Add($tb) }
      }
    }
    Add-Line '待办' '#88aaff' $true
    $priorityColors = @{ '高' = '#ff7777'; '中' = '#eebb55'; '低' = '#88cc88' }
    foreach ($t in (RD-Overlay $schedule.todos 'todo' $editMap)) {
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
      if ($t.pend) { $cb.Content.FontStyle = 'Italic' }
      $cb.Tag = $t
      $cb.Add_Click({ param($o, $e) Toggle-Done $o.Tag ([bool]$o.IsChecked) $o })
      Add-Item $cb $t 'todo'
    }
    Add-Line ("更新于 " + $schedule.updated_at + " · 右键/长按编辑 · 左拖出按钮") '#666666'
    $hd.Text = $(if ($cur) { "现在：$($cur.title)（至 $($cur.end)）" } else { '现在：空闲' }) + $(if ($nx) { "`n下一项：$($nx.start) $($nx.title)" } else { '' })
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

function RD-Token { Get-Token }
function RD-Client($tok) { New-Client $tok }
$RdApi = "https://api.github.com/gists/$($Gist.id)"
# ---- RollingDay item gestures + edits.json write-back ---------------------
# Right-click or long left-press (~0.5s) on an item opens a 编辑/删除 menu;
# dragging an item left reveals 编辑/删除 buttons. Edits are shown at once
# (optimistic) and appended to edits.json in the gist; sync_gist.py applies
# them to the markdown files and clears them.
$script:EDITS = @()
$script:editsW = [DateTime]::MinValue
$script:S = $null
$script:gs = $null
$script:openRow = $null
$RdActW = 112
$script:lpTimer = New-Object Windows.Threading.DispatcherTimer
$script:lpTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:lpTimer.Add_Tick({
  $script:lpTimer.Stop()
  $g = $script:gs
  if (-not $g -or $g.moved -or $g.swiping) { return }
  $g.fired = $true
  [void]$g.row.CaptureMouse()   # steal capture so a held checkbox doesn't toggle on release
  $g.row.ReleaseMouseCapture()
  RD-OpenMenu $g.row
})

function RD-Fields($o) {
  $h = @{}
  if ($null -eq $o) { return $h }
  if ($o -is [hashtable]) { foreach ($k in $o.Keys) { $h[$k] = $o[$k] }; return $h }
  foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value }
  return $h
}

function RD-Merge($list, $e) {
  $out = @(); $prev = $null
  foreach ($x in @($list)) {
    if (-not $x) { continue }
    if ($x.id -eq $e.id -and $x.type -eq $e.type) { $prev = $x } else { $out += $x }
  }
  if ($prev -and $prev.action -eq 'edit' -and $e.action -eq 'edit') {
    $f = RD-Fields $prev.fields
    $nf = RD-Fields $e.fields
    foreach ($k in $nf.Keys) { $f[$k] = $nf[$k] }
    $e.fields = $f
  }
  $out += $e
  return ,$out
}

function RD-EditMap {
  $m = @{}
  foreach ($e in @($script:EDITS)) { if ($e -and $e.id) { $m[[string]$e.id] = $e } }
  return $m
}

function RD-Overlay($items, $type, $map) {
  $out = @()
  foreach ($it in @($items)) {
    if (-not $it) { continue }
    $e = $null
    if ($it.id) { $e = $map[[string]$it.id] }
    if ($e -and $e.type -and $e.type -ne $type) { $e = $null }
    if (-not $e) { $out += $it; continue }
    if ($e.action -eq 'delete') { continue }
    $c = $it.PSObject.Copy()
    $f = RD-Fields $e.fields
    $keys = if ($type -eq 'todo') { @('title', 'due', 'priority', 'note') } else { @('title', 'start', 'end') }
    foreach ($k in $keys) {
      if ($f.ContainsKey($k) -and ($type -eq 'todo' -or $f[$k])) { $c | Add-Member -NotePropertyName $k -NotePropertyValue ([string]$f[$k]) -Force }
    }
    $c | Add-Member -NotePropertyName pend -NotePropertyValue 1 -Force
    $out += $c
  }
  if ($type -eq 'block') { $out = @($out | Sort-Object { [string]$_.start }) }
  return ,$out
}

function RD-CloseRows {
  if ($script:openRow) {
    $i = $script:openRow.Tag
    $i.tt.X = 0
    $i.acts.Visibility = 'Hidden'
    $script:openRow = $null
  }
}

function RD-OpenMenu($row) {
  RD-CloseRows
  $cm = $row.ContextMenu
  $cm.PlacementTarget = $row
  $cm.Placement = 'MousePoint'
  $cm.IsOpen = $true
}

function RD-NewButton($text, $color, $info, $act) {
  $b = New-Object Windows.Controls.Button -Property @{
    Content = $text; Width = ($RdActW / 2); Foreground = '#ffffff'; BorderThickness = 0
    Background = $color; FontFamily = 'Microsoft YaHei'; FontSize = 12; Cursor = 'Hand'
  }
  $b.Tag = @{ info = $info; act = $act }
  $b.Add_Click({ param($o, $e) $t = $o.Tag; RD-CloseRows; if ($t.act -eq 'edit') { RD-EditDialog $t.info } else { RD-Delete $t.info } })
  return $b
}

function Add-Item($el, $item, $type) {
  $row = New-Object Windows.Controls.Grid -Property @{ ClipToBounds = $true; Margin = '0,1,0,1'; Background = [Windows.Media.Brushes]::Transparent }
  $acts = New-Object Windows.Controls.StackPanel -Property @{ Orientation = 'Horizontal'; HorizontalAlignment = 'Right'; Visibility = 'Hidden' }
  $fg = New-Object Windows.Controls.Border -Property @{ Child = $el; Background = (New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(1, 0, 0, 0))) }
  $tt = New-Object Windows.Media.TranslateTransform
  $fg.RenderTransform = $tt
  $info = @{ item = $item; type = $type; tt = $tt; acts = $acts; row = $row; fg = $fg }
  $row.Tag = $info
  [void]$acts.Children.Add((RD-NewButton '编辑' '#22aa66' $info 'edit'))
  [void]$acts.Children.Add((RD-NewButton '删除' '#cc3333' $info 'del'))
  [void]$row.Children.Add($acts)
  [void]$row.Children.Add($fg)
  $cm = New-Object Windows.Controls.ContextMenu
  $mi1 = New-Object Windows.Controls.MenuItem -Property @{ Header = '编辑' }
  $mi1.Tag = $info
  $mi1.Add_Click({ param($o, $e) RD-EditDialog $o.Tag })
  $mi2 = New-Object Windows.Controls.MenuItem -Property @{ Header = '删除' }
  $mi2.Tag = $info
  $mi2.Add_Click({ param($o, $e) RD-Delete $o.Tag })
  [void]$cm.Items.Add($mi1); [void]$cm.Items.Add($mi2)
  $row.ContextMenu = $cm   # right-click on an item; window/tray menus are untouched
  $row.Add_PreviewMouseLeftButtonDown({
    param($o, $e)
    $src = $e.OriginalSource
    $i = $o.Tag
    if ($src -is [Windows.DependencyObject]) {
      $p = $src
      while ($p -and $p -ne $o) {
        if ($p -is [Windows.Controls.Button]) { return }
        $p = [Windows.Media.VisualTreeHelper]::GetParent($p)
      }
    }
    $pt = $e.GetPosition($sp)
    $base = 0
    if ($script:openRow -eq $o) { $base = -$RdActW }
    $script:gs = @{ row = $o; x = $pt.X; y = $pt.Y; moved = $false; swiping = $false; fired = $false; base = $base }
    $script:lpTimer.Stop(); $script:lpTimer.Start()
    if ($i.type -ne 'todo') { $e.Handled = $true }   # no window DragMove from items; checkbox still gets its click
  })
  $row.Add_PreviewMouseMove({
    param($o, $e)
    $g = $script:gs
    if (-not $g -or $g.row -ne $o) { return }
    if ($e.LeftButton -ne 'Pressed') { return }
    $pt = $e.GetPosition($sp)
    $dx = $pt.X - $g.x; $dy = $pt.Y - $g.y
    $adx = [Math]::Abs($dx); $ady = [Math]::Abs($dy)
    if (-not $g.moved -and ($adx -gt 6 -or $ady -gt 6)) { $g.moved = $true; $script:lpTimer.Stop() }
    if (-not $g.swiping -and $ady -gt 8 -and $ady -ge $adx) { $script:gs = $null; return }
    if (-not $g.swiping -and $adx -gt 8 -and $adx -gt $ady * 1.5) {
      $g.swiping = $true
      if ($script:openRow -and $script:openRow -ne $o) { RD-CloseRows }
      $o.Tag.acts.Visibility = 'Visible'
      [void]$o.CaptureMouse()
    }
    if ($g.swiping) {
      $tx = $g.base + $dx
      if ($tx -gt 0) { $tx = 0 }
      if ($tx -lt -$RdActW) { $tx = -$RdActW }
      $o.Tag.tt.X = $tx
      $e.Handled = $true
    }
  })
  $row.Add_PreviewMouseLeftButtonUp({
    param($o, $e)
    $script:lpTimer.Stop()
    $g = $script:gs
    $script:gs = $null
    if (-not $g -or $g.row -ne $o) { return }
    if ($g.fired) { $e.Handled = $true; return }
    if ($g.swiping) {
      $o.ReleaseMouseCapture()
      $i = $o.Tag
      if ($i.tt.X -lt -$RdActW / 2) {
        $i.tt.X = -$RdActW; $script:openRow = $o
      } else {
        $i.tt.X = 0; $i.acts.Visibility = 'Hidden'
        if ($script:openRow -eq $o) { $script:openRow = $null }
      }
      $e.Handled = $true
      return
    }
    if (-not $g.moved -and $script:openRow) { RD-CloseRows; $e.Handled = $true }
  })
  [void]$sp.Children.Add($row)
}

function RD-Rerender { if ($script:S) { try { Render-Schedule $script:S } catch { $hd.Text = "显示失败：$($_.Exception.Message)" } } }

function RD-Push($e) {
  $before = $script:EDITS
  $script:EDITS = RD-Merge $script:EDITS $e
  $script:editsW = Get-Date
  RD-Rerender
  try {
    $tok = RD-Token
    if (-not $tok) { throw '未提供 token' }
    $g = (RD-Client $tok).DownloadString($RdApi) | ConvertFrom-Json
    $list = @()
    if ($g.files.'edits.json') { try { $list = @(($g.files.'edits.json'.content | ConvertFrom-Json).edits) } catch {} }
    $list = RD-Merge $list $e
    $inner = ConvertTo-Json -InputObject @{ edits = @($list) } -Depth 8
    $body = ConvertTo-Json -InputObject @{ files = @{ 'edits.json' = @{ content = $inner } } } -Depth 8 -Compress
    $c = RD-Client $tok
    $c.Headers.Add('Content-Type', 'application/json; charset=utf-8')
    [void]$c.UploadData($RdApi, 'PATCH', [Text.Encoding]::UTF8.GetBytes($body))
    $script:EDITS = @($list)
    $script:editsW = Get-Date
  } catch {
    $script:EDITS = $before
    RD-Rerender
    $hd.Text = "$(if ($e.action -eq 'delete') { '删除' } else { '编辑' })失败：$($_.Exception.Message)"
  }
}

function RD-NewEdit($info, $action, $fields) {
  return [pscustomobject]@{
    eid = ('w' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString() + (Get-Random -Maximum 99999))
    id = [string]$info.item.id; type = $info.type; action = $action; fields = $fields
    at = [DateTime]::UtcNow.ToString('o')
  }
}

function RD-Delete($info) {
  $r = [Windows.MessageBox]::Show("删除「$($info.item.title)」？", '滚滚日程', 'OKCancel', 'Question')
  if ($r -ne 'OK') { return }
  RD-Push (RD-NewEdit $info 'delete' @{})
}

function RD-Field($panel, $label, $value) {
  [void]$panel.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = $label; Foreground = '#99aabb'; Margin = '0,6,0,2' }))
  $tb = New-Object Windows.Controls.TextBox -Property @{ Text = [string]$value; Padding = '4,3,4,3' }
  [void]$panel.Children.Add($tb)
  return $tb
}

function RD-EditDialog($info) {
  RD-CloseRows
  $it = $info.item
  $todo = $info.type -eq 'todo'
  $d = New-Object Windows.Window -Property @{
    Title = $(if ($todo) { '编辑待办' } else { '编辑日程' }); Width = 340; SizeToContent = 'Height'
    Topmost = $true; WindowStartupLocation = 'CenterScreen'; ResizeMode = 'NoResize'; FontFamily = 'Microsoft YaHei'
  }
  $p = New-Object Windows.Controls.StackPanel -Property @{ Margin = 10 }
  $d.Content = $p
  $tS = $null; $tE = $null; $tDue = $null; $cPri = $null; $tNote = $null
  if (-not $todo) {
    $st = if ($it.start -eq '--:--') { '' } else { [string]$it.start }
    $tS = RD-Field $p '开始（HH:MM）' $st
    $tE = RD-Field $p '结束（HH:MM）' $it.end
  }
  $tT = RD-Field $p '内容' $it.title
  if ($todo) {
    $tDue = RD-Field $p '截止' $it.due
    [void]$p.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = '优先级'; Foreground = '#99aabb'; Margin = '0,6,0,2' }))
    $cPri = New-Object Windows.Controls.ComboBox
    foreach ($x in @('高', '中', '低')) { [void]$cPri.Items.Add($x) }
    $cPri.SelectedItem = $(if ($it.priority) { [string]$it.priority } else { '中' })
    [void]$p.Children.Add($cPri)
    $tNote = RD-Field $p '备注' $it.note
  }
  $bp = New-Object Windows.Controls.StackPanel -Property @{ Orientation = 'Horizontal'; HorizontalAlignment = 'Right'; Margin = '0,12,0,0' }
  $bSave = New-Object Windows.Controls.Button -Property @{ Content = '保存'; IsDefault = $true; Width = 70; Margin = '0,0,6,0' }
  $bDel = New-Object Windows.Controls.Button -Property @{ Content = '删除'; Width = 70; Margin = '0,0,6,0'; Foreground = '#cc3333' }
  $bCancel = New-Object Windows.Controls.Button -Property @{ Content = '取消'; IsCancel = $true; Width = 70 }
  [void]$bp.Children.Add($bSave); [void]$bp.Children.Add($bDel); [void]$bp.Children.Add($bCancel)
  [void]$p.Children.Add($bp)
  $script:dlgResult = $null
  $bSave.Add_Click({ $script:dlgResult = 'save'; $d.Close() })
  $bDel.Add_Click({ $script:dlgResult = 'delete'; $d.Close() })
  $tT.Focus() | Out-Null
  $tT.SelectAll()
  [void]$d.ShowDialog()
  if ($script:dlgResult -eq 'delete') { RD-Delete $info; return }
  if ($script:dlgResult -ne 'save') { return }
  $title = $tT.Text.Trim()
  if (-not $title) { [void][Windows.MessageBox]::Show('内容不能为空', '滚滚日程'); return }
  if ($todo) {
    $f = @{ title = $title; due = $tDue.Text.Trim(); priority = [string]$cPri.SelectedItem; note = $tNote.Text.Trim() }
  } else {
    $f = @{ title = $title }
    $s1 = $tS.Text.Trim(); $e1 = $tE.Text.Trim()
    $re = '^([01]?\d|2[0-3]):[0-5]\d$'
    if ($s1 -or $e1) {
      if (-not ($s1 -match $re -and $e1 -match $re)) { [void][Windows.MessageBox]::Show('时间格式应为 HH:MM，开始和结束需同时填写', '滚滚日程'); return }
      $s1 = $s1.PadLeft(5, '0'); $e1 = $e1.PadLeft(5, '0')
      if ($e1 -le $s1) { [void][Windows.MessageBox]::Show('结束时间需晚于开始', '滚滚日程'); return }
      $f.start = $s1; $f['end'] = $e1
    }
  }
  RD-Push (RD-NewEdit $info 'edit' $f)
}
# ---------------------------------------------------------------------------

function Show-Win {
  $w.Show()
  $w.WindowState = 'Normal'
  $w.Activate()
  $w.Topmost = $true
  if ($script:ni) {
    $script:ni.Text = '滚滚日程'
    $script:ni.Visible = $true
  }
}

function Hide-Win {
  $w.Hide()
  if ($script:ni) {
    $script:ni.Text = '滚滚日程'
    $script:ni.Visible = $true
    if (-not $script:hidTipShown) {
      $script:hidTipShown = $true
      try {
        $script:ni.BalloonTipTitle = '滚滚日程'
        $script:ni.BalloonTipText = '已隐藏，点这里可重新打开'
        $script:ni.ShowBalloonTip(4000)
      } catch {}
    }
  }
}

function Exit-App {
  $script:reallyExit = $true
  try {
    if ($script:ni) {
      $script:ni.Visible = $false
      $script:ni.Dispose()
      $script:ni = $null
    }
  } catch {}
  try { $w.Close() } catch {}
  try { if ($script:owner) { $script:owner.Close() } } catch {}
  try { [Windows.Forms.Application]::Exit() } catch {}
}

$w.Add_MouseLeftButtonDown({ $w.DragMove() })
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
$w.Add_Closing({
  param($o, $e)
  if (-not $script:reallyExit) {
    $e.Cancel = $true
    Hide-Win
  }
})

$wcm = New-Object Windows.Controls.ContextMenu
$miWH = New-Object Windows.Controls.MenuItem -Property @{ Header = '隐藏' }
$miWH.Add_Click({ Hide-Win })
[void]$wcm.Items.Add($miWH)
$miWX = New-Object Windows.Controls.MenuItem -Property @{ Header = '退出' }
$miWX.Add_Click({ Exit-App })
[void]$wcm.Items.Add($miWX)
$w.ContextMenu = $wcm

# Ensure schedule.ico exists (generate a simple teal calendar if missing).
if (-not (Test-Path $IcoPath)) {
  $bmp = New-Object Drawing.Bitmap 32, 32
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'
  $g.Clear([Drawing.Color]::FromArgb(0, 0, 0, 0))
  $g.FillEllipse((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 32, 180, 140))), 1, 1, 30, 30)
  $g.FillRectangle((New-Object Drawing.SolidBrush ([Drawing.Color]::White)), 9, 8, 14, 17)
  $g.FillRectangle((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 220, 60, 60))), 9, 8, 14, 4)
  $g.Dispose()
  $ic = [Drawing.Icon]::FromHandle($bmp.GetHicon())
  $fs = [IO.File]::Create($IcoPath)
  $ic.Save($fs)
  $fs.Close()
  $bmp.Dispose()
}

$script:ico = New-Object Drawing.Icon $IcoPath, 16, 16
$script:ni = New-Object Windows.Forms.NotifyIcon
$script:ni.Icon = $script:ico
$script:ni.Text = '滚滚日程'
$script:ni.BalloonTipTitle = '滚滚日程'
$script:ni.BalloonTipIcon = [Windows.Forms.ToolTipIcon]::Info
$script:ni.Visible = $true

$tcm = New-Object Windows.Forms.ContextMenuStrip
$miShow = $tcm.Items.Add('显示/打开')
$miHide = $tcm.Items.Add('隐藏')
[void]$tcm.Items.Add('-')
$miExit = $tcm.Items.Add('退出')
$script:ni.ContextMenuStrip = $tcm
$miShow.Add_Click({ Show-Win })
$miHide.Add_Click({ Hide-Win })
$miExit.Add_Click({ Exit-App })
$script:ni.Add_MouseDoubleClick({ Show-Win })
$script:ni.Add_BalloonTipClicked({ Show-Win })

# 1px WinForms owner form keeps NotifyIcon alive across WPF Hide.
$script:owner = New-Object Windows.Forms.Form
$script:owner.Text = 'RollingDayTray'
$script:owner.ShowInTaskbar = $false
$script:owner.FormBorderStyle = 'FixedToolWindow'
$script:owner.Opacity = 0
$script:owner.ShowIcon = $false
$script:owner.Size = New-Object Drawing.Size 1, 1
$script:owner.StartPosition = 'Manual'
$script:owner.Location = New-Object Drawing.Point -4000, -4000
$script:owner.Add_FormClosing({
  param($o, $e)
  if (-not $script:reallyExit) { $e.Cancel = $true }
})

$w.Show()
[Windows.Forms.Application]::Run($script:owner)

try {
  if ($script:ni) {
    $script:ni.Visible = $false
    $script:ni.Dispose()
  }
} catch {}
