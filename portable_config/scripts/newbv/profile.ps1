$script:profile = $null
$script:profileFocus = $null
$script:profileStamp = $null
$profileSessionPath = Get-SessionPath
foreach ($name in @('ProfileOverlay','ProfileAvatar','ProfileAvatarImage','ProfileName','ProfileDetails','ProfileVip',
        'ProfileLevelBadge','ProfileLevel','ProfileCoins','ProfileFollowing','ProfileFollowers','ProfileDynamics',
        'ProfileStatus','ProfileSpace','ProfileSession')) {
    Set-Variable -Name $name -Value ($window.FindName($name))
}

function Initialize-AccountProfile {
    $railAvatar = [Windows.Controls.Grid]::new()
    $railAvatar.Width = 33
    $railAvatar.Height = 33
    $railAvatar.Clip = [Windows.Media.EllipseGeometry]::new([Windows.Point]::new(16.5,16.5),16.5,16.5)
    foreach ($container in @($railAvatar, $ProfileAvatar)) {
        $placeholder = New-Icon 'default_avatar' ([int]$container.Width)
        if (-not $placeholder) { $placeholder = New-Icon 'icon_user' ([int]$container.Width) }
        if ($placeholder) { $container.Children.Insert(0, $placeholder) }
    }
    $script:railAvatarImage = [Windows.Controls.Image]::new()
    $script:railAvatarImage.Stretch = 'UniformToFill'
    [void]$railAvatar.Children.Add($script:railAvatarImage)
    $AccountButton.Content = $railAvatar
    $AccountButton.ToolTip = 'B 站账号'
    [Windows.Automation.AutomationProperties]::SetName($AccountButton, 'B 站账号')
}

function Set-AccountAvatar([string]$Url) {
    $source = $script:railAvatarImage.Source
    if ($source -and $source.UriSource.AbsoluteUri -eq $Url) { return }
    $source = $null
    if ($Url) {
        try {
            $source = (New-Image $Url 'UniformToFill' 264).Source
            $source.add_DownloadFailed({
                param($sender, $event)
                if ($script:railAvatarImage.Source -eq $sender) {
                    $script:railAvatarImage.Source = $null
                    $ProfileAvatarImage.Source = $null
                }
            })
        } catch { $source = $null }
    }
    $script:railAvatarImage.Source = $source
    $ProfileAvatarImage.Source = $source
}

function Format-ProfileNumber($Value, [string]$Format) {
    if ($null -eq $Value) { return '—' }
    $Value.ToString($Format, [Globalization.CultureInfo]::GetCultureInfo('zh-CN'))
}

function Render-AccountProfile {
    $account = $script:profile
    $signedIn = $account.state -eq 'signed_in'
    Set-AccountAvatar $account.avatar
    $ProfileName.Text = switch ($account.state) {
        'signed_in' { $account.name }
        'signed_out' { '未登录' }
        default { 'B 站账号' }
    }
    $ProfileDetails.Visibility = if ($signedIn) { 'Visible' } else { 'Collapsed' }
    $ProfileVip.Visibility = if ($signedIn -and $account.vip) { 'Visible' } else { 'Collapsed' }
    $ProfileLevelBadge.Visibility = if ($null -ne $account.level) { 'Visible' } else { 'Collapsed' }
    $ProfileLevel.Text = 'LV' + $account.level
    $ProfileCoins.Text = '硬币数：' + (Format-ProfileNumber $account.coins '0.0#')
    $ProfileFollowing.Text = Format-ProfileNumber $account.following 'N0'
    $ProfileFollowers.Text = Format-ProfileNumber $account.followers 'N0'
    $ProfileDynamics.Text = Format-ProfileNumber $account.dynamics 'N0'
    $ProfileStatus.Text = switch ($account.state) {
        'signed_in' { '' }
        'signed_out' { '扫码登录后查看账号资料' }
        'error' { '暂时无法读取账号资料' }
        default { '正在读取账号资料…' }
    }
    $ProfileStatus.Visibility = if ($signedIn) { 'Collapsed' } else { 'Visible' }
    $ProfileSpace.Visibility = if ($signedIn -and $account.id -gt 0) { 'Visible' } else { 'Collapsed' }
    $ProfileSession.IsEnabled = [bool]$account.state -and $requests.account.action -ne 'logout'
    $ProfileSession.Content = switch ($account.state) {
        'signed_in' { '退出登录' }
        'signed_out' { '扫码登录' }
        'error' { '重试' }
        default { '请稍候' }
    }
    $ProfileSession.Foreground = if ($signedIn) { [Windows.Media.Brushes]::Tomato } else { $normal }
}

