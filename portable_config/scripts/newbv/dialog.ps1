$script:dialogState = $null

function Close-BbllDialog {
    $state = $script:dialogState
    if (-not $state) { return }
    $script:dialogState = $null
    $DialogOverlay.Visibility = 'Collapsed'
    $DialogOptions.Children.Clear()
    if ($state.focus) { [void]$state.focus.Focus() }
}

function Show-BbllDialog([string]$Title, [object[]]$Choices, [int]$Selected = 0, [scriptblock]$Apply, $Context, [string]$Message = '') {
    if (-not $Choices.Count) { return }
    if ($script:dialogState) { Close-BbllDialog }
    $script:dialogState = @{apply = $Apply; context = $Context; focus = [Windows.Input.Keyboard]::FocusedElement; buttons = @()}
    $DialogCard.Width = [Math]::Max(1, [Math]::Min(655, $window.ActualWidth - 24))
    $DialogCard.MaxHeight = [Math]::Max(80, [Math]::Min(636, $window.ActualHeight - 36))
    $DialogTitle.Text = $Title
    if ($Message) {
        $bodyText = New-Text $Message 21 $normal
        $bodyText.Margin = [Windows.Thickness]::new(36,0,36,16)
        $bodyText.TextWrapping = 'Wrap'
        [void]$DialogOptions.Children.Add($bodyText)
    }
    foreach ($item in $Choices) {
        $button = [Windows.Controls.Button]::new()
        $button.Style = $window.FindResource('DialogOption')
        $button.Content = [string]$item.text
        $button.Tag = $item
        $button.add_Click({
            param($sender, $event)
            $state = $script:dialogState
            if (-not $state) { return }
            Close-BbllDialog
            if ($state.apply) { & $state.apply $sender.Tag $state.context }
        })
        $button.add_GotKeyboardFocus({ param($sender, $event) $sender.BringIntoView() })
        [void]$DialogOptions.Children.Add($button)
        $script:dialogState.buttons += $button
    }
    $DialogOverlay.Visibility = 'Visible'
    $DialogScroll.ScrollToTop()
    $DialogCard.UpdateLayout()
    [void]$script:dialogState.buttons[[Math]::Min($Choices.Count - 1, [Math]::Max(0, $Selected))].Focus()
}

function Invoke-BbllDialogKey($Event) {
    $Event.Handled = $true
    $buttons = $script:dialogState.buttons
    $focused = [Windows.Input.Keyboard]::FocusedElement
    $index = [Array]::IndexOf($buttons, $focused)
    if ($Event.Key -in @('Up','Down','Tab')) {
        $previous = $Event.Key -eq 'Up' -or ($Event.Key -eq 'Tab' -and
            (([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Shift) -ne 0))
        $target = if ($index -lt 0) { 0 } elseif ($Event.Key -eq 'Tab') {
            ($index + $(if ($previous) { -1 } else { 1 }) + $buttons.Count) % $buttons.Count
        } elseif ($previous) { [Math]::Max(0, $index - 1) }
        else { [Math]::Min($buttons.Count - 1, $index + 1) }
        [void]$buttons[$target].Focus()
    } elseif ($Event.Key -in @('Return','Space') -and $index -ge 0) {
        $focused.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    }
}

$DialogOverlay.add_MouseLeftButtonDown({
    param($sender, $event)
    if ($event.OriginalSource -eq $sender) { Close-BbllDialog }
})
