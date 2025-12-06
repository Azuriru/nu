use ../scripts/_vid.nu *
use ../scripts/_combinators.nu *
use ../scripts/_sqlite.nu *
use ../scripts/_forms.nu *

const CURRENT_PATH = path self

# Attach on postinit so TextChanged doesn't fire when initializing the default value
let arrow_code = open ($CURRENT_PATH | path dirname | path join timecb.ps1)

def update-screencap [ path: string, time: string, preview_path: string ] {
    # NOTE: for -ss, this will include the captured frame. For -to, it will **not**
    ffmpeg -ss $time -i $path -frames:v 1 -update 1 -y $preview_path o+e>| ignore
}

def main [ file: string ] {
    let paths = collate $file --wait 150ms --interval 55ms | sort-by value -i

    if ($paths | is-empty) {
        return
    }

    let db_path = $nu.temp-path | path join togif.db
    let timecode_path = $nu.temp-path | path join modal_timecode.txt
    let preview_path = $nu.temp-path | path join modal_preview.jpg

    touch $timecode_path
    sqlite init $db_path [
        "
            CREATE TABLE IF NOT EXISTS key_values (
                key TEXT PRIMARY KEY,
                value TEXT
            )
        "
    ]

    let lastconf = open $db_path | query db "SELECT * FROM key_values" | transpose -rd

    let defaults = if ($paths | length) != 1 or $lastconf.path? != $paths.0.value {
        {}
    } else {
        $lastconf
    }

    if ($paths | length) == 1 {
        update-screencap $paths.0.value ($defaults.start? | default 0 | into string) $preview_path
    }

    let metas = $paths.value | par-each { |path| vid get-meta $path }
    let max_duration = $metas.duration | math max

    let formatted_duration = vid _format-duration $max_duration

    let watcher_id = job spawn {
        watch -q $timecode_path | reduce -f null { |_, last|
            try {
                let lines = open $timecode_path | decode utf-8 | lines | str trim
                let timecode = $lines.0?
                let path = $lines.1?

                if $timecode == $last {
                    return $last
                }

                print $timecode
                update-screencap $paths.0.value $timecode $preview_path

                return $timecode
            } catch { |e|
                print -e $e

                return null
            }
        }
    }

    $env.config.filesize.unit = 'binary'
    let responses = (ps-form
        --title "Video to gif"
        --options {
            preinit: $'$VIDEO_END = "($formatted_duration)"; $VIDEO_PATH = "($paths.0.value)";'
        }
        --questions [
            (if ($paths | length) == 1 {
                {
                    key: 'preview',
                    type: 'picture'
                }
            }),
            {
                type: 'row-start'
            },
            {
                key: 'start',
                type: 'text',
                label: 'Start time',
                default: ($defaults.start? | default '0:00'),
                autofocus: true,
                width: 134,
                postinit: ($arrow_code | str replace -a "__key__" "start")
            },
            {
                key: 'end',
                type: 'text',
                label: 'End time',
                default: ($defaults.end? | default $formatted_duration), # '1:00:00'
                width: 134,
                postinit: ($arrow_code | str replace -a "__key__" "end")
            },
            {
                type: 'row-end'
            },
            {
                key: 'palette',
                type: 'dropdown',
                label: 'Palette type',
                options: [
                    { label: 'Global', value: 'global' },
                    { label: 'Per-frame', value: 'frame' }
                ],
                default: ($defaults.palette? | default 0)
            },
            {
                key: 'dithering',
                type: 'dropdown',
                label: 'Dithering',
                options: [
                    { label: 'None', value: 'none' },
                    { label: 'Atkinson', value: 'atkinson' },
                    # Looks great for being basic, deterministic, and fast, but has obvious matrix pattern
                    # Only when viewed from afar, it's really gross when zoomed in
                    { label: 'Bayer', value: 'bayer' },
                    { label: 'Burkes', value: 'burkes' },
                    { label: 'Floyd/Steinberg', value: 'floyd_steinberg' },
                    { label: 'Heckbert', value: 'heckbert' }, # 'considered wrong', works pretty well
                    { label: 'Sierra2', value: 'sierra2' },
                    { label: 'Sierra2_4a', value: 'sierra2_4a' }, # ffmpeg default; good at its job
                    { label: 'Sierra3' value: 'sierra3' }
                ],
                default: ($defaults.dithering? | default 7)
            },
            {
                key: 'loops',
                type: 'number',
                label: 'Loop count (-1 = never, 0 = infinite)',
                default: ($defaults.loops? | default 0),
                min: -1,
                max: 65535
            },
            {
                key: 'maxres',
                type: 'number',
                label: 'Max res',
                default: ($defaults.maxres? | default 512),
                max: (1080 * 8)
            }
        ]
    )

    if $responses == null {
        return
    }

    print $responses

    open $db_path | query db "REPLACE INTO key_values (key, value) VALUES (?, ?)" -p ['start', $responses.start]
    open $db_path | query db "REPLACE INTO key_values (key, value) VALUES (?, ?)" -p ['end', $responses.end]
    open $db_path | query db "REPLACE INTO key_values (key, value) VALUES (?, ?)" -p ['palette', $responses.palette_index]
    open $db_path | query db "REPLACE INTO key_values (key, value) VALUES (?, ?)" -p ['dithering', $responses.dithering_index]
    open $db_path | query db "REPLACE INTO key_values (key, value) VALUES (?, ?)" -p ['loops', $responses.loops]
    open $db_path | query db "REPLACE INTO key_values (key, value) VALUES (?, ?)" -p ['maxres', $responses.maxres]

    for path in $paths.value {
        open $db_path | query db "REPLACE INTO key_values (key, value) VALUES (?, ?)" -p ['path', $path]

        (vid to-gif $path
            --start $responses.start
            --end $responses.end
            --height $responses.maxres
            --loops $responses.loops
            --framepalettes=($responses.palette != 'global')
            --dither $responses.dithering
        )
    }
}
