function Find-TimeToken {
    param([string]$text, [int]$pos)

    $pattern = '\d+(?::\d+){0,2}(?:\.\d{1,3})?'
    $matches = [regex]::Matches($text, $pattern)
    foreach ($m in $matches) {
        if ($pos -ge $m.Index -and $pos -le ($m.Index + $m.Length)) {
            # Build digit segments with their start positions
            $segments = @()
            $i = 0
            while ($i -lt $m.Value.Length) {
                if ($m.Value[$i] -match '\d') {
                    $start = $i
                    $s = ""
                    while ($i -lt $m.Value.Length -and $m.Value[$i] -match '\d') {
                        $s += $m.Value[$i]; $i++
                    }
                    $segments += @{ Text = $s; Start = $start }
                } else { $i++ }
            }

            return [pscustomobject]@{
                Text     = $m.Value
                Start    = $m.Index
                Length   = $m.Length
                Segments = $segments
                HasDot   = ($m.Value.Contains('.'))
            }
        }
    }

    return $null
}

function Parse-TimeToken {
    param([string]$token)

    $colonParts = $token -split ':'
    if ($colonParts.Length -gt 3) {
        $colonParts = $colonParts[($colonParts.Length - 3)..($colonParts.Length - 1)]
    }

    $lastPart = $colonParts[-1]
    $msPart = $null
    $secondsPart = $lastPart
    if ($lastPart.Contains('.')) {
        $split = $lastPart.Split('.', 2)
        $secondsPart = $split[0]
        $msPart = $split[1]
    }

    $hours = 0; $minutes = 0; $seconds = 0; $millis = 0
    switch ($colonParts.Length) {
        1 { $seconds = [int]$secondsPart }
        2 { $minutes = [int]$colonParts[0]; $seconds = [int]$secondsPart }
        3 { $hours = [int]$colonParts[0]; $minutes = [int]$colonParts[1]; $seconds = [int]$secondsPart }
    }

    if ($msPart) {
        if ($msPart.Length -lt 3) { $millis = [int]($msPart.PadRight(3, '0')) }
        else { $millis = [int]$msPart }
    }

    return [pscustomobject]@{
        Hours   = $hours
        Minutes = $minutes
        Seconds = $seconds
        Millis  = $millis
        Meta    = @{
            ColonCount = ($colonParts.Length - 1)
            HasDot     = [bool]$msPart
        }
    }
}

function Normalize-Time {
    param(
        [pscustomobject]$t,
        [pscustomobject]$MinTime = $null,
        [pscustomobject]$MaxTime = $null
    )

    # Carry / borrow logic identical to original
    if ($t.Millis -lt 0) {
        $borrow = [math]::Ceiling(([math]::Abs($t.Millis) + 999) / 1000)
        $t.Seconds -= $borrow
        $t.Millis += $borrow * 1000
    }
    if ($t.Millis -gt 999) {
        $carry = [math]::Floor($t.Millis / 1000)
        $t.Seconds += $carry
        $t.Millis = $t.Millis % 1000
    }

    if ($t.Seconds -lt 0) {
        $borrow = [math]::Ceiling(([math]::Abs($t.Seconds) + 59) / 60)
        $t.Minutes -= $borrow
        $t.Seconds += $borrow * 60
    }
    if ($t.Seconds -gt 59) {
        $carry = [math]::Floor($t.Seconds / 60)
        $t.Minutes += $carry
        $t.Seconds = $t.Seconds % 60
    }

    if ($t.Minutes -lt 0) {
        $borrow = [math]::Ceiling(([math]::Abs($t.Minutes) + 59) / 60)
        $t.Hours -= $borrow
        $t.Minutes += $borrow * 60
    }
    if ($t.Minutes -gt 59) {
        $carry = [math]::Floor($t.Minutes / 60)
        $t.Hours += $carry
        $t.Minutes = $t.Minutes % 60
    }

    if ($t.Hours -lt 0) { $t.Hours=0; $t.Minutes=0; $t.Seconds=0; $t.Millis=0 }

    # clamp
    function ToMs($x) { ($x.Hours*3600000) + ($x.Minutes*60000) + ($x.Seconds*1000) + $x.Millis }

    $total = ToMs $t
    if ($MinTime) { $total = [math]::Max($total, (ToMs $MinTime)) }
    if ($MaxTime) { $total = [math]::Min($total, (ToMs $MaxTime)) }

    # back to fields
    $t.Hours   = [math]::Floor($total / 3600000)
    $total    %= 3600000
    $t.Minutes = [math]::Floor($total / 60000)
    $total    %= 60000
    $t.Seconds = [math]::Floor($total / 1000)
    $t.Millis  = $total % 1000

    return $t
}

