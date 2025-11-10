use ../scripts/_vid.nu *
use ../scripts/_dev.nu *
use ../scripts/_sqlite.nu *
use ../scripts/_combinators.nu *
use ../scripts/_forms.nu *

# tested on 6:52 65mib 24fps 1080p 9911 frames video
# | p  |   ssim   |   time    | fps |
# | -- | -------- | --------- | --- |
# | 13 | 0.993780 | 1m 8.9s   | 145 |
# | 12 | 0.993777 | 1m 8.2s   | 145 |
# | 11 | 0.993777 | 1m 8.8s   | 145 |
# | 10 | 0.993774 | 1m 9.5s   | 143 | 2-pass 1080p runtime plateau (~500fps 1st + ~200fps 2nd)
# |  9 | 0.994713 | 1m 26.1s  | 114 | Significantly reduced spurious blocking
# |  8 | 0.995800 | 2m 13.0s  | 74  | Starts matching precise target birate (250fps 1st pass)
# |  7 | 0.996164 | 3m 1.8s   | 54  |
# |  6 | 0.996476 | 4m 31.5s  | 36  |
# |  5 | 0.996712 | 6m 3.1s   | 27  |
# |  4 | 0.996923 | 9m 26.7s  | 17  | Threshold for ultra low bitrates and lower resolutions
# |  3 | 0.997030 | 17m 42.3s | 9.3 |
# |  2 | 0.997160 | 37m 13.5s | 4.4 |
# |  1 | 0.997313 | 75m 22.4s | 2.1 | Probably as low as you want to go, but going lower can help
# |  0 | 0.997390 | 196m 54s  | 0.8 |
def main [ file: string ] {
    let paths = collate $file --wait 150ms --interval 55ms | sort-by value -i

    let db_path = $nu.temp-path | path join cutav1.db
    sqlite init $db_path [
        "
            CREATE TABLE IF NOT EXISTS key_values (
                key TEXT PRIMARY KEY,
                value TEXT
            )
        "
    ]

    if ($paths | is-empty) {
        return
    }

    let lastconf = open $db_path | query db "SELECT * FROM key_values" | transpose -rd

    let defaults = if ($paths | length) != 1 or $lastconf.path? != $paths.0.value {
        {}
    } else {
        $lastconf
    }

    $env.config.filesize.unit = 'binary'

    let xy = parallel [
        { $paths.value | par-each { |path| ls -D $path | get 0.size } }
        { $paths.value | par-each { |path| vid get-meta $path } }
    ]
    let stats = $xy.0
    let metas = $xy.1
    let max_filesize = $stats | math max
    let max_duration = $metas.duration | math max
    let title = if ($paths | length) > 1 {
        $"AV1 \(($paths | length) videos)"
    } else {
        "AV1"
    }

    let arrow_code = '
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
    '

    let formatted_duration = vid _format-duration $max_duration --trim --optmillis

    let responses = ps-form --title $title --questions [
        {
            key: 'start',
            type: 'text',
            label: 'Start time',
            default: ($defaults.start? | default '0:00'),
            autofocus: true,
            postnew: $arrow_code
        },
        {
            key: 'end',
            type: 'text',
            label: 'End time',
            default: ($defaults.end? | default $formatted_duration), # '1:00:00'
            postnew: ($arrow_code | str replace -a "$startTextBox" "$endTextBox")
        },
        {
            key: 'size',
            type: 'number',
            label: 'Target size in MB',
            # todo: instead of this, could store the last target size and use that
            default: ($defaults.size? | default (if $max_filesize < 50mib { 10 } else { 50 })),
            step: 1,
            decimals: 1,
            max: 10000,
            preinit: $'$videoLengthSec = ($max_duration / 1sec)',
            postnew: '$sizeNumeric.Add_TextChanged({ $sizeLabel.Text = "Target size in MB ($([Math]::Round($sizeNumeric.Value * 1024 * 1024 * 8 / $videoLengthSec / 1000, 1))kbit)" })'
        },
        {
            key: 'preset',
            type: 'number',
            label: 'Encoder preset',
            default: ($defaults.preset? | default 8),
            max: 12
        },
        {
            key: 'maxres',
            type: 'number',
            label: 'Max res',
            default: ($defaults.maxres? | default 1080),
            max: (1080 * 8)
        }
    ]

    if $responses == null {
        return
    }

    let defaultend = get-param-default "vid 2p av1" end

    let start = $responses.start
    let end = if $responses.end == $formatted_duration {
        $defaultend
    } else {
        $responses.end
    }
    let size = $responses.size * 1mib
    let preset = $responses.preset
    let maxres = $responses.maxres

    let endstr = if $end == $defaultend {
        ':END:'
    } else {
        $end
    }

    print $"Svt av1 encoding at preset ($preset) targeting ($size | into string) from ($start) to ($endstr)"

    open $db_path | query db "REPLACE INTO key_values (key, value) VALUES (?, ?)" -p ['start', $start]
    open $db_path | query db "REPLACE INTO key_values (key, value) VALUES (?, ?)" -p ['end', $responses.end]
    open $db_path | query db "REPLACE INTO key_values (key, value) VALUES (?, ?)" -p ['size', $responses.size]
    open $db_path | query db "REPLACE INTO key_values (key, value) VALUES (?, ?)" -p ['preset', $preset]
    open $db_path | query db "REPLACE INTO key_values (key, value) VALUES (?, ?)" -p ['maxres', $maxres]

    for path in $paths.value {
        open $db_path | query db "REPLACE INTO key_values (key, value) VALUES (?, ?)" -p ['path', $path]

        vid 2p av1 $path $size --start $start --end $end --preset $preset --count --max $maxres
    }
}
