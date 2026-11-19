param([string]$Assets, [scriptblock]$OnReady, [string]$CurrentVideo = '', [string]$StartView = 'detail', [switch]$SignInOnStart,
    [string]$PlayMailbox = '', [int]$MpvProcessId = 0)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
try {
    Add-Type -Namespace NewBV -Name TaskbarIdentity -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, ExactSpelling = true)]
public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
[System.Runtime.InteropServices.DllImport("shell32.dll", ExactSpelling = true)]
public static extern int GetCurrentProcessExplicitAppUserModelID(out System.IntPtr appId);
'@
    [void][NewBV.TaskbarIdentity]::SetCurrentProcessExplicitAppUserModelID('NativeWasmTv.NewBV.BBLLBrowser')
} catch { Write-Verbose "BBLL taskbar identity unavailable: $($_.Exception.Message)" }
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$helper = Join-Path $PSScriptRoot 'resolve.ps1'
if (-not $Assets) { $Assets = Join-Path $PSScriptRoot 'bbll-assets' }
$xml = [xml][IO.File]::ReadAllText((Join-Path $PSScriptRoot 'browser.xaml'))
$window = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xml))
foreach ($name in @('Backdrop','Sidebar','AccountButton','SettingsButton','HeaderTabs','ClockText',
        'Viewport','Body','MoreButton','StatusText','StatusLayer','Header','MainView','SettingsView',
        'EmptyState','EmptyMessage','EmptyAction','EmptyActionText',
        'SettingsHeader','SettingsBack','SettingsCategories','SettingsRows','SettingsScroll','HeaderScroll',
        'DialogOverlay','DialogCard','DialogTitle','DialogScroll','DialogOptions',
        'MinimizeButton','FullscreenButton','CloseWindowButton')) {
    Set-Variable -Name $name -Value ($window.FindName($name))
}
$vectorPath = Join-Path $PSScriptRoot 'bbll-icons.json'
$vectors = if ([IO.File]::Exists($vectorPath)) { [IO.File]::ReadAllText($vectorPath) | ConvertFrom-Json }
$fallbackIcons = @{
    icon_search = 0xE721; icon_home = 0xE80F; tab_recommend = 0xE80A; tab_dynamic = 0xE8A7
    tab_live = 0xE714; tab_me = 0xE77B; icon_user = 0xE77B; default_avatar = 0xE77B
    icon_setting = 0xE713; icon_back = 0xE72B; icon_about = 0xE946; ic_tv = 0xE7F4
    icon_video_play_count = 0xE768; icon_video_danmaku = 0xE8BD; icon_video_up = 0xE77B; ic_hot = 0xE9D2
}
$regions = @(
    @{id = 'popular'; title = '全站'}, @{id = 'region:1005'; title = '动画'}, @{id = 'region:1003'; title = '音乐'},
    @{id = 'region:1004'; title = '舞蹈'}, @{id = 'region:1008'; title = '游戏'}, @{id = 'region:1010'; title = '知识'},
    @{id = 'region:1001'; title = '影视'}, @{id = 'region:1002'; title = '娱乐'}
)
$homePages = @(
    @{id = 'home'; title = '推荐'}, @{id = 'popular'; title = '热门'},
    @{id = 'season:1'; title = '番剧'}, @{id = 'season:2'; title = '影视'}
)
$library = @(
    @{id = 'history'; title = '历史'}, @{id = 'folders'; title = '收藏'},
    @{id = 'following-seasons'; title = '追番'}, @{id = 'following-series'; title = '追剧'},
    @{id = 'later'; title = '稍后观看'}, @{id = 'following'; title = '关注'}
)
$sections = @(
    @{id = 'search'; title = '搜索'; icon = 'icon_search'},
    @{id = 'home'; title = '首页'; icon = 'icon_home'},
    @{id = 'region'; title = '分区'; icon = 'tab_recommend'},
    @{id = 'dynamic'; title = '动态'; icon = 'tab_dynamic'},
    @{id = 'live'; title = '直播'; icon = 'tab_live'},
    @{id = 'mine'; title = '我的'; icon = 'tab_me'}
)
$script:page = $null
$stack = [Collections.Generic.Stack[hashtable]]::new()
$pageCache = @{}
$requests = @{page = $null; account = $null}
$script:grid = $null
$script:output = $null
$script:mailboxSequence = 0
$script:selected = 0
$script:searchBox = $null
$script:lastSearch = ''
$script:sort = 'totalrank'
$script:searchType = 'video'
$script:keyboard = $null
$script:alternateKeyboard = $false
$script:hotPanel = $null
$script:keywords = @()
$script:tapKey = ''
$script:tapIndex = 0
$script:tapTime = [DateTime]::MinValue
$searchFile = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'mpv-newbv\search-history.json'
$script:recentSearch = @()
try {
    if ([IO.File]::Exists($searchFile) -and [IO.FileInfo]::new($searchFile).Length -lt 16384) {
        $script:recentSearch = @(([IO.File]::ReadAllText($searchFile) | ConvertFrom-Json) |
            Where-Object { $_ -is [string] -and $_.Length -le 100 } | Select-Object -First 10)
    }
} catch {}
$cards = [Collections.Generic.List[Windows.Controls.Button]]::new()
$cancelled = [Collections.Generic.List[hashtable]]::new()
$tabs = @{}
$normal = [Windows.Media.Brushes]::White
$secondary = [Windows.Media.BrushConverter]::new().ConvertFromString('#CCCCCC')
$purple = [Windows.Media.BrushConverter]::new().ConvertFromString('#424242')
$railSelection = [Windows.Media.BrushConverter]::new().ConvertFromString('#626262')
$activeTab = [Windows.Media.BrushConverter]::new().ConvertFromString('#715C90')
$accent = [Windows.Media.BrushConverter]::new().ConvertFromString('#BB86FC')
$commentAccent = [Windows.Media.BrushConverter]::new().ConvertFromString('#65CFF5')
$commentMuted = [Windows.Media.BrushConverter]::new().ConvertFromString('#ABABAB')
$divider = [Windows.Media.BrushConverter]::new().ConvertFromString('#474747')
$timer = [Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(80)
. (Join-Path $PSScriptRoot 'dialog.ps1')
. (Join-Path $PSScriptRoot 'settings.ps1')
. (Join-Path $PSScriptRoot 'account.ps1')
. (Join-Path $PSScriptRoot 'profile.ps1')
. (Join-Path $PSScriptRoot 'signin.ps1')

$iconPath = Join-Path $PSScriptRoot 'bbll-launcher.png.base64'
if ([IO.File]::Exists($iconPath)) {
    $imageBytes = [Convert]::FromBase64String([IO.File]::ReadAllText($iconPath))
    $iconStream = [IO.MemoryStream]::new($imageBytes)
    try {
        $bitmap = [Windows.Media.Imaging.BitmapImage]::new()
        $bitmap.BeginInit()
        $bitmap.CacheOption = 'OnLoad'
        $bitmap.StreamSource = $iconStream
        $bitmap.EndInit()
        $window.Icon = $bitmap
    } finally { $iconStream.Dispose() }
}

function Get-Asset([string]$Name) {
    $path = Join-Path $Assets $Name
    if (Test-Path -LiteralPath $path -PathType Leaf) { return [Uri](Resolve-Path -LiteralPath $path).Path }
}

function New-Image([Uri]$Source, [string]$Stretch, [int]$Pixels = 0) {
    $image = [Windows.Controls.Image]::new()
    $image.Stretch = $Stretch
    if ($Source) {
        $bitmap = [Windows.Media.Imaging.BitmapImage]::new()
        $bitmap.BeginInit()
        if ($Pixels) { $bitmap.DecodePixelWidth = $Pixels }
        $bitmap.UriSource = $Source
        $bitmap.EndInit()
        $image.Source = $bitmap
    }
    $image
}

function New-Text([string]$Text, [int]$Size, $Color, [bool]$Bold = $false) {
    $block = [Windows.Controls.TextBlock]::new()
    $block.Text = $Text
    $block.FontSize = $Size
    $block.Foreground = $Color
    $block.TextTrimming = 'CharacterEllipsis'
    if ($Bold) { $block.FontWeight = 'Bold' }
    $block
}

function New-Icon([string]$Name, [int]$Size) {
    $definition = if ($vectors) { $vectors.PSObject.Properties[$Name] }
    if ($definition) {
        $definition = $definition.Value
        $canvas = [Windows.Controls.Canvas]::new()
        $canvas.Width = $definition.width
        $canvas.Height = $definition.height
        foreach ($shape in $definition.paths) {
            $path = [Windows.Shapes.Path]::new()
            $rule = if ($shape.evenOdd) { 'F0 ' } else { 'F1 ' }
            $path.Data = [Windows.Media.Geometry]::Parse($rule + $shape.d)
            $path.Fill = $normal
            if ($shape.stroke) {
                $path.Stroke = $normal
                $path.StrokeThickness = $shape.stroke
                $path.StrokeStartLineCap = 'Round'
                $path.StrokeEndLineCap = 'Round'
                $path.StrokeLineJoin = 'Round'
            }
            [void]$canvas.Children.Add($path)
        }
        $view = [Windows.Controls.Viewbox]::new()
        $view.Child = $canvas
    } else {
        $asset = Get-Asset ($Name + '.png')
        if ($asset) {
            $view = New-Image $asset 'Uniform'
        } elseif ($fallbackIcons.ContainsKey($Name)) {
            $glyph = [Windows.Controls.TextBlock]::new()
            $glyph.Text = [string][char]$fallbackIcons[$Name]
            $glyph.FontFamily = [Windows.Media.FontFamily]::new('Segoe MDL2 Assets')
            $glyph.Foreground = if ($Name -eq 'default_avatar') { [Windows.Media.Brushes]::DimGray } else { $normal }
            $view = [Windows.Controls.Viewbox]::new()
            $view.Child = $glyph
        } else { return }
    }
    $view.Width = $Size
    $view.Height = $Size
    $view
}

function Set-ButtonIcon($Button, [string]$Icon, [string]$Label) {
    $Button.ToolTip = $Label
    [Windows.Automation.AutomationProperties]::SetName($Button, $Label)
    $size = switch ($Icon) { 'icon_search' {23} 'icon_home' {33} 'icon_setting' {28} default {30} }
    $image = New-Icon $Icon $size
    if ($image) { $Button.Content = $image } else { $Button.Content = $Label; $Button.FontSize = 12 }
}

function Cancel-Request([string]$Channel = 'page') {
    $old = $requests[$Channel]
    if (-not $old) { return }
    $requests[$Channel] = $null
    $old.stop = $old.worker.BeginStop($null, $null)
    $cancelled.Add($old)
}

function Invoke-Request([string]$Action, [string]$Value, [int]$Number, [scriptblock]$Done, $Context = $null,
    [string]$Channel = 'page') {
    Cancel-Request $Channel
    $worker = [PowerShell]::Create()
    [void]$worker.AddScript(@'
param($helper, $action, $value, $number, $cursor, $order, $searchType)
& $helper -Action $action -Query ('q:' + $value) -Page $number -Cursor $cursor -Order $order -SearchType $searchType
'@).AddArgument($helper).AddArgument($Action).AddArgument($Value).AddArgument($Number).AddArgument(
        [string]$Context.cursor).AddArgument($script:sort).AddArgument($script:searchType)
    $requests[$Channel] = @{action = $Action; worker = $worker; task = $worker.BeginInvoke(); done = $Done; context = $Context}
    $timer.Start()
}

$timer.add_Tick({
    for ($index = $cancelled.Count - 1; $index -ge 0; $index--) {
        $old = $cancelled[$index]
        if ($old.stop.IsCompleted) {
            $old.worker.EndStop($old.stop)
            $old.worker.Dispose()
            $cancelled.RemoveAt($index)
        }
    }
    foreach ($channel in @('page','account')) {
        $pending = $requests[$channel]
        if (-not $pending -or -not $pending.task.IsCompleted) { continue }
        $requests[$channel] = $null
        try { $data = ($pending.worker.EndInvoke($pending.task) -join '') | ConvertFrom-Json }
        catch { $data = $null }
        finally { $pending.worker.Dispose() }
        & $pending.done $data $pending.context
    }
    if (-not $requests.page -and -not $requests.account -and -not $cancelled.Count) { $timer.Stop() }
})

function Finish([string]$Action, [string]$Url = '', $Parts = @()) {
    $queue = @($Parts | ForEach-Object {
        $caption = if ($_.page) { [string]$_.page + '  ' + $_.title } else { [string]$_.title }
        @{url = $_.url; title = $caption}
    })
    $message = @{action = $Action; url = $Url; queue = $queue}
    if ($Action -notin @('play','signin','cancel-signin','check-signin') -or -not $PlayMailbox) {
        $script:output = $message
        $window.Close()
        return
    }
    $message.sequence = ++$script:mailboxSequence
    $temporary = $PlayMailbox + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $message -Compress -Depth 4), [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($PlayMailbox)) { [IO.File]::Replace($temporary, $PlayMailbox, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $PlayMailbox) }
    } catch {
        Show-Status '未能与 mpv 通信，请重试。'
        return
    }
    if ($Action -eq 'signin') { return $message.sequence }
    if ($Action -ne 'play') { return }
    Show-Status '已发送到 mpv。可继续选择视频。'
    if ($MpvProcessId -gt 0) {
        try { [void](New-Object -ComObject WScript.Shell).AppActivate($MpvProcessId) } catch {}
    }
}

