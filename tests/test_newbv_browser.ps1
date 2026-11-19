param([string]$ScreenshotDirectory, [string]$InstalledDirectory, [switch]$CheckFavoritePicker, [switch]$Legacy, [switch]$CheckLayout,
    [switch]$CheckAccountProfile)
$ErrorActionPreference = 'Stop'
$browser = Join-Path $PSScriptRoot '../portable_config/scripts/newbv/browser.ps1'
if ($InstalledDirectory) { $browser = Join-Path $InstalledDirectory 'browser.ps1' }
$withLauncherIcon = [IO.File]::Exists((Join-Path (Split-Path $browser -Parent) 'bbll-launcher.png.base64'))
if ($ScreenshotDirectory) { [void][IO.Directory]::CreateDirectory($ScreenshotDirectory) }

function Save-Visual($Window, [string]$Name) {
    if (-not $ScreenshotDirectory) { return }
    $Window.UpdateLayout()
    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new(
        [int]$Window.ActualWidth, [int]$Window.ActualHeight, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($Window)
    $png = [Windows.Media.Imaging.PngBitmapEncoder]::new()
    $png.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $file = [IO.File]::Create((Join-Path $ScreenshotDirectory ($Name + '.png')))
    try { $png.Save($file) } finally { $file.Dispose() }
}

function Invoke-RightClick($Element) {
    $event = [Windows.Input.MouseButtonEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice, 0, [Windows.Input.MouseButton]::Right)
    $event.RoutedEvent = [Windows.Input.Mouse]::PreviewMouseUpEvent
    $Element.RaiseEvent($event)
    if (-not $event.Handled) { throw 'Right click did not route to the browser Back action' }
}

function Assert-CaptionAlignment($Window) {
    $Window.UpdateLayout()
    $clock = $Window.FindName('ClockText')
    $clockCenter = $clock.TranslatePoint([Windows.Point]::new(0, $clock.ActualHeight / 2), $Window).Y
    foreach ($name in @('MinimizeButton','FullscreenButton','CloseWindowButton')) {
        $button = $Window.FindName($name)
        $buttonCenter = $button.TranslatePoint([Windows.Point]::new(0, $button.ActualHeight / 2), $Window).Y
        if ([Math]::Abs($buttonCenter - $clockCenter) -gt 0.5) { throw "$name is not aligned with the clock" }
    }
}

$state = @{stage = 0; failure = $null; expected = $null; checkFavorites = $CheckFavoritePicker.IsPresent; legacy = $Legacy.IsPresent; layout = $CheckLayout.IsPresent
    checkAccount = $CheckAccountProfile.IsPresent; withLauncherIcon = $withLauncherIcon
    mailbox = Join-Path ([IO.Path]::GetTempPath()) ('newbv-browser-test-' + [Guid]::NewGuid().ToString('N') + '.json')}
$ready = {
    param($Window)
    $state.window = $Window
    $state.timer = [Windows.Threading.DispatcherTimer]::new()
    $state.timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $state.deadline = [DateTime]::UtcNow.AddSeconds(30)
    $state.timer.add_Tick({
        $body = $state.window.FindName('Body')
        try {
            if ([DateTime]::UtcNow -gt $state.deadline) {
                throw ('Browser test timed out at stage ' + $state.stage + ': ' + $state.window.FindName('StatusText').Text)
            }
            if ($state.stage -eq 0) {
                $rail = $state.window.FindName('Sidebar')
                $header = $state.window.FindName('HeaderTabs')
                if ($header.Children.Count -ne 4 -and -not $state.homeRequested) {
                    $state.homeRequested = $true
                    $rail.Children[1].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                    return
                }
                if (-not $body.Children.Count -or $body.Children[0].Children.Count -lt 4) { return }
                $grid = $body.Children[0]
                if ($grid.Columns -ne 4) { throw 'Expected four columns' }
                if ($rail.Children.Count -ne 6 -or $header.Children.Count -ne 4) { throw 'Missing BBLL navigation tabs' }
                if ($state.checkAccount) {
                    $accountButton = $state.window.FindName('AccountButton')
                    $railAvatar = $accountButton.Content.Children | Select-Object -Last 1
                    $avatar = $railAvatar.Source
                    if (-not $avatar -or $avatar.IsDownloading -or $avatar.PixelWidth -le 0) { return }
                    $click = [Windows.Controls.Button]::ClickEvent
                    [void]$accountButton.Focus()
                    $accountButton.RaiseEvent([Windows.RoutedEventArgs]::new($click))
                    $overlay = $state.window.FindName('ProfileOverlay')
                    $profileAvatar = $state.window.FindName('ProfileAvatarImage')
                    if ($overlay.Visibility -ne 'Visible' -or $profileAvatar.Source -ne $avatar -or
                        $avatar.UriSource.Scheme -ne 'https' -or -not $avatar.UriSource.Host.EndsWith('.hdslb.com') -or
                        $state.window.FindName('ProfileLevel').Text -notmatch '^LV\d+$' -or
                        $state.window.FindName('ProfileCoins').Text -notmatch '\d+\.\d+' -or
                        $state.window.FindName('ProfileSpace').Visibility -ne 'Visible') { throw 'Invalid account profile data or avatar' }
                    foreach ($field in @('ProfileFollowing','ProfileFollowers','ProfileDynamics')) {
                        if ($state.window.FindName($field).Text -notmatch '^\d[\d,]*$') { throw "Missing account statistic: $field" }
                    }
                    $state.window.FindName('ProfileSession').RaiseEvent([Windows.RoutedEventArgs]::new($click))
                    $confirmation = $state.window.FindName('DialogOverlay')
                    $options = $state.window.FindName('DialogOptions')
                    if ($confirmation.Visibility -ne 'Visible' -or -not $options.Children[0].IsKeyboardFocused) {
                        throw 'Logout did not request confirmation with Cancel selected'
                    }
                    $options.Children[0].RaiseEvent([Windows.RoutedEventArgs]::new($click))
                    if ($confirmation.Visibility -ne 'Collapsed' -or $overlay.Visibility -ne 'Visible') { throw 'Cancel did not restore the account card' }
                    $escape = [Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice,
                        [Windows.PresentationSource]::FromVisual($state.window), 0, [Windows.Input.Key]::Escape)
                    $escape.RoutedEvent = [Windows.Input.Keyboard]::PreviewKeyDownEvent
                    $state.window.RaiseEvent($escape)
                    if ($overlay.Visibility -ne 'Collapsed' -or -not $accountButton.IsKeyboardFocused -or $body.Children[0] -ne $grid) {
                        throw 'Closing the profile did not restore the selection page and focus'
                    }
                    $state.checkAccount = $false
                }
                if ($state.layout) {
                    Assert-CaptionAlignment $state.window
                    $clock = $state.window.FindName('ClockText')
                    if ([Windows.Media.TextOptions]::GetTextRenderingMode($clock) -ne 'Auto' -or
                        [Windows.Media.TextOptions]::GetTextFormattingMode($clock) -ne 'Display' -or
                        [Windows.Media.TextOptions]::GetTextHintingMode($clock) -ne 'Fixed' -or
                        $clock.FontWeight -ne [Windows.FontWeights]::SemiBold -or
                        $state.window.FindName('ProfileName').FontWeight -ne [Windows.FontWeights]::Bold) {
                        throw 'The browser lost its display text rendering or existing font weights'
                    }
                    if ($state.withLauncherIcon -and $state.window.Icon.PixelWidth -ne 96) {
                        throw 'Optional application icon not loaded'
                    }
                    if (-not ($rail.Children[0].Content -is [Windows.UIElement])) { throw 'Sidebar icon is missing' }
                    $appId = [IntPtr]::Zero
                    $status = [NewBV.TaskbarIdentity]::GetCurrentProcessExplicitAppUserModelID([ref]$appId)
                    try {
                        if ($status -ne 0 -or [Runtime.InteropServices.Marshal]::PtrToStringUni($appId) -ne 'NativeWasmTv.NewBV.BBLLBrowser') {
                            throw 'Windows taskbar still identifies the browser as its host'
                        }
                    } finally { [Runtime.InteropServices.Marshal]::FreeCoTaskMem($appId) }
                    $state.window.FindName('SettingsButton').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                    $categories = $state.window.FindName('SettingsCategories')
                    $rows = $state.window.FindName('SettingsRows')
                    if ($state.window.FindName('SettingsView').Visibility -ne 'Visible' -or $categories.Children.Count -ne 5 -or
                        $rows.Children[0].ActualHeight -gt 68) { throw 'Invalid BBLL settings layout' }
                    Save-Visual $state.window 'settings'
                    $rows.Children[0].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                    $overlay = $state.window.FindName('DialogOverlay')
                    $card = $state.window.FindName('DialogCard')
                    $options = $state.window.FindName('DialogOptions')
                    $state.window.UpdateLayout()
                    if ($overlay.Visibility -ne 'Visible' -or $card.ActualWidth -ne 655 -or
                        $options.Children.Count -lt 8 -or $options.Children[0].Height -ne 72) { throw 'Invalid BBLL settings dialog' }
                    Save-Visual $state.window 'settings-dialog'
                    $selected = $options.Children | Where-Object { $_.IsKeyboardFocused } | Select-Object -First 1
                    if (-not $selected) { throw 'Setting dialog did not focus the selected option' }
                    $selected.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                    if ($overlay.Visibility -ne 'Collapsed') { throw 'Setting dialog did not dismiss' }
                    $categories.Children[1].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                    if ($rows.Children[2].Tag.key -ne 'audio') { throw 'Missing default audio setting' }
                    $categories.Children[2].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                    $danmakuKeys = $rows.Children | Where-Object { $_ -is [Windows.Controls.Button] } | ForEach-Object { $_.Tag.key }
                    if (($danmakuKeys -join ',') -ne 'danmaku,dmSize,dmOpacity,dmSpeed,dmArea,dmDensity,dmTop,dmBottom') {
                        throw 'Missing live danmaku settings'
                    }
                    $rows.Children[8].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                    if ($overlay.Visibility -ne 'Visible' -or $options.Children.Count -lt 6) { throw 'Missing danmaku area choices' }
                    Invoke-RightClick $options.Children[0]
                    if ($overlay.Visibility -ne 'Collapsed' -or $state.window.FindName('SettingsView').Visibility -ne 'Visible') {
                        throw 'Right click should dismiss only the frontmost dialog'
                    }
                    Invoke-RightClick $state.window.FindName('SettingsView')
                    if ($state.window.FindName('SettingsView').Visibility -ne 'Collapsed') { throw 'Right click did not close settings' }
                    $rail.Children[5].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                    Assert-CaptionAlignment $state.window
                    $label = $header.Children[4].Content.Children[0]
                    if ($label.Text -ne '稍后观看' -or $label.ActualWidth -lt 105 -or $label.TextTrimming -ne 'None') {
                        throw 'The four-character library tab was clipped'
                    }
                    $history = $header.Children[0].Content.Children[0]
                    $position = $history.TranslatePoint([Windows.Point]::new(0,0), $state.window)
                    if ($position.X -lt 80 -or $position.X -gt 90) { throw "Library labels are not left-aligned: $($position.X)" }
                    Save-Visual $state.window 'library-tabs'
                    $header.Children[4].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                    $state.window.UpdateLayout()
                    $later = $header.Children[4]
                    $line = $later.Content.Children[1]
                    if ($later.Background.Color.A -ne 255 -or $header.Children[0].Background.Color.A -ne 0 -or
                        $line.HorizontalAlignment -ne 'Center' -or $later.Content.Children[0].FontWeight -ne [Windows.FontWeights]::Bold) {
                        throw 'The selected tab did not retain its highlight and centered underline'
                    }
                    Save-Visual $state.window 'library-selection'
                    $rail.Children[1].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                }
                Save-Visual $state.window 'home'
                $state.stage++
                $rail.Children[0].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            } elseif ($state.stage -eq 1 -and $body.Children.Count -ge 3) {
                $keyboard = $body.Children[0].Children[0].Children[1]
                if ($keyboard.Columns -ne 3 -or $keyboard.Children.Count -ne 9) { throw 'Missing numeric search keyboard' }
                if ($body.Children[0].Children[1].Children.Count -lt 8) { return }
                Save-Visual $state.window 'search'
                $keyboard.Children[1].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                $keyboard.Children[1].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                $query = $state.window.FindName('HeaderTabs').Children[0].Children[0]
                if ($query.Text -ne 'A') { throw 'Multi-tap search input did not cycle' }
                $state.stage++
                $state.window.FindName('Sidebar').Children[1].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            } elseif ($state.stage -eq 2 -and $body.Children.Count -eq 1 -and $body.Children[0].Children.Count -ge 4) {
                $grid = $body.Children[0]
                $state.expected = $grid.Children[0].Tag.item.url
                $state.stage++
                $grid.Children[0].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            } elseif ($state.stage -eq 3 -and $body.Children.Count -ge 5) {
                $parts = $body.Children[3]
                if (-not $parts.Children.Count) { throw 'No playable video parts' }
                $actions = $body.Children[4].Children
                if ($actions[0].Content -ne '稍后再看' -or $actions[0].Tag.value -notmatch '^later:\d+$' -or
                    $actions[1].Content -ne '收藏' -or $actions[1].Tag.action -ne 'favorite-folders') {
                    throw 'Missing watch-later or favorite shortcut.'
                }
                Save-Visual $state.window 'detail'
                if ($state.layout) {
                    $commentButton = $actions | Where-Object { $_.Content -eq '评论' } | Select-Object -First 1
                    $state.stage = 8
                    $commentButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                } elseif ($state.checkFavorites) {
                    $state.stage = 4
                    $actions[1].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                } else { $state.stage = 6 }
            } elseif ($state.stage -eq 4 -and $state.window.FindName('HeaderTabs').Children[0].Text -eq '选择收藏夹') {
                $row = $body.Children[1]
                if ($row.Children[1].Tag.value -notmatch '^favorite:\d+:\d+:add$') { throw 'Invalid favorite folder action.' }
                $state.stage = 5
                $body.Children[0].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            } elseif ($state.stage -eq 5 -and $body.Children.Count -ge 5) {
                if ($body.Children[4].Children[1].Content -ne '收藏') { throw 'Returning from the folder picker did not restore details.' }
                $state.stage = 6
            } elseif ($state.stage -eq 8 -and $body.Children.Count -eq 2 -and $body.Children[1].Children.Count -ge 3) {
                $list = $body.Children[1]
                $first = $list.Children[0]
                $state.window.UpdateLayout()
                if ($list -isnot [Windows.Controls.StackPanel] -or $first.Content.Children[0].Width -ne 44 -or
                    $first.ActualHeight -le 0 -or $body.Children[0].Children[2].Content -ne '最新') { throw 'Invalid comment list' }
                Save-Visual $state.window 'comments'
                Invoke-RightClick $first
                $state.stage = 9
            } elseif ($state.stage -eq 9 -and $body.Children.Count -ge 5) {
                $state.stage = 6
            } elseif ($state.stage -eq 6) {
                $part = $body.Children[3].Children[0]
                if ($state.legacy) {
                    $state.stage = 7
                    $state.timer.Stop()
                    $part.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                    if ($state.window.IsVisible) { throw 'Legacy mpv must receive the selection on process exit.' }
                    return
                }
                $part.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                $first = [IO.File]::ReadAllText($state.mailbox) | ConvertFrom-Json
                if ($first.sequence -ne 1 -or -not $state.window.IsVisible -or $body.Children[3].Children[0] -ne $part) {
                    throw 'First play did not preserve the browser and its current page.'
                }
                $part.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                $state.selection = [IO.File]::ReadAllText($state.mailbox) | ConvertFrom-Json
                if ($state.selection.sequence -ne 2 -or -not $state.window.IsVisible) { throw 'The browser did not accept a second selection.' }
                $state.stage = 7
                $state.timer.Stop()
                if ($state.layout) {
                    $fullscreen = $state.window.FindName('FullscreenButton')
                    $minimize = $state.window.FindName('MinimizeButton')
                    $close = $state.window.FindName('CloseWindowButton')
                    $original = $state.window.WindowState
                    $glyph = $fullscreen.Content
                    $expected = if ($original -eq 'Maximized') { 'Normal' } else { 'Maximized' }
                    $click = [Windows.Controls.Button]::ClickEvent
                    $fullscreen.RaiseEvent([Windows.RoutedEventArgs]::new($click))
                    if ($state.window.WindowState -ne $expected -or $fullscreen.Content -eq $glyph) { throw 'Fullscreen button did not toggle' }
                    $minimize.RaiseEvent([Windows.RoutedEventArgs]::new($click))
                    if ($state.window.WindowState -ne 'Minimized') { throw 'Minimize button did not minimize' }
                    $state.window.WindowState = $expected
                    $fullscreen.RaiseEvent([Windows.RoutedEventArgs]::new($click))
                    if ($state.window.WindowState -ne $original) { throw 'Fullscreen button did not restore' }
                    $close.RaiseEvent([Windows.RoutedEventArgs]::new($click))
                    if ($state.window.IsVisible) { throw 'Close button did not close the selection window' }
                } else { $state.window.Close() }
            }
        } catch {
            $state.failure = $_.Exception.Message + "`n" + $_.ScriptStackTrace
            $state.timer.Stop()
            $state.window.Close()
        }
    })
    $state.timer.Start()
}.GetNewClosure()
try {
    if ($Legacy) { $legacySelection = & $browser -OnReady $ready | ConvertFrom-Json }
    else { $null = & $browser -OnReady $ready -PlayMailbox $state.mailbox }
}
finally { [IO.File]::Delete($state.mailbox); [IO.File]::Delete($state.mailbox + '.tmp') }
if ($state.failure) { throw $state.failure }
$data = if ($Legacy) { $legacySelection } else { $state.selection }
if ($state.stage -ne 7 -or $data.action -ne 'play' -or
    -not ([string]$data.url).StartsWith($state.expected + '?p=') -or
    $data.url -notin @($data.queue | ForEach-Object { $_.url })) {
    throw "Browser did not return the selected video part (stage $($state.stage), action '$($data.action)')."
}
if ($Legacy) { 'NewBV browser returned playback JSON to a legacy mpv instance.' }
else { 'NewBV browser navigation, detail and repeat playback without closing passed.' }
if ($CheckAccountProfile) { 'NewBV loaded the signed-in avatar in the sidebar and profile card, and restored focus after closing.' }
