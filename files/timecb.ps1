. "$env:NU_ROOT\files\timefns.ps1"

$__key__TextBox.Add_TextChanged({ param($sender, $e)
    $previewPictureBox.ImageLocation = $previewPictureBox.ImageLocation
    $__key__TextBox.Text | Out-File -FilePath $env:TEMP\modal_timecode.txt
})

$__key__TextBox.Add_KeyDown({
    param($sender, $e)

    if (@("Up", "Down") -notcontains $e.KeyCode) { return }
    $e.SuppressKeyPress = $true

    $pos = $__key__TextBox.SelectionStart
    $selLen = $__key__TextBox.SelectionLength
    $text = $__key__TextBox.Text

    # only bump if selection is within a single numeric segment
    if ($selLen -gt 0 -and ($text.Substring($pos, $selLen) -match '[^0-9]')) { return }

    $tokenInfo = Find-TimeToken $text $pos
    if (-not $tokenInfo) { return }

    $t = Parse-TimeToken $tokenInfo.Text
    $unit = Map-CaretToUnit $tokenInfo $pos

    $bump = 1

    if (($unit -eq 'millis') -and -not ($e.Control -or $e.Shift -or $e.Alt)) {
        $bump = 10
    }

    if ($e.KeyCode -eq 'Down') {
        $bump *= -1
    }

    switch ($unit) {
        'hours'   { $t.Hours += $bump }
        'minutes' { $t.Minutes += $bump }
        'seconds' { $t.Seconds += $bump }
        'millis'  { $t.Millis += $bump }
    }

    $min = $null
    $max = Parse-TimeToken $VIDEO_END

    if ("__key__" -eq "start") {
        $max = Parse-TimeToken $endTextBox.Text
    } else {
        $min = Parse-TimeToken $startTextBox.Text
    }

    $t = Normalize-Time $t $min $max
    $newToken = Format-Time $t $t.Meta

    $newText = $text.Substring(0, $tokenInfo.Start) + $newToken + $text.Substring($tokenInfo.Start + $tokenInfo.Length)
    $__key__TextBox.Text = $newText

    Update-CaretSelection $__key__TextBox $tokenInfo $unit $newToken
})