function Show-Status([string]$Message = '') {
    $EmptyState.Visibility = 'Collapsed'
    $StatusText.Text = $Message
    $StatusLayer.Visibility = if ($Message) { 'Visible' } else { 'Collapsed' }
}

function Show-EmptyState([string]$Message, [string]$Action = 'retry') {
    Show-Status
    $EmptyMessage.Text = $Message
    $EmptyAction.Tag = $Action
    $EmptyActionText.Text = if ($Action -eq 'signin') { '扫码登录' } else { '重试' }
    [Windows.Automation.AutomationProperties]::SetName($EmptyAction, $EmptyActionText.Text)
    $EmptyState.Visibility = 'Visible'
}

function Select-HeaderTab {
    $active = $HeaderTabs.Children | Where-Object { $_ -is [Windows.Controls.Button] -and $_.Tag.choice.id -eq $script:page.id } | Select-Object -First 1
    if ($active) { [void]$active.Focus() }
}

function Set-Header {
    $HeaderTabs.Children.Clear()
    $key = $script:page.rail
    $searching = $script:page.id -eq 'search'
    $ClockText.Visibility = if ($searching) { 'Collapsed' } else { 'Visible' }
    $HeaderTabs.Margin = if ($searching) { [Windows.Thickness]::new(0,20,0,0) }
        elseif ($key -eq 'mine' -and -not $script:page.standalone) { [Windows.Thickness]::new(0,24,0,0) }
        else { [Windows.Thickness]::new(20,16,0,0) }
    $HeaderTabs.Orientation = if ($searching) { 'Vertical' } else { 'Horizontal' }
    $HeaderScroll.HorizontalScrollBarVisibility = if ($searching) { 'Disabled' } else { 'Hidden' }
    $HeaderScroll.ScrollToHorizontalOffset(0)
    $Header.Parent.RowDefinitions[0].Height = [Windows.GridLength]::new($(if ($searching) { 53 }
        elseif ($key -eq 'mine' -and -not $script:page.standalone) { 77 } else { 69 }))
    $choices = switch ($key) { 'home' { $homePages }; 'region' { $regions }; 'mine' { $library }; default {} }
    if (-not $searching -and ($script:page.standalone -or -not $choices)) {
        $label = New-Text $script:page.title 27 $normal
        $label.VerticalAlignment = 'Center'
        [void]$HeaderTabs.Children.Add($label)
    } elseif (-not $searching) {
        foreach ($item in $choices) {
            $button = [Windows.Controls.Button]::new()
            $button.Style = $window.FindResource('HeaderTab')
            if ($key -eq 'home') { $button.MinWidth = 108 }
            $caption = [Windows.Controls.Grid]::new()
            $text = [Windows.Controls.TextBlock]::new()
            $text.Text = $item.title
            $text.HorizontalAlignment = 'Center'
            $text.VerticalAlignment = 'Center'
            [void]$caption.Children.Add($text)
            if ($script:page.id -eq $item.id) {
                $button.Background = $activeTab
                $button.Foreground = $normal
                $line = [Windows.Controls.Border]::new()
                $line.Width = 38
                $line.Height = 4
                $line.Background = $accent
                $line.CornerRadius = [Windows.CornerRadius]::new(2)
                $line.Margin = [Windows.Thickness]::new(0,0,0,2)
                $line.HorizontalAlignment = 'Center'
                $line.VerticalAlignment = 'Bottom'
                [void]$caption.Children.Add($line)
            }
            $button.Content = $caption
            [Windows.Automation.AutomationProperties]::SetName($button, $item.title)
            $button.Tag = @{choice = $item; rail = $key}
            $button.add_GotKeyboardFocus({ param($sender, $event) $sender.BringIntoView() })
            $button.add_Click({ param($sender, $event) Open-Section $sender.Tag.choice $sender.Tag.rail })
            [void]$HeaderTabs.Children.Add($button)
        }
    }
    foreach ($tab in $tabs.Values) {
        $tab.Background = if ($tab.Tag.id -eq $key) { $railSelection } else { [Windows.Media.Brushes]::Transparent }
        if ($tab.Content -is [Windows.UIElement]) { $tab.Content.Opacity = if ($tab.Tag.id -eq $key) { 1 } else { 0.58 } }
    }
}