function Reset-AccountPages {
    foreach ($key in @($pageCache.Keys)) {
        if ($key -like 'mine:*' -or $key -like 'dynamic:*') { $pageCache.Remove($key) }
    }
    if ($script:page.id -in @('detail','actions') -and $script:page.rail -in @('mine','dynamic')) {
        $stack.Clear()
        return
    }
    if ($script:page.rail -eq 'mine') {
        if ($script:page.standalone) { Open-Section $sections[5] }
        else { Open-Section $script:page 'mine' $true }
    }
    if ($script:page.rail -eq 'dynamic') { Open-Section $sections[3] }
}

function Sync-AccountProfile([switch]$Refresh) {
    if ($requests.account.action -eq 'logout') { return }
    $stamp = [IO.File]::GetLastWriteTimeUtc($profileSessionPath).Ticks
    if ($stamp -eq $script:profileStamp -and (-not $Refresh -or $requests.account)) { return }
    if ($stamp -ne $script:profileStamp) {
        $script:profile = $null
        if ($null -ne $script:profileStamp) { Reset-AccountPages }
        $script:profileStamp = $stamp
    }
    Render-AccountProfile
    Invoke-Request 'profile' '' 1 {
        param($result, $context)
        if ($context.stamp -ne [IO.File]::GetLastWriteTimeUtc($profileSessionPath).Ticks) {
            Sync-AccountProfile
            return
        }
        if ($result.state -in @('signed_in','signed_out')) { $script:profile = $result }
        elseif (-not $script:profile) { $script:profile = @{state = 'error'} }
        Render-AccountProfile
    } @{stamp = $stamp} 'account'
}

function Open-AccountProfile {
    if ($ProfileOverlay.Visibility -eq 'Visible') { return }
    $script:profileFocus = [Windows.Input.Keyboard]::FocusedElement
    $ProfileOverlay.Visibility = 'Visible'
    [void]$ProfileOverlay.Focus()
    if ($script:profile.state -eq 'error') { $script:profile = $null }
    Sync-AccountProfile -Refresh
}

function Close-AccountProfile {
    if ($ProfileOverlay.Visibility -ne 'Visible') { return }
    $ProfileOverlay.Visibility = 'Collapsed'
    if ($script:profileFocus) { [void]$script:profileFocus.Focus() }
    $script:profileFocus = $null
}

function Invoke-AccountProfileKey($Event) {
    $Event.Handled = $true
    $buttons = @(@($ProfileSpace,$ProfileSession) | Where-Object { $_.IsVisible -and $_.IsEnabled })
    if (-not $buttons.Count) { return }
    $focused = [Windows.Input.Keyboard]::FocusedElement
    $index = [Array]::IndexOf($buttons, $focused)
    if ($Event.Key -in @('Tab','Left','Right','Up','Down')) {
        if ($index -lt 0) { [void]$buttons[0].Focus() }
        else { [void]$buttons[($index + 1) % $buttons.Count].Focus() }
    } elseif ($Event.Key -in @('Return','Space')) {
        $buttons[[Math]::Max(0, $index)].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    }
}

$ProfileOverlay.add_MouseLeftButtonDown({
    param($sender, $event)
    if ($event.OriginalSource -eq $sender) { Close-AccountProfile }
})

$ProfileSpace.add_Click({
    $id = [string]$script:profile.id
    if ($id -notmatch '^[1-9][0-9]{0,18}$') { return }
    try { Start-Process ('https://space.bilibili.com/' + $id) -ErrorAction Stop }
    catch {
        $ProfileStatus.Text = '无法打开个人空间'
        $ProfileStatus.Visibility = 'Visible'
    }
})

$ProfileSession.add_Click({
    switch ($script:profile.state) {
        'signed_out' { Open-BrowserSignIn }
        'error' { $script:profile = $null; Sync-AccountProfile -Refresh }
        'signed_in' {
            Show-BbllDialog '退出登录' @(@{text='取消'}, @{text='退出登录'; confirm=$true}) 0 {
                param($choice, $context)
                if (-not $choice.confirm) { return }
                Invoke-Request 'logout' '' 1 {
                    param($result, $context)
                    if ($result.state -ne 'signed_out') {
                        Render-AccountProfile
                        $ProfileStatus.Text = '退出失败，请重试'
                        $ProfileStatus.Visibility = 'Visible'
                        return
                    }
                    $script:profileStamp = [IO.File]::GetLastWriteTimeUtc($profileSessionPath).Ticks
                    $script:profile = $result
                    Reset-AccountPages
                    Render-AccountProfile
                } $null 'account'
                Render-AccountProfile
            }
        }
    }
})
