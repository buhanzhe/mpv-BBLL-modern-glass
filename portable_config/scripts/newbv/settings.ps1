$settingsFile = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'mpv-newbv\settings.json'
$defaults = @{start = 'home'; autobrowse = ($DefaultAutobrowse -ne 'no'); picture = 480; theme = 'dark'; fullscreen = $false; quality = $null; qualityRevision = $null; codec = ''; audio = 'aac'
    speed = 1; subtitles = 'auto'; danmaku = 'theme'; dmSize = $null; dmOpacity = $null; dmSpeed = $null
    dmArea = $null; dmDensity = $null; dmTop = $true; dmBottom = $true}
$settings = $defaults.Clone()
try {
    if ([IO.File]::Exists($settingsFile) -and ([IO.FileInfo]$settingsFile).Length -lt 16384) {
        $stored = [IO.File]::ReadAllText($settingsFile) | ConvertFrom-Json
        foreach ($property in $stored.PSObject.Properties) {
            if ($settings.ContainsKey($property.Name)) { $settings[$property.Name] = $property.Value }
        }
    }
} catch {}

function Save-BrowserSettings {
    try {
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($settingsFile))
        $temporary = $settingsFile + '.' + $PID + '.tmp'
        [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $settings -Compress), [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($settingsFile)) { [IO.File]::Replace($temporary, $settingsFile, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $settingsFile) }
        return $true
    } catch {
        Show-BbllDialog '设置' @(@{text = '知道了'}) 0 $null $null '无法保存设置，请检查用户目录权限。'
        return $false
    }
}

function New-SettingChoice($Value, [string]$Text) { @{value = $Value; text = $Text} }

function Get-DanmakuChoices([int[]]$Values, [string]$Suffix) {
    New-SettingChoice $null '跟随主题'
    foreach ($value in $Values) { New-SettingChoice $value "$value$Suffix" }
}

$settingGroups = @(
    @{title = '通用设置'; icon = 'icon_setting'; rows = @(
        @{title = '默认启动页面'; key = 'start'; choices = @(
            (New-SettingChoice 'home' '推荐'), (New-SettingChoice 'popular' '热门'), (New-SettingChoice 'region' '分区'),
            (New-SettingChoice 'dynamic' '动态'), (New-SettingChoice 'mine' '历史'), (New-SettingChoice 'folders' '收藏'),
            (New-SettingChoice 'following-seasons' '追番'), (New-SettingChoice 'following-series' '追剧'),
            (New-SettingChoice 'later' '稍后观看'), (New-SettingChoice 'search' '搜索')
        )},
        @{title = '随 mpv 启动打开 BBLL'; key = 'autobrowse'; choices = @((New-SettingChoice $true '开'), (New-SettingChoice $false '关'))},
        @{title = '图片质量'; key = 'picture'; choices = @((New-SettingChoice 320 '小尺寸'), (New-SettingChoice 480 '中尺寸'), (New-SettingChoice 640 '大尺寸'))},
        @{title = '主题'; key = 'theme'; choices = @((New-SettingChoice 'dark' '黑色'), (New-SettingChoice 'background' 'BBLL 背景图'))},
        @{title = '以全屏模式运行'; key = 'fullscreen'; choices = @((New-SettingChoice $false '关'), (New-SettingChoice $true '开'))},
        @{title = '账号登录 / 退出'; action = 'account'}
    )},
    @{title = '播放设置'; icon = 'icon_video_play_count'; rows = @(
        @{title = '默认画质'; key = 'quality'; choices = @((New-SettingChoice $null '自动 / 最高可用'), (New-SettingChoice 126 '杜比视界'), (New-SettingChoice 120 '4K'), (New-SettingChoice 112 '1080P 高码率'), (New-SettingChoice 80 '1080P'), (New-SettingChoice 64 '720P'), (New-SettingChoice 32 '480P'))},
        @{title = '默认音轨'; key = 'audio'; choices = @((New-SettingChoice 'aac' 'AAC'), (New-SettingChoice 'flac' 'Hi-Res / FLAC'), (New-SettingChoice 'eac3' 'Dolby'))},
        @{title = '默认播放速度'; key = 'speed'; choices = @((New-SettingChoice 1 '1.0×'), (New-SettingChoice 1.25 '1.25×'), (New-SettingChoice 1.5 '1.5×'), (New-SettingChoice 2 '2.0×'))},
        @{title = '视频编码'; key = 'codec'; choices = @((New-SettingChoice '' '自动'), (New-SettingChoice 'h264' 'AVC'), (New-SettingChoice 'hevc' 'HEVC'), (New-SettingChoice 'av1' 'AV1'))},
        @{title = '默认启用字幕'; key = 'subtitles'; choices = @((New-SettingChoice 'auto' '跟随播放器'), (New-SettingChoice 'no' '关'))},
        @{title = '清除手动选择的画质'; action = 'clear-quality'}
    )},
    @{title = '弹幕设置'; icon = 'icon_video_danmaku'; rows = @(
        @{title = '弹幕开关'; key = 'danmaku'; choices = @((New-SettingChoice 'theme' '跟随主题'), (New-SettingChoice 'on' '开'), (New-SettingChoice 'off' '关'))},
        @{title = '弹幕字体大小'; key = 'dmSize'; choices = @(Get-DanmakuChoices @(16,22,28,36,44,52,64) '')},
        @{title = '弹幕透明度'; key = 'dmOpacity'; choices = @(Get-DanmakuChoices @(0,20,40,60,80) '%')},
        @{title = '弹幕速度'; key = 'dmSpeed'; choices = @(
            (New-SettingChoice $null '跟随主题'), (New-SettingChoice 0.75 '0.75×'), (New-SettingChoice 1 '1.0×'),
            (New-SettingChoice 1.25 '1.25×'), (New-SettingChoice 1.5 '1.5×'), (New-SettingChoice 2 '2.0×'))},
        @{title = '弹幕占屏比'; key = 'dmArea'; choices = @(Get-DanmakuChoices @(10,25,50,75,100) '%')},
        @{title = '弹幕数量'; key = 'dmDensity'; choices = @(
            (New-SettingChoice $null '跟随主题'), (New-SettingChoice 8 '最多 8 条'), (New-SettingChoice 16 '最多 16 条'),
            (New-SettingChoice 32 '最多 32 条'), (New-SettingChoice 64 '最多 64 条'), (New-SettingChoice 0 '不限'))},
        @{title = '允许顶部悬停弹幕'; key = 'dmTop'; choices = @((New-SettingChoice $true '开'), (New-SettingChoice $false '关'))},
        @{title = '允许底部悬停弹幕'; key = 'dmBottom'; choices = @((New-SettingChoice $true '开'), (New-SettingChoice $false '关'))}
    )},
    @{title = '关于应用'; icon = 'icon_about'; rows = @()},
    @{title = '设备信息'; icon = 'ic_tv'; rows = @(
        @{title = 'CPU'; value = $env:PROCESSOR_ARCHITECTURE}, @{title = '系统'; value = [Environment]::OSVersion.VersionString},
        @{title = '分辨率'; value = "$([int][Windows.SystemParameters]::PrimaryScreenWidth) × $([int][Windows.SystemParameters]::PrimaryScreenHeight)"},
        @{title = '界面'; value = 'Windows WPF · mpv'}
    )}
)
$script:settingsGroup = 0
$script:beforeSettings = $null