function Get-DurationLabel([string]$Value) {
    if ($Value -eq 'LIVE') { return '直播中' }
    if ($Value -match '^[0-9]+:[0-9]{2}(?::[0-9]{2})?$') { return $Value }
    $seconds = 0
    if ([int]::TryParse($Value, [ref]$seconds) -and $seconds -gt 0) {
        $time = [TimeSpan]::FromSeconds($seconds)
        if ($time.TotalHours -ge 1) { return $time.ToString('hh\:mm\:ss') }
        return $time.ToString('mm\:ss')
    }
    ''
}

function Add-CoverCount($Panel, [string]$Icon, $Value) {
    $count = 0L
    if (-not [long]::TryParse([string]$Value, [ref]$count) -or $count -lt 1) { return }
    $text = if ($count -ge 10000) { '{0:0.#}万' -f ($count / 10000) } else { "$count" }
    $picture = New-Icon $Icon 20
    if ($picture) { [void]$Panel.Children.Add($picture) }
    $label = New-Text $text 15 $normal
    $label.Margin = [Windows.Thickness]::new(4,0,10,0)
    [void]$Panel.Children.Add($label)
}

function New-Cover($Item) {
    $frame = [Windows.Controls.Border]::new()
    $frame.Background = [Windows.Media.Brushes]::Black
    $frame.ClipToBounds = $true
    $frame.CornerRadius = [Windows.CornerRadius]::new(9)
    $frame.add_SizeChanged({
        param($sender, $event)
        $sender.Clip = [Windows.Media.RectangleGeometry]::new([Windows.Rect]::new($event.NewSize), 9, 9)
    })
    $layers = [Windows.Controls.Grid]::new()
    $fallback = Get-Asset 'default_video.png'
    if ($fallback) { [void]$layers.Children.Add((New-Image $fallback 'UniformToFill')) }
    if ($Item.cover) {
        $pixels = if ($settings.picture -in @(320,480,640)) { [int]$settings.picture } else { 480 }
        $height = [int]($pixels * 9 / 16)
        $uri = if ($Item.cover -like '*?*') { [Uri]$Item.cover } else { [Uri]($Item.cover + "@$($pixels)w_$($height)h_1c.jpg") }
        [void]$layers.Children.Add((New-Image $uri 'UniformToFill' $pixels))
    }
    $footer = [Windows.Controls.DockPanel]::new()
    $footer.VerticalAlignment = 'Bottom'
    $footer.Background = [Windows.Media.LinearGradientBrush]::new(
        [Windows.Media.Colors]::Transparent, [Windows.Media.Color]::FromArgb(205,0,0,0), 90)
    $footer.Height = 32
    $label = New-Text (Get-DurationLabel $Item.duration) 15 $normal
    $label.Margin = [Windows.Thickness]::new(7,0,12,5)
    $label.VerticalAlignment = 'Bottom'
    [Windows.Controls.DockPanel]::SetDock($label, 'Right')
    [void]$footer.Children.Add($label)
    $label.HorizontalAlignment = 'Right'
    $counts = [Windows.Controls.StackPanel]::new()
    $counts.Orientation = 'Horizontal'
    $counts.VerticalAlignment = 'Bottom'
    $counts.Margin = [Windows.Thickness]::new(6,0,0,5)
    Add-CoverCount $counts 'icon_video_play_count' $Item.views
    Add-CoverCount $counts 'icon_video_danmaku' $Item.danmaku
    [void]$footer.Children.Add($counts)
    [void]$layers.Children.Add($footer)
    $duration = 0
    if ($Item.progress -gt 0 -and [int]::TryParse([string]$Item.duration, [ref]$duration) -and $duration -gt 0) {
        $progress = [Windows.Controls.ProgressBar]::new()
        $progress.Height = 3
        $progress.VerticalAlignment = 'Bottom'
        $progress.Maximum = $duration
        $progress.Value = [Math]::Min($duration, $Item.progress)
        $progress.Foreground = $accent
        [void]$layers.Children.Add($progress)
    }
    $frame.Child = $layers
    $frame
}

function Add-Card($Item) {
    $index = $cards.Count
    $button = [Windows.Controls.Button]::new()
    $button.Tag = @{item = $Item; index = $index}
    $button.Padding = [Windows.Thickness]::new(8,11,8,10)
    $button.HorizontalContentAlignment = 'Stretch'
    $button.VerticalContentAlignment = 'Top'
    $button.ToolTip = $Item.title
    $content = [Windows.Controls.StackPanel]::new()
    $frame = New-Cover $Item
    $frame.Height = [Math]::Max(55, ($Viewport.ActualWidth / 4 - 20) * 9 / 16)
    $frame.add_SizeChanged({ param($sender, $event) if ($event.WidthChanged -and $event.NewSize.Width -gt 0) {
        $sender.Height = $event.NewSize.Width * 9 / 16
    } })
    [void]$content.Children.Add($frame)
    $title = New-Text $Item.title 21 $normal $true
    $title.TextWrapping = 'Wrap'
    $title.LineHeight = 31
    $title.LineStackingStrategy = 'BlockLineHeight'
    $title.Height = 62
    $title.Margin = [Windows.Thickness]::new(0,7,0,2)
    [void]$content.Children.Add($title)
    $ownerLine = [Windows.Controls.DockPanel]::new()
    $ownerIcon = New-Icon 'icon_video_up' 22
    if ($ownerIcon) { $ownerIcon.Margin = [Windows.Thickness]::new(0,0,6,0); [void]$ownerLine.Children.Add($ownerIcon) }
    $byline = [string]$Item.author
    if ($Item.published -gt 0) {
        $ago = [DateTimeOffset]::Now - [DateTimeOffset]::FromUnixTimeSeconds([long]$Item.published)
        if ($ago.TotalHours -ge 1 -and $ago.TotalDays -lt 2) { $byline += " · $([Math]::Floor($ago.TotalHours))小时前" }
        elseif ($ago.TotalDays -ge 2) { $byline += ' · ' + [DateTimeOffset]::FromUnixTimeSeconds([long]$Item.published).ToLocalTime().ToString('MM-dd') }
    }
    [void]$ownerLine.Children.Add((New-Text $byline 15 $secondary))
    [void]$content.Children.Add($ownerLine)
    $button.Content = $content
    $button.add_GotKeyboardFocus({ param($sender, $event) $script:selected = $sender.Tag.index; $sender.BringIntoView() })
    $button.add_Click({ param($sender, $event) Open-Item $sender.Tag.item $sender.Tag.index })
    [void]$cards.Add($button)
    [void]$script:grid.Children.Add($button)
}

function Select-Card([int]$Index) {
    if ($Index -ge 0 -and $Index -lt $cards.Count) { [void]$cards[$Index].Focus() }
}

function Update-More {
    $MoreButton.Visibility = if ($script:page.more -and $script:page.number -lt 100 -and $StatusLayer.Visibility -eq 'Visible') { 'Visible' } else { 'Collapsed' }
}

function Render-Page([int]$FocusIndex = -1) {
    $script:searchBox = $null
    $script:keyboard = $null
    $script:hotPanel = $null
    $Body.Children.Clear()
    $cards.Clear()
    Set-Header
    if ($script:page.id -eq 'search') {
        $box = [Windows.Controls.TextBox]::new()
        $box.Height = 37
        $box.FontSize = 23
        $box.Padding = [Windows.Thickness]::new(9,5,9,5)
        $box.Margin = [Windows.Thickness]::new(0)
        $box.Background = [Windows.Media.Brushes]::Transparent
        $box.Foreground = $normal
        $box.BorderThickness = [Windows.Thickness]::new(0)
        $box.Text = $script:lastSearch
        $box.MaxLength = 400
        $box.ToolTip = '输入关键词、BV / av 号或 B 站视频链接'
        $box.add_PreviewKeyDown({ param($sender, $event)
            if ($event.Key -eq 'Return') { $event.Handled = $true; Submit-Search $sender.Text }
            if ($event.Key -eq 'Down' -and $cards.Count) { $event.Handled = $true; Select-Card 0 }
        })
        $hint = New-Text '搜索' 27 $normal $true
        $hint.VerticalAlignment = 'Center'
        $hint.Margin = [Windows.Thickness]::new(27,0,0,0)
        $hint.IsHitTestVisible = $false
        $hint.Visibility = if ($box.Text) { 'Collapsed' } else { 'Visible' }
        $box.add_TextChanged({
            param($sender, $event)
            $sender.Tag.Visibility = if ($sender.Text) { 'Collapsed' } else { 'Visible' }
        })
        $box.Tag = $hint
        $searchFrame = [Windows.Controls.Grid]::new()
        [void]$searchFrame.Children.Add($box)
        [void]$searchFrame.Children.Add($hint)
        [void]$HeaderTabs.Children.Add($searchFrame)
        $script:searchBox = $box
        Add-SearchPanel
    }
    New-ResultGrid
    foreach ($item in $script:page.items) { Add-Result $item }
    if ($cards.Count) { Show-Status }
    elseif ($script:page.loaded) { Show-EmptyState '这里还没有内容。' }
    else { Show-Status }
    Update-More
    $Viewport.ScrollToHome()
    if ($FocusIndex -ge 0 -and $cards.Count) { Select-Card $FocusIndex }
    elseif ($script:searchBox) { [void]$script:searchBox.Focus(); $script:searchBox.SelectAll() }
}