function Format-Time {
    param(
        [pscustomobject]$t,
        [hashtable]$meta
    )

    $colonCount = $meta.ColonCount
    $hasDot = $meta.HasDot

    if ($colonCount -eq 2 -or $t.Hours -gt 0) {
        $h = $t.Hours
        $m = $t.Minutes.ToString().PadLeft(2, '0')
        $s = $t.Seconds.ToString().PadLeft(2, '0')
        $out = "${h}:${m}:${s}"
    } elseif ($colonCount -eq 1 -or $t.Minutes -gt 0) {
        $m = $t.Minutes
        $s = $t.Seconds.ToString().PadLeft(2, '0')
        $out = "${m}:${s}"
    } else {
        $out = $t.Seconds.ToString()
    }

    if ($hasDot -or $t.Millis -ne 0) {
        $out += "." + $t.Millis.ToString().PadLeft(3, '0')
    }

    return $out
}

function Map-CaretToUnit {
    param([pscustomobject]$tokenInfo, [int]$pos)

    $rel = $pos - $tokenInfo.Start
    $segIndex = $null
    for ($i=0; $i -lt $tokenInfo.Segments.Count; $i++) {
        $s = $tokenInfo.Segments[$i]
        if ($rel -ge $s.Start -and $rel -le ($s.Start + $s.Text.Length)) {
            $segIndex = $i; break
        }
    }

    # Guess units based on token structure
    $token = $tokenInfo.Text
    $colonParts = $token -split ':'
    $hasDot = $tokenInfo.HasDot
    $units = @()

    switch ($colonParts.Length) {
        1 { if ($hasDot -and $token -match '\.') { $units += 'seconds','millis' } else { $units += 'seconds' } }
        2 { $units += 'minutes','seconds'; if ($hasDot) { $units += 'millis' } }
        3 { $units += 'hours','minutes','seconds'; if ($hasDot) { $units += 'millis' } }
    }

    if ($segIndex -ge $units.Count) { $segIndex = $units.Count - 1 }
    return $units[$segIndex]
}

function Update-CaretSelection {
    param(
        $textBox,
        [pscustomobject]$tokenInfo,
        [string]$unit,
        [string]$newToken
    )

    # rebuild segment positions for new token
    $newSegs = @()
    $i=0
    while ($i -lt $newToken.Length) {
        if ($newToken[$i] -match '\d') {
            $start=$i; $s=""
            while ($i -lt $newToken.Length -and $newToken[$i] -match '\d') {
                $s+=$newToken[$i];$i++
            }
            $newSegs+=$(@{Text=$s;Start=$start})
        } else {$i++}
    }

    # map to same unit type
    $parts = $newToken -split ':'
    $hasDot = $newToken.Contains('.')
    $uMap=@()
    switch ($parts.Length) {
        1 { if ($hasDot){$uMap+='seconds','millis'} else{$uMap+='seconds'} }
        2 { $uMap+='minutes','seconds'; if ($hasDot){$uMap+='millis'} }
        3 { $uMap+='hours','minutes','seconds'; if ($hasDot){$uMap+='millis'} }
    }

    $idx = ($uMap.IndexOf($unit))
    if ($idx -lt 0) { $idx = 0 }
    $selStart = $tokenInfo.Start + $newSegs[$idx].Start
    $selLen   = $newSegs[$idx].Text.Length
    $textBox.SelectionStart = $selStart
    $textBox.SelectionLength = $selLen
}