function Apply-BrowserTheme {
    $Backdrop.Visibility = if ($settings.theme -eq 'background') { 'Visible' } else { 'Collapsed' }
}

function Select-SettingValue($Row) {
    if ($Row.action -eq 'account') { Open-AccountProfile; return }
    if ($Row.action -eq 'clear-quality') {
        $path = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'mpv-newbv-quality.json'
        try {
            [IO.File]::Delete($path)
            $message = '已清除，下次按默认画质播放。'
        } catch { $message = '无法清除画质记忆。' }
        Show-BbllDialog '播放设置' @(@{text = '知道了'}) 0 $null $null $message
        return
    }
    if (-not $Row.key) { return }
    $selected = 0
    for ($index = 0; $index -lt $Row.choices.Count; $index++) {
        if ($settings[$Row.key] -eq $Row.choices[$index].value) { $selected = $index; break }
    }
    Show-BbllDialog $Row.title $Row.choices $selected {
        param($choice, $key)
        if ($settings[$key] -eq $choice.value -and $key -ne 'quality') { return }
        $previous = $settings[$key]
        $revision = $settings.qualityRevision
        $settings[$key] = $choice.value
        if ($key -eq 'quality') { $settings.qualityRevision = [Guid]::NewGuid().ToString('N') }
        if (-not (Save-BrowserSettings)) { $settings[$key] = $previous; $settings.qualityRevision = $revision; return }
        Apply-BrowserTheme
        if ($key -eq 'fullscreen') { $window.WindowState = if ($settings.fullscreen) { 'Maximized' } else { 'Normal' } }
        Render-SettingsGroup $script:settingsGroup
        $rowButton = $SettingsRows.Children | Where-Object { $_ -is [Windows.Controls.Button] -and $_.Tag.key -eq $key } | Select-Object -First 1
        if ($rowButton) { [void]$rowButton.Focus(); $rowButton.BringIntoView() }
    } $Row.key
}