function Add-SearchPanel {
    $panel = [Windows.Controls.DockPanel]::new()
    $panel.Margin = [Windows.Thickness]::new(13,0,15,0)
    $panel.Visibility = if ($script:page.loaded) { 'Collapsed' } else { 'Visible' }
    $script:keyboard = $panel
    $board = [Windows.Controls.StackPanel]::new()
    $board.Width = 416
    $board.Margin = [Windows.Thickness]::new(0,15,0,0)
    [void]$panel.Children.Add($board)
    $reset = [Windows.Controls.Primitives.UniformGrid]::new()
    $reset.Columns = 2
    [void]$board.Children.Add($reset)
    foreach ($caption in @('清空', '后退')) {
        $key = New-PageButton (New-Text $caption 23 $secondary $true)
        $key.Height = 68
        $key.Tag = $caption
        $key.add_Click({
            param($sender, $event)
            $script:tapKey = ''
            $value = $script:searchBox.Text
            if ($sender.Tag -eq '清空') { $script:searchBox.Text = '' }
            elseif ($value) {
                $offsets = [Globalization.StringInfo]::ParseCombiningCharacters($value)
                $script:searchBox.Text = $value.Substring(0, $offsets[-1])
            }
        })
        [void]$reset.Children.Add($key)
    }
    $keys = [Windows.Controls.Primitives.UniformGrid]::new()
    $keys.Columns = if ($script:alternateKeyboard) { 6 } else { 3 }
    $keys.Margin = [Windows.Thickness]::new(0,4,0,0)
    [void]$board.Children.Add($keys)
    $symbols = if ($script:alternateKeyboard) { @('ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'.ToCharArray()) } else {
        @('01 ', '2ABC', '3DEF', '4GHI', '5JKL', '6MNO', '7PQRS', '8TUV', '9WXYZ')
    }
    foreach ($symbol in $symbols) {
        $keyText = [string]$symbol
        $label = if ($script:alternateKeyboard) { $keyText } elseif ($keyText -eq '01 ') {
            [Environment]::NewLine + '0/1'
        } else {
            $keyText.Substring(0, 1) + [Environment]::NewLine + $keyText.Substring(1)
        }
        $labelBlock = New-Text $label 24 $secondary $true
        $labelBlock.TextAlignment = 'Center'
        $key = New-PageButton $labelBlock
        $key.Tag = $keyText
        $key.Height = if ($script:alternateKeyboard) { 52 } else { 123 }
        $key.Margin = [Windows.Thickness]::new(6,5,6,4)
        $key.add_Click({
            param($sender, $event)
            $group = $sender.Tag
            $value = $script:searchBox.Text
            $now = [DateTime]::Now
            if (-not $script:alternateKeyboard -and $group -ceq $script:tapKey -and $value.Length -gt 0 -and
                ($now - $script:tapTime).TotalMilliseconds -lt 850) {
                $script:tapIndex = ($script:tapIndex + 1) % $group.Length
                $value = $value.Substring(0, $value.Length - 1)
            } else { $script:tapIndex = 0 }
            if ($value.Length -lt 100) { $script:searchBox.Text = $value + $group[$script:tapIndex] }
            $script:tapKey = $group
            $script:tapTime = $now
        })
        [void]$keys.Children.Add($key)
    }
    $actions = [Windows.Controls.Primitives.UniformGrid]::new()
    $actions.Columns = 3
    [void]$board.Children.Add($actions)
    foreach ($caption in @('T9键盘', '全键盘', '搜索')) {
        $selectedMode = ($script:alternateKeyboard -and $caption -eq '全键盘') -or (-not $script:alternateKeyboard -and $caption -eq 'T9键盘')
        $color = if ($selectedMode) { $accent } else { $secondary }
        $button = New-PageButton (New-Text $caption 23 $color $true)
        $button.Height = 68
        $button.Tag = $caption
        $button.add_Click({
            param($sender, $event)
            if ($sender.Tag -eq '搜索') { Submit-Search $script:searchBox.Text; return }
            $query = $script:searchBox.Text
            $script:alternateKeyboard = $sender.Tag -eq '全键盘'
            $script:tapKey = ''
            Render-Page
            $script:searchBox.Text = $query
            $script:keyboard.Visibility = 'Visible'
            [void]$script:keyboard.Children[0].Children[1].Children[0].Focus()
        })
        [void]$actions.Children.Add($button)
    }
    $script:hotPanel = [Windows.Controls.StackPanel]::new()
    $script:hotPanel.Margin = [Windows.Thickness]::new(17,0,0,0)
    [void]$panel.Children.Add($script:hotPanel)
    [void]$Body.Children.Add($panel)
    Render-HotSearch
    $filters = [Windows.Controls.StackPanel]::new()
    if (-not $script:page.loaded) { $filters.Visibility = 'Collapsed' }
    $typeRow = [Windows.Controls.StackPanel]::new()
    $typeRow.Orientation = 'Horizontal'
    foreach ($choice in @(@('视频','video'), @('番剧','media_bangumi'), @('影视','media_ft'), @('直播','live_room'), @('UP 主','bili_user'))) {
        $button = New-PageButton $choice[0]
        $button.Tag = $choice[1]
        if ($script:searchType -eq $choice[1]) { $button.BorderBrush = $accent }
        $button.add_Click({ param($sender, $event) $script:searchType = $sender.Tag; Submit-Search $script:lastSearch })
        [void]$typeRow.Children.Add($button)
    }
    [void]$filters.Children.Add($typeRow)
    $sortRow = [Windows.Controls.StackPanel]::new()
    $sortRow.Orientation = 'Horizontal'
    if ($script:searchType -ne 'video') { $sortRow.Visibility = 'Collapsed' }
    foreach ($choice in @(@('综合排序','totalrank'), @('最多播放','click'), @('最新发布','pubdate'), @('最多弹幕','dm'), @('最多收藏','stow'))) {
        $button = New-PageButton $choice[0]
        $button.Tag = $choice[1]
        if ($script:sort -eq $choice[1]) { $button.BorderBrush = $accent }
        $button.add_Click({ param($sender, $event) $script:sort = $sender.Tag; Submit-Search $script:lastSearch })
        [void]$sortRow.Children.Add($button)
    }
    [void]$filters.Children.Add($sortRow)
    [void]$Body.Children.Add($filters)
}

function Render-HotSearch {
    if (-not $script:hotPanel) { return }
    $script:hotPanel.Children.Clear()
    if ($script:recentSearch.Count) {
        [void]$script:hotPanel.Children.Add((New-Text '最近搜索' 18 $secondary $true))
        $recent = [Windows.Controls.WrapPanel]::new()
        foreach ($value in $script:recentSearch) {
            $button = New-PageButton (New-Text $value 17 $normal)
            $button.MaxWidth = 220
            $button.Tag = $value
            $button.add_Click({ param($sender, $event) Submit-Search $sender.Tag })
            [void]$recent.Children.Add($button)
        }
        $clear = New-PageButton '清空历史'
        $clear.add_Click({
            $script:recentSearch = @()
            try { [IO.File]::Delete($searchFile) } catch {}
            Render-HotSearch
        })
        [void]$recent.Children.Add($clear)
        [void]$script:hotPanel.Children.Add($recent)
    }
    foreach ($word in $script:keywords) {
        $caption = [Windows.Controls.StackPanel]::new()
        $caption.Orientation = 'Horizontal'
        $flame = New-Icon 'ic_hot' 23
        if ($flame) { $flame.Margin = [Windows.Thickness]::new(3,0,9,0); [void]$caption.Children.Add($flame) }
        [void]$caption.Children.Add((New-Text $word.title 23 $normal))
        $button = New-PageButton $caption
        $button.Style = $window.FindResource('HotSearch')
        $button.HorizontalAlignment = 'Left'
        $button.HorizontalContentAlignment = 'Left'
        $button.Margin = [Windows.Thickness]::new(0,0,0,15)
        $button.Height = 47
        $button.Tag = $word.keyword
        $button.add_Click({ param($sender, $event) Submit-Search $sender.Tag })
        [void]$script:hotPanel.Children.Add($button)
    }
}

