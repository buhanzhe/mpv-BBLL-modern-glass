$script:signInState = $null
foreach ($name in @('SignInOverlay','SignInHeader','SignInImage','SignInStatus','SignInCancel','SignInCheck','SignInRetry')) {
    Set-Variable -Name $name -Value ($window.FindName($name))
}

function Set-SignInImage([string[]]$Rows) {
    $modules = $Rows.Count
    if ($modules -lt 21 -or $modules -gt 177 -or ($modules - 21) % 4 -ne 0) { return $false }
    $size = $modules + 8
    $pixels = [byte[]]::new($size * $size)
    for ($i = 0; $i -lt $pixels.Length; $i++) { $pixels[$i] = 255 }
    for ($y = 0; $y -lt $modules; $y++) {
        $row = $Rows[$y]
        if ($row.Length -ne $modules -or $row -notmatch '^[01]+$') { return $false }
        for ($x = 0; $x -lt $modules; $x++) {
            if ($row[$x] -eq '1') { $pixels[($y + 4) * $size + $x + 4] = 0 }
        }
    }
    $bitmap = [Windows.Media.Imaging.BitmapSource]::Create($size, $size, 96, 96,
        [Windows.Media.PixelFormats]::Gray8, $null, $pixels, $size)
    $bitmap.Freeze()
    $SignInImage.Width = $size * [Math]::Floor(326 / $size)
    $SignInImage.Height = $SignInImage.Width
    $SignInImage.Source = $bitmap
    return $true
}

function Request-BrowserSignIn {
    $SignInImage.Source = $null
    $SignInCheck.IsEnabled = $false
    $SignInRetry.Visibility = 'Collapsed'
    $SignInStatus.Text = '正在获取二维码…'
    [void]$SignInCancel.Focus()
    if (-not $PlayMailbox) {
        $SignInStatus.Text = '请从 mpv 打开选片窗口后扫码。'
        return
    }
    $script:signInState.sequence = Finish 'signin'
    if (-not $script:signInState.sequence) {
        $SignInStatus.Text = '无法连接 mpv，请重试。'
        $SignInRetry.Visibility = 'Visible'
    }
}

function Open-BrowserSignIn($Context = $null) {
    if ($script:signInState) { return }
    $script:signInState = @{context = $Context; focus = [Windows.Input.Keyboard]::FocusedElement}
    $SignInOverlay.Visibility = 'Visible'
    Request-BrowserSignIn
}

function Close-BrowserSignIn([switch]$Completed) {
    $state = $script:signInState
    if (-not $state) { return }
    $script:signInState = $null
    $SignInOverlay.Visibility = 'Collapsed'
    $SignInImage.Source = $null
    if ($state.focus) { [void]$state.focus.Focus() }
    if ($state.sequence -and -not $Completed) { Finish 'cancel-signin' }
}

function Update-BrowserSignIn($Update) {
    $state = $script:signInState
    if (-not $state -or -not $state.sequence -or $state.sequence -ne $Update.sequence) { return }
    if ($Update.state -eq 'ready' -and (Set-SignInImage $Update.rows)) {
        $SignInCheck.IsEnabled = $true
        $SignInStatus.Text = '请用哔哩哔哩 App 扫码'
        [void]$SignInCheck.Focus()
        return
    }
    if ($Update.state -eq 'waiting') {
        $SignInStatus.Text = '等待扫码，请打开哔哩哔哩 App。'
        return
    }
    if ($Update.state -eq 'scanned') {
        $SignInStatus.Text = '已扫码，请在手机上确认'
        return
    }
    if ($Update.state -eq 'success') {
        Close-BrowserSignIn -Completed
        Sync-AccountProfile -Refresh
        if ($state.context.value -and [object]::ReferenceEquals($script:page, $state.context.page)) {
            Submit-VideoAction $state.context.value -Retried
        } elseif ($state.context.refresh) {
            if ([object]::ReferenceEquals($script:page, $state.context.page)) { Refresh-Page }
        } else { Show-Status '登录成功。' }
        return
    }
    $state.sequence = $null
    $SignInImage.Source = $null
    $SignInCheck.IsEnabled = $false
    $SignInStatus.Text = switch ($Update.state) {
        'expired' { '二维码已过期，请重新生成。' }
        'cancelled' { '扫码已取消，可以重新生成。' }
        'credentials_missing' { 'B 站未返回完整登录凭据，请重新扫码。' }
        default { '无法获取或确认二维码，请重试。' }
    }
    $SignInRetry.Visibility = 'Visible'
    [void]$SignInRetry.Focus()
}

function Invoke-BrowserSignInKey($Event) {
    $Event.Handled = $true
    $buttons = @(@($SignInCancel, $SignInCheck, $SignInRetry) | Where-Object { $_.IsVisible -and $_.IsEnabled })
    $focused = [Windows.Input.Keyboard]::FocusedElement
    $index = [Array]::IndexOf($buttons, $focused)
    if ($Event.Key -in @('Tab','Left','Right','Up','Down')) {
        $step = if ($Event.Key -in @('Left','Up') -and $index -ge 0) { -1 } else { 1 }
        [void]$buttons[($index + $step + $buttons.Count) % $buttons.Count].Focus()
    } elseif ($Event.Key -in @('Return','Space')) {
        $buttons[[Math]::Max(0, $index)].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    }
}

$SignInCancel.add_Click({ Close-BrowserSignIn })
$SignInCheck.add_Click({ Finish 'check-signin' })
$SignInRetry.add_Click({ Request-BrowserSignIn })
