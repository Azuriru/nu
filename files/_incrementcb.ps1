
$startTextBox.Add_KeyDown({ param($sender, $e)
    if (@("Up", "Down") -contains $e.KeyCode) {
        $e.SuppressKeyPress = $true

        $pos = $startTextBox.SelectionStart
        $text = $startTextBox.Text

        if ($text.Substring($pos, $startTextBox.SelectionLength) -match "\D") {
            return
        }

        $matches = [regex]::Matches($text, "\d+")
        foreach ($m in $matches) {
            if ($pos -ge $m.Index -and $pos -le ($m.Index + $m.Length)) {
                # Caret is inside this match
                $num = [int]$m.Value

                if ($e.KeyCode -eq "Up") {
                    $num++
                } else {
                    $num--
                }

                $num = [Math]::Max(0, $num)
                if ($pos -gt 0) {
                    $num = $num.ToString().PadLeft(2, '0')
                }

                $newText = $text.Substring(0, $m.Index) + $num + $text.Substring($m.Index + $m.Length)
                $startTextBox.Text = $newText

                $startTextBox.SelectionStart = $m.Index
                $startTextBox.SelectionLength = $num.ToString().Length

                break
            }
        }
    }
})