function Load-HotSearch {
    Invoke-Request 'catalog' 'hot-search' 1 {
        param($result)
        if ($result -and -not $result.error) { $script:keywords = @($result.items); Render-HotSearch }
    }
}

function New-ResultGrid {
    if ($script:page.id.StartsWith('comments:')) {
        Add-CommentHeader
        $script:grid = [Windows.Controls.StackPanel]::new()
        $script:grid.HorizontalAlignment = 'Stretch'
    } else {
        $script:grid = [Windows.Controls.Primitives.UniformGrid]::new()
        $script:grid.Columns = 4
    }
    [void]$Body.Children.Add($script:grid)
}

function Add-CommentHeader {
    $header = [Windows.Controls.StackPanel]::new()
    $header.Orientation = 'Horizontal'
    $header.Margin = [Windows.Thickness]::new(22,0,0,12)
    if ($script:page.id -match '^(comments:\d+)(?::latest)?$') {
        $base = $Matches[1]
        $count = New-Text $(if ($script:page.total) { [string]$script:page.total } else { '' }) 16 $commentMuted
        $count.Margin = [Windows.Thickness]::new(0,0,18,0)
        $count.VerticalAlignment = 'Center'
        $script:page.countLabel = $count
        [void]$header.Children.Add($count)
        foreach ($choice in @(@('最热', $base), @('最新', ($base + ':latest')))) {
            $button = New-PageButton $choice[0]
            $button.Background = [Windows.Media.Brushes]::Transparent
            if ($script:page.id -eq $choice[1]) { $button.Foreground = $commentAccent }
            $button.Tag = @{commentSort = $choice[1]}
            $button.add_Click({
                param($sender, $event)
                if ($script:page.id -eq $sender.Tag.commentSort) { return }
                $script:page.id = $sender.Tag.commentSort
                $script:page.loaded = $false
                Refresh-Page
            })
            [void]$header.Children.Add($button)
        }
    } else {
        $button = New-PageButton '‹ 返回评论'
        $button.add_Click({ Back })
        [void]$header.Children.Add($button)
    }
    [void]$Body.Children.Add($header)
}

function Add-Result($Item) {
    if (-not $script:page.id.StartsWith('comments:')) { Add-Card $Item; return }
    $button = [Windows.Controls.Button]::new()
    $button.Style = $window.FindResource('CommentRow')
    $button.Margin = [Windows.Thickness]::new(12,0,25,0)
    $button.Padding = [Windows.Thickness]::new(10,13,10,0)
    $button.Tag = @{item = $Item; index = $cards.Count}
    $layout = [Windows.Controls.DockPanel]::new()
    $avatarUri = if ($Item.avatar) { [Uri]$Item.avatar } else { Get-Asset 'default_avatar.png' }
    $avatar = New-Image $avatarUri 'UniformToFill' 48
    $avatar.Width = 44; $avatar.Height = 44
    $avatar.Clip = [Windows.Media.EllipseGeometry]::new([Windows.Point]::new(22,22),22,22)
    $avatar.Margin = [Windows.Thickness]::new(0,0,15,0)
    $avatar.VerticalAlignment = 'Top'
    [void]$layout.Children.Add($avatar)
    $row = [Windows.Controls.StackPanel]::new()
    $name = New-Text $Item.author 17 $secondary $true
    $name.Margin = [Windows.Thickness]::new(0,0,0,5)
    [void]$row.Children.Add($name)
    if ($Item.title) {
        $message = New-Text $Item.title 18 $normal
        $message.TextWrapping = 'Wrap'
        $message.LineHeight = 26
        $message.TextTrimming = 'None'
        [void]$row.Children.Add($message)
    }
    if ($Item.pictures) {
        $pictures = [Windows.Controls.WrapPanel]::new()
        $pictures.Margin = [Windows.Thickness]::new(0,8,0,0)
        foreach ($picture in $Item.pictures) {
            $thumbnail = New-Image ([Uri]$picture) 'UniformToFill' 208
            $thumbnail.Width = 104; $thumbnail.Height = 84
            $thumbnail.Margin = [Windows.Thickness]::new(0,0,6,4)
            [void]$pictures.Children.Add($thumbnail)
        }
        [void]$row.Children.Add($pictures)
    }
    $date = if ($Item.published -gt 0) { [DateTimeOffset]::FromUnixTimeSeconds([long]$Item.published).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } else { '' }
    $summary = (@($date, "$($Item.views) 赞") | Where-Object { $_ }) -join '   ·   '
    $info = New-Text $summary 14 $commentMuted
    $info.Margin = [Windows.Thickness]::new(0,7,0,0)
    [void]$row.Children.Add($info)
    foreach ($reply in @($Item.preview | Where-Object { $_ })) {
        $snippet = New-Text ($reply.author + '：' + ([string]$reply.title -replace '\s+', ' ')) 15 $secondary
        $snippet.Margin = [Windows.Thickness]::new(0,6,0,0)
        [void]$row.Children.Add($snippet)
    }
    if ($Item.replies -gt 0 -and $script:page.id -match '^comments:\d+(?::latest)?$') {
        $replies = New-Text "查看全部 $($Item.replies) 条回复 ›" 15 $commentAccent
        $replies.Margin = [Windows.Thickness]::new(0,8,0,0)
        [void]$row.Children.Add($replies)
    }
    $line = [Windows.Controls.Border]::new()
    $line.Background = $divider
    $line.Height = 1
    $line.Margin = [Windows.Thickness]::new(0,13,0,0)
    [void]$row.Children.Add($line)
    [void]$layout.Children.Add($row)
    $button.Content = $layout
    $button.add_GotKeyboardFocus({ param($sender, $event) $script:selected = $sender.Tag.index; $sender.BringIntoView() })
    $button.add_Click({
        param($sender, $event)
        if ($script:page.id -match '^(comments:\d+)(?::latest)?$' -and $sender.Tag.item.replies -gt 0) {
            Open-ChildList ($Matches[1] + ':' + $sender.Tag.item.id) '评论回复' $sender.Tag.index
        }
    })
    [void]$cards.Add($button)
    [void]$script:grid.Children.Add($button)
}

function Load-Page([bool]$Append = $false) {
    $state = $script:page
    $number = if ($Append) { $state.number + 1 } else { 1 }
    if ($number -gt 100) { return }
    $action = switch ($state.id) {
        'search' { 'search' }
        {$_ -in @('home','popular')} { 'browse' }
        default { 'catalog' }
    }
    $value = if ($action -eq 'search') { $script:lastSearch } else { $state.id }
    Show-Status '正在加载…'
    Invoke-Request $action $value $number {
        param($data, $context)
        $state = $context.state
        if (-not [object]::ReferenceEquals($script:page, $state)) { return }
        if (-not $data -or $data.error) {
            if ($cards.Count) { Show-Status '加载失败，按 F5 重试。' }
            else { Show-EmptyState '加载失败，请重试。' }
            return
        }
        if ($data.requiresLogin) { Show-EmptyState '登录后即可使用此功能。' 'signin'; return }
        $known = @{}
        foreach ($item in $state.items) { if ($item.url) { $known[$item.url] = $true } elseif ($item.id) { $known[$item.id] = $true } }
        $firstNew = $state.items.Count
        foreach ($item in $data.items) {
            $identity = if ($item.url) { $item.url } else { $item.id }
            if ($identity -and -not $known.ContainsKey($identity)) {
                $known[$identity] = $true
                $state.items += $item
                Add-Result $item
            }
        }
        $state.loaded = $true
        $state.number = $context.number
        $state.more = $data.more
        $state.cursor = $data.cursor
        if ($state.countLabel -and $data.total -gt 0) { $state.total = $data.total; $state.countLabel.Text = [string]$state.total }
        if ($state.id -eq 'search' -and $script:keyboard) {
            $script:keyboard.Visibility = 'Collapsed'
            $Body.Children[1].Visibility = 'Visible'
        }
        if ($cards.Count) { Show-Status } else { Show-EmptyState '这里还没有内容。' }
        Update-More
        if ($cards.Count -gt $firstNew -and $SignInOverlay.Visibility -ne 'Visible' -and
            ([Windows.Input.Keyboard]::FocusedElement -isnot [Windows.Controls.TextBox])) { Select-Card $firstNew }
    } @{state = $state; number = $number; cursor = $state.cursor}
}

function New-Page([string]$Id, [string]$Title, [string]$Rail, [bool]$Standalone = $false) {
    @{id = $Id; title = $Title; rail = $Rail; standalone = $Standalone; items = @(); loaded = $false; number = 0; more = $false; cursor = ''; focus = 0}
}