function Render-SettingsGroup([int]$Index) {
    $script:settingsGroup = $Index
    $group = $settingGroups[$Index]
    $SettingsRows.Children.Clear()
    foreach ($category in $SettingsCategories.Children) {
        $category.Background = if ($category.Tag -eq $Index) { $railSelection } else { [Windows.Media.Brushes]::Transparent }
    }
    if ($Index -eq 3) {
        $about = [Windows.Controls.StackPanel]::new()
        $about.Margin = [Windows.Thickness]::new(10,90,10,0)
        if ($window.Icon) {
            $logo = [Windows.Controls.Image]::new()
            $logo.Width = 155; $logo.Height = 155; $logo.Source = $window.Icon
            [void]$about.Children.Add($logo)
        }
        $title = New-Text 'BBLL 风格 · NewBV for mpv' 24 $normal $true
        $title.HorizontalAlignment = 'Center'; $title.Margin = [Windows.Thickness]::new(0,18,0,10)
        [void]$about.Children.Add($title)
        $bodyText = New-Text '界面参考 BBLL 1.5.2，接入 newBV 的 B 站 Web 接口，由 mpv 播放。此扩展不是 BBLL 官方客户端。' 19 $secondary
        $bodyText.TextWrapping = 'Wrap'; $bodyText.TextAlignment = 'Center'
        [void]$about.Children.Add($bodyText)
        [void]$SettingsRows.Children.Add($about)
        return
    }
    foreach ($row in $group.rows) {
        $button = [Windows.Controls.Button]::new()
        $button.Tag = $row
        $button.Height = 67
        $button.HorizontalContentAlignment = 'Stretch'
        $button.Padding = [Windows.Thickness]::new(0)
        $content = [Windows.Controls.DockPanel]::new()
        if ($row.key -or $row.action) {
            $arrow = New-Icon 'icon_back' 16
            if ($arrow) {
                $arrow.RenderTransform = [Windows.Media.ScaleTransform]::new(-1,1,8,8)
                $arrow.Margin = [Windows.Thickness]::new(10,0,0,0)
                [Windows.Controls.DockPanel]::SetDock($arrow, 'Right')
                [void]$content.Children.Add($arrow)
            }
        }
        $label = if ($row.key) { ($row.choices | Where-Object { $_.value -eq $settings[$row.key] } | Select-Object -First 1).text } else { $row.value }
        if ($label) {
            $value = New-Text $label 17 $secondary
            [Windows.Controls.DockPanel]::SetDock($value, 'Right')
            $value.VerticalAlignment = 'Center'
            [void]$content.Children.Add($value)
        }
        [void]$content.Children.Add((New-Text $row.title 20 $normal $true))
        $button.Content = $content
        $button.Focusable = [bool]($row.key -or $row.action)
        $button.add_Click({ param($sender, $event) Select-SettingValue $sender.Tag })
        $button.add_GotKeyboardFocus({ param($sender, $event) $sender.BringIntoView() })
        [void]$SettingsRows.Children.Add($button)
        $line = [Windows.Controls.Border]::new()
        $line.Height = 1
        $line.Background = $divider
        [void]$SettingsRows.Children.Add($line)
    }
    $SettingsScroll.ScrollToTop()
}

function Open-Settings {
    if ($SettingsView.Visibility -eq 'Visible') { return }
    $script:beforeSettings = [Windows.Input.Keyboard]::FocusedElement
    $MainView.Visibility = 'Collapsed'
    $SettingsView.Visibility = 'Visible'
    Render-SettingsGroup 0
    [void]$SettingsCategories.Children[0].Focus()
}

function Close-Settings {
    $SettingsView.Visibility = 'Collapsed'
    $MainView.Visibility = 'Visible'
    if ($script:beforeSettings) { [void]$script:beforeSettings.Focus() }
}

function Initialize-Settings {
    Set-ButtonIcon $SettingsBack 'icon_back' '返回'
    $SettingsBack.add_Click({ Close-Settings })
    for ($index = 0; $index -lt $settingGroups.Count; $index++) {
        $group = $settingGroups[$index]
        $button = New-PageButton $null
        $button.Style = $window.FindResource('SettingsCategory')
        $button.Height = 59
        $button.Margin = [Windows.Thickness]::new(0,0,0,13)
        $button.Padding = [Windows.Thickness]::new(20,0,0,0)
        $button.HorizontalContentAlignment = 'Left'
        $button.Tag = $index
        $panel = [Windows.Controls.StackPanel]::new(); $panel.Orientation = 'Horizontal'
        $icon = New-Icon $group.icon 29
        if ($icon) { $icon.Margin = [Windows.Thickness]::new(0,0,15,0); [void]$panel.Children.Add($icon) }
        [void]$panel.Children.Add((New-Text $group.title 20 $normal $true))
        $button.Content = $panel
        $button.add_Click({ param($sender, $event) Render-SettingsGroup $sender.Tag })
        $button.add_GotKeyboardFocus({ param($sender, $event) if ($script:settingsGroup -ne $sender.Tag) { Render-SettingsGroup $sender.Tag } })
        [void]$SettingsCategories.Children.Add($button)
    }
    Apply-BrowserTheme
    if ($settings.fullscreen -eq $true) { $window.WindowState = 'Maximized' }
}
