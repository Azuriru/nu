. "$PSScriptRoot\timefns.ps1"

function Assert-Equal($a, $b, $msg) {
    if ($a -ne $b) { throw "Assertion failed: $msg (Got: $a, Expected: $b)" }
}

# Basic seconds
$t = Parse-TimeToken "42"
Assert-Equal $t.Hours 0 "Hours default to 0"
Assert-Equal $t.Minutes 0 "Minutes default to 0"
Assert-Equal $t.Seconds 42 "Seconds parsed"
Assert-Equal $t.Millis 0 "Millis default to 0"

# Seconds.millis
$t = Parse-TimeToken "5.25"
Assert-Equal $t.Seconds 5 "Seconds correct"
Assert-Equal $t.Millis 250 "Millis scaled to 3 digits"

# hh:mm:ss.zzz
$t = Parse-TimeToken "1:02:03.045"
Assert-Equal $t.Hours 1 "Hours parsed"
Assert-Equal $t.Minutes 2 "Minutes parsed"
Assert-Equal $t.Seconds 3 "Seconds parsed"
Assert-Equal $t.Millis 45 "Millis parsed as 045 → 45"

Write-Host "Parse-TimeToken tests passed"

$t = [pscustomobject]@{ Hours=0; Minutes=0; Seconds=59; Millis=1200 }
$t = Normalize-Time $t
Assert-Equal $t.Seconds 0 "Millis carry to next second"
Assert-Equal $t.Minutes 1 "Seconds overflow → minutes"

$t = [pscustomobject]@{ Hours=1; Minutes=0; Seconds=-1; Millis=0 }
$t = Normalize-Time $t
Assert-Equal $t.Minutes 59 "Borrow from hours → minutes"
Assert-Equal $t.Hours 0 "Borrowed hour decremented"

Write-Host "Normalize-Time tests passed"

$t = [pscustomobject]@{ Hours=0; Minutes=0; Seconds=5; Millis=20; Meta=@{ ColonCount=0; HasDot=$true } }
$s = Format-Time $t $t.Meta
Assert-Equal $s "5.020" "Basic seconds.millis formatted"

$t = [pscustomobject]@{ Hours=1; Minutes=2; Seconds=3; Millis=4; Meta=@{ ColonCount=2; HasDot=$true } }
$s = Format-Time $t $t.Meta
Assert-Equal $s "1:02:03.004" "hh:mm:ss.zzz format padded"

Write-Host "Format-Time tests passed"

$text = "Jump to 00:01:02.500 now"
$tok = Find-TimeToken $text 12  # cursor inside "01"
Assert-Equal $tok.Text "00:01:02.500" "Token matched correctly"
Assert-Equal $tok.Segments.Count 4 "Segments: hh, mm, ss, zzz"

Write-Host "Find-TimeToken tests passed"

$tok = Find-TimeToken "00:01:02.500" 4   # inside "01"
$unit = Map-CaretToUnit $tok 4
Assert-Equal $unit "minutes" "Caret in minutes"

$tok = Find-TimeToken "00:01:02.500" 10  # inside "500"
$unit = Map-CaretToUnit $tok 10
Assert-Equal $unit "millis" "Caret in milliseconds"

Write-Host "Map-CaretToUnit tests passed"