function Open-Section($Section, [string]$Rail = '', [bool]$Reload = $false) {
    Cancel-Request
    $stack.Clear()
    if (-not $Rail) {
        $Rail = $Section.id
        if ($Rail -eq 'region') { $Section = $regions[0] }
        if ($Rail -eq 'mine') { $Section = $library[0] }
        if ($Rail -eq 'home') { $Section = $homePages[0] }
    }
    if ($script:page) { $script:page.focus = $script:selected }
    if ($Section.id -eq 'history') { $Reload = $true }
    $cacheKey = $Rail + ':' + $Section.id
    if ($Reload -or -not $pageCache.ContainsKey($cacheKey)) {
        $pageCache[$cacheKey] = New-Page $Section.id $Section.title $Rail
    }
    $script:page = $pageCache[$cacheKey]
    Render-Page $script:page.focus
    if ($Section.id -eq 'search') {
        if (-not $script:keywords.Count) { Load-HotSearch }
    } elseif (-not $script:page.loaded) { Load-Page }
}

function Open-ChildList([string]$Key, [string]$Title, [int]$Index) {
    $script:page.focus = $Index
    $stack.Push($script:page)
    $script:page = New-Page $Key $Title $script:page.rail $true
    Render-Page
    Load-Page
}

function Open-VideoList([string]$Kind, $Video) {
    switch ($Kind) {
        'author' { if ($Video.mid) { Open-ChildList ('author:' + $Video.mid) 'UP 主投稿' 0 } }
        'related' { if ($Video.bvid) { Open-ChildList ('related:' + $Video.bvid) '相关视频' 0 } }
        'comments' { if ($Video.aid) { Open-ChildList ('comments:' + $Video.aid) '评论' 0 } }
        'actions' { if ($Video.aid) { Open-VideoActions $Video } }
    }
}

function Open-Item($Item, [int]$Index) {
    switch ($Item.kind) {
        'catalog' { Open-ChildList $Item.key $Item.title $Index }
        'live' { Finish 'play' $Item.url }
        default { Open-Detail $Item $Index }
    }
}

function Submit-Search([string]$Text) {
    $value = $Text.Trim()
    if (-not $value) { return }
    if ($value -cmatch '^https://(?:live\.bilibili\.com/[1-9]\d{0,12}/?|www\.bilibili\.com/bangumi/play/ep[1-9]\d{0,12})$') {
        Finish 'play' $value
        return
    }
    if ($value -cmatch '^(BV[A-Za-z0-9]{10}|av[1-9]\d*)$|^https?://(?:www\.|m\.)?bilibili\.com/video/|^https://www\.bilibili\.com/bangumi/play/ss[1-9]\d{0,12}$') {
        Open-Detail @{url = $value; title = '视频详情'} 0
        return
    }
    if ($value.Length -gt 100) { Show-Status '关键词最多 100 个字符。'; return }
    $script:recentSearch = @($value) + @($script:recentSearch | Where-Object { $_ -cne $value } | Select-Object -First 9)
    try {
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($searchFile))
        [IO.File]::WriteAllText($searchFile, (ConvertTo-Json -InputObject $script:recentSearch -Compress))
    } catch {}
    $script:lastSearch = $value
    $script:page.items = @()
    $script:page.more = $false
    $script:page.number = 0
    $script:page.cursor = ''
    $script:page.loaded = $false
    Render-Page
    Load-Page
}

function New-PageButton($Label) {
    $button = [Windows.Controls.Button]::new()
    $button.Content = $Label
    $button.Margin = [Windows.Thickness]::new(3)
    $button.Padding = [Windows.Thickness]::new(12,8,12,8)
    $button.Background = $purple
    $button
}

function Back {
    if ($stack.Count) {
        Cancel-Request
        $script:page = $stack.Pop()
        if ($script:page.id -eq 'detail') { Render-Detail $script:page.detail; return }
        if ($script:page.id -eq 'actions') { Render-VideoActions $script:page.video; return }
        Render-Page $script:page.focus
    } elseif ($script:page.id -eq 'search' -and $script:page.loaded) {
        $script:page.items = @(); $script:page.loaded = $false; $script:page.more = $false; $script:page.number = 0
        Render-Page
    } elseif ($script:page.rail -ne 'home') { Open-Section $sections[1] }
    else { $window.Close() }
}

function Invoke-BrowserBack {
    if ($SignInOverlay.Visibility -eq 'Visible') { Close-BrowserSignIn }
    elseif ($DialogOverlay.Visibility -eq 'Visible') { Close-BbllDialog }
    elseif ($ProfileOverlay.Visibility -eq 'Visible') { Close-AccountProfile }
    elseif ($SettingsView.Visibility -eq 'Visible') { Close-Settings }
    elseif ($script:page) { Back }
}

function Render-Detail($data) {
    $script:searchBox = $null
    $script:keyboard = $null
    Set-Header
    $MoreButton.Visibility = 'Collapsed'
    $Body.Children.Clear()
    $cards.Clear()
    $Viewport.ScrollToHome()
    Show-Status '正在读取详情…'
    $return = New-PageButton '‹ 返回'
    $return.HorizontalAlignment = 'Left'
    $return.add_Click({ Back })
    [void]$Body.Children.Add($return)
    [void]$return.Focus()
    if (-not $data) { return }
        $summary = [Windows.Controls.DockPanel]::new()
        $summary.Margin = [Windows.Thickness]::new(5,8,7,22)
        $cover = New-Cover $data
        $cover.Width = 310
        $cover.Height = 174
        $cover.Margin = [Windows.Thickness]::new(0,0,24,0)
        [void]$summary.Children.Add($cover)
        $text = [Windows.Controls.StackPanel]::new()
        $title = New-Text $data.title 28 $normal $true
        $title.TextWrapping = 'Wrap'
        [void]$text.Children.Add($title)
        [void]$text.Children.Add((New-Text $data.author 17 $secondary))
        $desc = New-Text $data.description 15 $secondary
        $desc.TextWrapping = 'Wrap'
        $desc.MaxHeight = 105
        $desc.Margin = [Windows.Thickness]::new(0,10,0,0)
        [void]$text.Children.Add($desc)
        [void]$summary.Children.Add($text)
        [void]$Body.Children.Add($summary)
        $heading = New-Text '选集' 21 $normal $true
        $heading.Margin = [Windows.Thickness]::new(7,0,0,8)
        [void]$Body.Children.Add($heading)
        $parts = [Windows.Controls.Primitives.UniformGrid]::new()
        $parts.Columns = 4
        [void]$Body.Children.Add($parts)
        foreach ($part in $data.parts) {
            $caption = if ($data.parts.Count -eq 1) { '▶ 播放视频' } elseif ($data.kind -eq 'season') {
                $part.page + '  ' + $part.title
            } else { 'P' + $part.page + '  ' + $part.title }
            $button = New-PageButton (New-Text $caption 17 $normal)
            $button.Tag = @{url = $part.url; queue = $data.parts}
            $button.add_Click({ param($sender, $event) Finish 'play' $sender.Tag.url $sender.Tag.queue })
            $button.add_GotKeyboardFocus({ param($sender, $event) $sender.BringIntoView() })
            $button.ToolTip = $caption
            [void]$parts.Children.Add($button)
        }
        $actions = [Windows.Controls.WrapPanel]::new()
        $actions.Orientation = 'Horizontal'
        $actions.Margin = [Windows.Thickness]::new(4,16,4,0)
        if ($data.aid) {
            [void]$actions.Children.Add((New-Action '稍后再看' "later:$($data.aid)"))
            [void]$actions.Children.Add((New-FavoriteButton $data.aid '收藏'))
        }
        foreach ($entry in @(@('UP 主投稿', ('author:' + $data.mid), $data.mid),
                @('相关视频', ('related:' + $data.bvid), $data.bvid),
                @('评论', ('comments:' + $data.aid), $data.aid))) {
            if (-not $entry[2]) { continue }
            $action = New-PageButton $entry[0]
            $action.Tag = @{key = $entry[1]; title = $entry[0]}
            $action.add_Click({ param($sender, $event) Open-ChildList $sender.Tag.key $sender.Tag.title 0 })
            [void]$actions.Children.Add($action)
        }
        if ($data.aid) {
            $more = New-PageButton '更多操作'
            $more.Tag = $data
            $more.add_Click({ param($sender, $event) Open-VideoActions $sender.Tag })
            [void]$actions.Children.Add($more)
        }
        if ($data.seasonId) {
            [void]$actions.Children.Add((New-Action '追番' "season:$($data.seasonId):add"))
            [void]$actions.Children.Add((New-Action '取消追番' "season:$($data.seasonId):del"))
        }
        [void]$Body.Children.Add($actions)
        if ($parts.Children.Count) {
            $position = [Math]::Min($parts.Children.Count - 1, [Math]::Max(0, [int]$data.part - 1))
            [void]$parts.Children[$position].Focus()
            Show-Status
        } else { Show-Status '没有可播放的剧集。' }
}

function New-Action([string]$Label, [string]$Value) {
    $button = New-PageButton $Label
    $button.HorizontalAlignment = 'Left'
    $button.Tag = @{label = $Label; value = $Value}
    $button.add_Click({ param($sender, $event) Confirm-VideoAction $sender.Tag.label $sender.Tag.value })
    $button
}

function New-FavoriteButton([string]$Aid, [string]$Label) {
    $button = New-PageButton $Label
    $button.HorizontalAlignment = 'Left'
    $button.Tag = @{aid = $Aid; action = 'favorite-folders'}
    $button.add_Click({ param($sender, $event) Show-FavoriteFolders $sender.Tag.aid })
    $button
}

function Confirm-VideoAction([string]$Label, [string]$Value) {
    if ($requests.page) { return }
    $question = "确定要执行「$Label」吗？"
    if ($Value -match '^later:') { $question = '加入 B 站「稍后再看」？' }
    if ($Value -match '^(coin|triple):') { $question += ' 此操作会消耗硬币。' }
    Show-BbllDialog '确认操作' @(@{text = '取消'; value = $false}, @{text = '确认'; value = $true}) 0 {
        param($answer, $operation)
        if ($answer.value) { Submit-VideoAction $operation }
    } $Value $question
}

function Submit-VideoAction([string]$Value, [switch]$Retried) {
    if ($requests.page) { return }
    Show-Status '正在提交操作…'
    Invoke-Request 'interaction' $Value 1 {
        param($response, $context)
        if ($response.requiresLogin) {
            if ($PlayMailbox -and $context.value -like 'later:*' -and -not $context.retried) {
                Show-Status '当前登录需要更新后才能加入稍后再看。'
                Show-BbllDialog '重新扫码登录' @(@{text='取消'}, @{text='扫码并加入稍后再看'; confirm=$true}) 0 {
                    param($choice, $operation)
                    if (-not $choice.confirm) { return }
                    Open-BrowserSignIn @{value = $operation; page = $script:page}
                } $context.value '请用哔哩哔哩 App 扫码。确认登录后会加入当前视频。'
            } else { Show-Status '账号写入凭据无效，请通过左下角头像或 Alt+L 重新扫码。' }
            return
        }
        if ($response.success) {
            foreach ($key in @('mine:later','mine:folders','mine:following','mine:following-seasons','dynamic:dynamic')) { $pageCache.Remove($key) }
            $message = switch -Regex ($context.value) {
                '^later:' { '已加入「我的 → 稍后再看」。' }
                '^favorite:.*:add$' { '已收藏，可在「我的 → 收藏夹」查看。' }
                '^favorite:.*:remove$' { '已从所选收藏夹移除。' }
                default { '操作成功。' }
            }
            Show-Status $message
        } else { Show-Status ('操作未完成：' + $response.error) }
    } @{value = $Value; retried = $Retried.IsPresent}
}

function Open-VideoActions($Video) {
    $stack.Push($script:page)
    $script:page = New-Page 'actions' '视频操作' $script:page.rail $true
    $script:page.video = $Video
    Render-VideoActions $Video
}

function Render-VideoActions($Video) {
    Render-Page
    foreach ($item in @(@('点赞', "like:$($Video.aid):1"), @('取消点赞', "like:$($Video.aid):2"),
            @('投 1 枚硬币', "coin:$($Video.aid):1"), @('投 2 枚硬币', "coin:$($Video.aid):2"),
            @('一键三连', "triple:$($Video.aid)"), @('加入稍后再看', "later:$($Video.aid)"))) {
        [void]$Body.Children.Add((New-Action $item[0] $item[1]))
    }
    if ($Video.mid) {
        [void]$Body.Children.Add((New-Action '关注 UP 主' "follow:$($Video.mid):1"))
        [void]$Body.Children.Add((New-Action '取消关注' "follow:$($Video.mid):2"))
    }
    [void]$Body.Children.Add((New-FavoriteButton $Video.aid '选择收藏夹'))
    [void]$Body.Children[1].Focus()
}

function Show-FavoriteFolders([string]$Aid) {
    if ($requests.page) { return }
    Show-Status '正在读取收藏夹…'
    Invoke-Request 'catalog' 'folders' 1 {
        param($result, $context)
        if ($result.requiresLogin) { Show-Status '请先通过左下角用户图标扫码登录。'; return }
        if (-not $result -or $result.error) { Show-Status ('无法读取收藏夹，请重试。' + $result.error); return }
        if (-not $result.items.Count) { Show-Status '账号没有收藏夹。'; return }
        $stack.Push($script:page)
        $script:page = New-Page 'favorite-picker' '选择收藏夹' $script:page.rail $true
        Set-Header
        $Body.Children.Clear()
        $Viewport.ScrollToHome()
        $backButton = New-PageButton '‹ 返回'
        $backButton.HorizontalAlignment = 'Left'
        $backButton.add_Click({ Back })
        [void]$Body.Children.Add($backButton)
        foreach ($folder in $result.items) {
            $id = $folder.key.Split(':')[-1]
            $row = [Windows.Controls.StackPanel]::new()
            $row.Orientation = 'Horizontal'
            [void]$row.Children.Add((New-Text $folder.title 20 $normal))
            [void]$row.Children.Add((New-Action '收藏到此' ("favorite:{0}:{1}:add" -f $context.aid, $id)))
            [void]$row.Children.Add((New-Action '从此移除' ("favorite:{0}:{1}:remove" -f $context.aid, $id)))
            foreach ($button in $row.Children | Where-Object { $_ -is [Windows.Controls.Button] }) {
                $button.Tag.label = $button.Content + '：' + $folder.title
            }
            [void]$Body.Children.Add($row)
        }
        [void]$Body.Children[1].Children[1].Focus()
        Show-Status
    } @{aid = $Aid}
}

function Load-Detail {
    Render-Detail $null
    Invoke-Request 'detail' $script:page.item.url 1 {
        param($data)
        if (-not $data -or $data.error) { Show-Status ('无法读取详情。' + $data.error); return }
        $script:page.detail = $data
        Render-Detail $data
        if ($script:page.view -and $script:page.view -ne 'detail') {
            $view = $script:page.view
            $script:page.view = 'detail'
            Open-VideoList $view $data
        }
    }
}

function Open-Detail($Item, [int]$Index, [string]$View = 'detail') {
    $script:page.focus = $Index
    $stack.Push($script:page)
    $script:page = New-Page 'detail' $(if ($Item.kind -eq 'season') { '剧集详情' } else { '视频详情' }) $script:page.rail $true
    $script:page.item = $Item
    $script:page.view = $View
    Load-Detail
}

function Refresh-Page {
    if ($script:page.id -eq 'detail') { Load-Detail; return }
    if ($script:page.id -eq 'search' -and $script:searchBox.Text.Trim()) { Submit-Search $script:searchBox.Text; return }
    if ($script:page.standalone) {
        $script:page.items = @()
        $script:page.number = 0
        $script:page.cursor = ''
        Render-Page
        Load-Page
    } elseif ($script:page.id -eq 'search') { Load-HotSearch }
    else { Open-Section $script:page $script:page.rail $true }
}

function Toggle-FullScreen {
    $window.WindowState = if ($window.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' }
}

function Update-WindowControls {
    if ($window.WindowState -eq 'Minimized') { return }
    $script:restoreWindowState = $window.WindowState
    $isExpanded = $window.WindowState -eq 'Maximized'
    $FullscreenButton.Content = [string]$(if ($isExpanded) { [char]0xE923 } else { [char]0xE922 })
    $label = if ($isExpanded) { '退出全屏' } else { '全屏' }
    $FullscreenButton.ToolTip = "$label (F11)"
    [Windows.Automation.AutomationProperties]::SetName($FullscreenButton, $label)
}

$Backdrop.Source = (New-Image (Get-Asset 'background.png') 'Fill').Source
Initialize-Settings
Update-WindowControls
$window.add_StateChanged({ Update-WindowControls })
$MinimizeButton.add_Click({ $window.WindowState = 'Minimized' })
$FullscreenButton.add_Click({ Toggle-FullScreen })
$CloseWindowButton.add_Click({ $window.Close() })
foreach ($section in $sections) {
    $button = [Windows.Controls.Button]::new()
    $button.Style = $window.FindResource('RailButton')
    $button.Margin = [Windows.Thickness]::new(0,0,0,13)
    $button.Tag = $section
    Set-ButtonIcon $button $section.icon $section.title
    $button.add_Click({ param($sender, $event) Open-Section $sender.Tag })
    $tabs[$section.id] = $button
    [void]$Sidebar.Children.Add($button)
}
Initialize-AccountProfile
$AccountButton.add_Click({ Open-AccountProfile })
Set-ButtonIcon $SettingsButton 'icon_setting' '设置'
$SettingsButton.add_Click({ Open-Settings })
$EmptyAction.add_Click({
    if ($EmptyAction.Tag -eq 'signin') { Open-BrowserSignIn @{refresh = $true; page = $script:page} }
    else { Refresh-Page }
})
$MoreButton.Content = '下一页'
$MoreButton.add_Click({ Load-Page $true })
$dragHeader = {
    param($sender, $event)
    $source = $event.OriginalSource
    while ($source -and $source -ne $sender) {
        if ($source -is [Windows.Controls.Primitives.ButtonBase] -or
            $source -is [Windows.Controls.Primitives.TextBoxBase] -or
            $source -is [Windows.Controls.Primitives.ScrollBar]) { return }
        $source = if ($source -is [Windows.FrameworkContentElement]) { $source.Parent }
            else { [Windows.Media.VisualTreeHelper]::GetParent($source) }
    }
    $event.Handled = $true
    try { $window.DragMove() } catch [InvalidOperationException] {}
}
$Header.add_PreviewMouseLeftButtonDown($dragHeader)
$SettingsHeader.add_PreviewMouseLeftButtonDown($dragHeader)
$SignInHeader.add_PreviewMouseLeftButtonDown($dragHeader)
$Viewport.add_ScrollChanged({
    param($sender, $event)
    if ($event.VerticalChange -gt 0 -and $script:page.more -and -not $requests.page -and
        $sender.ScrollableHeight - $sender.VerticalOffset -lt 120) { Load-Page $true }
})
$window.add_PreviewMouseUp({ param($sender, $event)
    if ($event.ChangedButton -eq 'Right') {
        $event.Handled = $true
        Invoke-BrowserBack
    }
})
$window.add_PreviewKeyDown({ param($sender, $event)
    if ($event.Key -in @('Escape','BrowserBack')) { $event.Handled = $true; Invoke-BrowserBack; return }
    if ($SignInOverlay.Visibility -eq 'Visible') {
        Invoke-BrowserSignInKey $event
        return
    }
    if ($DialogOverlay.Visibility -eq 'Visible') {
        Invoke-BbllDialogKey $event
        return
    }
    if ($ProfileOverlay.Visibility -eq 'Visible') {
        Invoke-AccountProfileKey $event
        return
    }
    if ($SettingsView.Visibility -eq 'Visible') {
        $focused = [Windows.Input.Keyboard]::FocusedElement
        if ($event.Key -eq 'F1') { $event.Handled = $true; Close-Settings; return }
        if ($event.Key -eq 'Right' -and $SettingsCategories.Children -contains $focused) {
            $option = $SettingsRows.Children | Where-Object { $_ -is [Windows.Controls.Button] -and $_.Focusable } | Select-Object -First 1
            if ($option) { [void]$option.Focus() }
            $event.Handled = $true; return
        }
        if ($event.Key -eq 'Left' -and $SettingsRows.Children -contains $focused) {
            [void]$SettingsCategories.Children[$script:settingsGroup].Focus()
            $event.Handled = $true; return
        }
        if ($event.Key -notin @('Return','F11')) { return }
    }
    if ($event.Key -eq 'F11') { $event.Handled = $true; Toggle-FullScreen; return }
    if ($event.Key -eq 'F5') { $event.Handled = $true; if ($script:page.id -notin @('settings','actions','favorite-picker')) { Refresh-Page }; return }
    if ($event.Key -eq 'F1') { $event.Handled = $true; Open-Settings; return }
    $focused = [Windows.Input.Keyboard]::FocusedElement
    if ($focused -isnot [Windows.Controls.Button]) { return }
    if ($event.Key -eq 'Return') {
        $event.Handled = $true
        $focused.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        return
    }
    if ($focused -eq $MoreButton -and $event.Key -eq 'Up' -and $cards.Count) {
        Select-Card ($cards.Count - 1); $event.Handled = $true
    } elseif ($focused.Tag -is [hashtable] -and $focused.Tag.ContainsKey('index')) {
        $index = $focused.Tag.index
        $columns = if ($script:page.id.StartsWith('comments:')) { 1 } else { $script:grid.Columns }
        switch ($event.Key) {
            'Left' { if ($index % $columns -eq 0) { [void]$tabs[$script:page.rail].Focus() } else { Select-Card ($index - 1) }; $event.Handled = $true }
            'Right' { if ($index % $columns -lt ($columns - 1)) { Select-Card ($index + 1) }; $event.Handled = $true }
            'Up' {
                if ($index -ge $columns) { Select-Card ($index - $columns) }
                elseif ($script:searchBox) { [void]$script:searchBox.Focus() }
                elseif ($script:page.id.StartsWith('comments:') -and $Body.Children[0].Children.Count) {
                    $sort = $Body.Children[0].Children | Where-Object { $_ -is [Windows.Controls.Button] } | Select-Object -First 1
                    if ($sort) { [void]$sort.Focus() }
                }
                else { Select-HeaderTab }
                $event.Handled = $true
            }
            'Down' {
                if ($index + $columns -lt $cards.Count) { Select-Card ($index + $columns) }
                elseif ($script:page.more -and -not $requests.page) { Load-Page $true }
                $event.Handled = $true
            }
        }
    } elseif ($focused.Tag -is [hashtable] -and $focused.Tag.ContainsKey('id') -and $event.Key -eq 'Right') {
        if ($cards.Count) { Select-Card $script:selected } elseif ($script:searchBox) { [void]$script:searchBox.Focus() }
        $event.Handled = $true
    } elseif ($focused.Tag -is [hashtable] -and $focused.Tag.ContainsKey('choice') -and $event.Key -eq 'Down') {
        if ($cards.Count) { Select-Card 0 }; $event.Handled = $true
    }
})
$clock = [Windows.Threading.DispatcherTimer]::new()
$clock.Interval = [TimeSpan]::FromSeconds(15)
$clockCulture = [Globalization.CultureInfo]::GetCultureInfo('zh-CN')
$clock.add_Tick({ $ClockText.Text = [DateTime]::Now.ToString('tth:mm', $clockCulture); Sync-AccountProfile })
$ClockText.Text = [DateTime]::Now.ToString('tth:mm', $clockCulture)
$clock.Start()
$focusTimer = [Windows.Threading.DispatcherTimer]::new()
if ($PlayMailbox) {
    $focusTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $focusTimer.add_Tick({
        $signinSignal = $PlayMailbox + '.signin'
        if ([IO.File]::Exists($signinSignal)) {
            try {
                $signin = [IO.File]::ReadAllText($signinSignal) | ConvertFrom-Json
                [IO.File]::Delete($signinSignal)
            } catch { return }
            Update-BrowserSignIn $signin
        }
        $signal = $PlayMailbox + '.focus'
        if (-not [IO.File]::Exists($signal)) { return }
        $request = $null
        try {
            $payload = [IO.File]::ReadAllText($signal)
            [IO.File]::Delete($signal)
            if ($payload) { $request = $payload | ConvertFrom-Json -ErrorAction SilentlyContinue }
        } catch { return }
        if ($window.WindowState -eq 'Minimized') { $window.WindowState = $script:restoreWindowState }
        try { [void](New-Object -ComObject WScript.Shell).AppActivate($PID) } catch {}
        [void]$window.Activate()
        if ($request.url -and $script:page) {
            Close-BrowserSignIn
            Close-BbllDialog
            Close-AccountProfile
            if ($SettingsView.Visibility -eq 'Visible') { Close-Settings }
            Open-Detail @{url = $request.url} $script:selected $request.view
        }
        if ($request.signin) { Open-BrowserSignIn }
    })
    $focusTimer.Start()
}
$window.add_ContentRendered({
    Sync-AccountProfile
    if (-not $script:page) {
        switch ($settings.start) {
            'popular' { Open-Section $homePages[1] 'home' }
            'search' { Open-Section $sections[0] }
            'mine' { Open-Section $sections[5] }
            'region' { Open-Section $sections[2] }
            'dynamic' { Open-Section $sections[3] }
            {$_ -in @('folders','following-seasons','following-series','later')} {
                $entry = $library | Where-Object { $_.id -eq $settings.start } | Select-Object -First 1
                Open-Section $entry 'mine'
            }
            default { Open-Section $sections[1] }
        }
        if ($CurrentVideo) { Open-Detail @{url = $CurrentVideo; title = '当前视频'} 0 $StartView }
        if ($SignInOnStart) { Open-BrowserSignIn }
    }
    if ($OnReady) { & $OnReady $window }
})
$window.add_Activated({ Sync-AccountProfile })
[void]$window.add_Closed({ Cancel-Request; Cancel-Request 'account'; $timer.Stop(); $clock.Stop(); $focusTimer.Stop() })
[void]$window.ShowDialog()
if ($script:output) { $script:output | ConvertTo-Json -Compress }
