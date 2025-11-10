use _combinators.nu *
use _dev.nu *
use _term.nu *
use _mutex.nu *
use _ssh.nu *
use _path.nu *

const NANOSECONDS_IN_SECOND = 1000000000

export def 'vid get-streams' [
    file_path: path
] {
    let ffprobe_results = do {
        let res = ffprobe -v error -show_entries 'format:stream' $file_path | complete

        echo $res

        if ("stderr" in $res and $res.stderr != "") or $res.exit_code != 0 {
            print "Error or warnings while probing file."
            print $"Path: ($file_path)"
            print $"Exit code: ($res.exit_code)"
            print $"Stderr:\n($res.stderr)"
        }

        $res | get stdout
    }
    let sections = $ffprobe_results | parse -r '\[([A-Z]+?)\]([\s\S]*?)\[/\1\]' | rename section_name props | upsert props {
        $in | lines | str trim | where $it != "" | split column '=' key value | transpose -rd
    }

    $sections
}

export def 'vid get-meta' [
    file_path: path
] {
    let streams = vid get-streams $file_path
    let format = $streams | where section_name == FORMAT | first | get props
    let video = $streams | where section_name == STREAM and props.codec_type == video | get 0?.props
    let dimensions = $streams | where { |r|
        $r.section_name == "STREAM" and "width" in $r.props and "height" in $r.props
    } | get 0?.props

    $format | select duration size bit_rate
        | upsert duration { into float | $in * 1sec }
        | upsert bit_rate { into filesize }
        | upsert size { into filesize }
        | then $dimensions { |dims|
            insert height ($dims.height | into int)
            | insert width ($dims.width | into int)
        }
        | then ($format | get -o "TAG:comment") { |comment| insert comment $comment }
        | then $video { |v|
            insert vcodec $v.codec_name
            | insert frames { |r|
                try {
                    $v.nb_frames | into int
                } catch {
                    # approximate
                    $r.duration / 1sec * 30 | math floor
                }
            }
            | insert fps { |r| $r.frames / ($r.duration / 1sec) }
            | insert fps_ratio ($v.r_frame_rate | split row '/')
        }
}

export def 'vid audio-stream-size' [
    path: path
    --format: string = "matroska" # Container format to use (like ogg, mp3, adts, matroska). Matroska is very flexible
] {
    ffmpeg -v warning -i $path -vn -acodec copy -f $format - | length | into filesize
}

export def 'vid size-report' [
    --glob: string = "**/*.{mp4,webm,mkv,avi,m4v,mpg,wmv,flv,mov}",
    --min-per-ten: filesize = 0b
    --min-size: filesize = 0b
    --threads: int = 16
    --limit: int = 5000
    --audio
    --raw
] {
    let results = glob $glob
        | par-each -t $threads { |path|
            vid get-meta $path
            | upsert size { |row| if $audio { vid audio-stream-size $path } else { $row.size }}
            | upsert per_ten { |row| $row.size / ($row.duration | into int | $in / 1000000000) * 600 }
            | upsert path { $path }
        }
        | sort-by per_ten
        | where per_ten >= $min_per_ten
        | where size >= $min_size
        | last $limit

    if $raw {
        $results
    } else {
        $results | each { |file|
            let parsed = $file.path | path parse
            print $"(ansiwrap blue $parsed.parent)/(ansiwrap yellow ($file.path | path basename))\nSize: (ansiwrap red ($file.size | to text)) \(10min: (ansiwrap green ($file.per_ten | to text))\)"
        }
    }
}

export def 'vid get-default-scaling' [
    path: path,
    --max: int = 1080
] {
    let meta = vid get-meta $path
    let max_height = if $meta.width >= $meta.height {
        [$meta.height, $max] | math min
    } else {
        # -2 to scale to multiples of 2 for derived aspect ratio resolution
        # Used to return null, -2 is more convenient, and always defaulted to that
        # Keep this file clean if returned to null
        -2
    }
    let max_width = if $meta.height > $meta.width {
        [$meta.width, $max] | math min
    } else {
        -2
    }

    # print $"max-h: ($max_height) max-w: ($max_width)"

    {
        max_width: $max_width,
        max_height: $max_height
    }
}

export def 'vid compare-frame' [
    a: path
    b: path
] {
    # -lavfi ssim for the comparison, scaling dance if they're different sizes
    let stderr = ffmpeg -i $a -i $b -lavfi "[1:v]scale=rw:rh[resized];[0:v][resized]ssim" -f null - | complete | get stderr

    try {
        $stderr | parse -r 'All:(\d\S+)' | get capture0.0 | into float
    } catch { |e|
        print -e $stderr
    }
}

export def 'vid compare-frames' [
    a: path
    ...others: path
    --frames: int = 3000
] {
    if ($others | is-empty) {
        error make {
            msg: 'Comparison paths is empty'
        }
    }

    const FRAME_SLICE = 5
    const RANGE_START = 0 # 0-indexed
    const RANGE_END = $FRAME_SLICE - 1 # inclusive frame 0-indexed range for between()
    const MIDDLE = $FRAME_SLICE / 2 | math floor # Still 0-indexed

    mkdir cmp

    let filter = "select='between(mod(n,300),$min,$max)*lt(n,$frames)',setpts=N/FRAME_RATE/TB"
    let fa = $filter | str replace '$min' $"($RANGE_START)" | str replace '$max' $"($RANGE_END)" | str replace '$frames' $"($frames)"
    let fb = $filter | str replace '$min' $"($MIDDLE)" | str replace '$max' $"($MIDDLE)" | str replace '$frames' $"($frames)"
    let to = $frames / 20 # assume 24 fps baseline; read this with ffprobe later
    let chars = seq char b z

    ffmpeg -ss 0 -to $to -i $a -vf $fa -fps_mode vfr cmp/a_%03d.png
    # ffmpeg -ss 0 -to $to -i $b -vf $fb -fps_mode vfr cmp/b_%03d.png
    for other in ($others | enumerate) {
        ffmpeg -ss 0 -to $to -i $other.item -vf $fb -fps_mode vfr $"cmp/($chars | get $other.index)_%03d.png"
    }

    glob cmp/b_*.png | each { |path|
        try {
            let index = $path | parse -r '_(\d+).png' | get 0.capture0 | into int
            # File naming index that starts at 1 is very annoying for the intersection math
            let index = $index - 1

            let other_start = $index * $FRAME_SLICE
            let mid = $other_start + $MIDDLE

            let candidates = $other_start..<($other_start + $FRAME_SLICE) | par-each -k { |n|
                let name = $"cmp/a_($n + 1 | fill -a r -c 0 -w 3).png"
                let score = (vid compare-frame $name $path) - ($n - $mid | math abs) * 0.000001
                let score = $score | math round -p 6

                return { score: $score, name: $name }
            } | enumerate | sort-by item.score index -r

            let best = $candidates | first

            print -e $"Best score: ($best | get item.score | fill -a l -w 10) Worst score: ($candidates | last | get item.score | fill -a l -w 10) Jitter: ($best.index - $MIDDLE | math abs)"

            cp $best.item.name $"./cmp/($index).a.png"
            # cp $path $"./cmp/($index).($bn).png"
            for other in ($others | enumerate) {
                let chr = $chars | get $other.index
                cp ($path | str replace -r 'b(?=_\d+\.)' $chr) $"./cmp/($index).($chr).png"
            }
        } catch { |e| print -e $e }
    }

    rm cmp/?_*.png
}

export def 'vid _format-duration' [
    duration
    --trim
    --optmillis
] {
    let hours = $duration / 1hr | math floor
    let duration = $duration - $hours * 1hr
    let minutes = $duration / 1min | math floor
    let duration = $duration - $minutes * 1min
    let seconds = $duration / 1sec | math floor
    let duration = $duration - $seconds * 1sec
    let millis = $duration / 1ms | math floor

    mut units = [
        ($hours | fill -w 2 -c 0 -a r),
        ($minutes | fill -w 2 -c 0 -a r),
        ($seconds | fill -w 2 -c 0 -a r)
    ] | skip while { |seg| $seg == '00' } | str join ':' | default -e '0'

    if $trim {
        $units = $units | str trim -l -c 0
    }

    if $optmillis and $millis == 0 {
        $"($units)"
    } else {
        $"($units).($millis | fill -w 3 -c 0 -a r)"
    }
}

# 8 0.970231 (+0.000000) (45sec 323ms)       (x1.000) (2.647x) (0.38x of runtime)
# 7 0.970826 (+0.000595) (59sec 560ms)       (x1.314) (2.014x) (0.5x of runtime)
# 6 0.973855 (+0.003029) (1min 21sec 844ms)  (x1.374) (1.466x) (0.68x of runtime)
# 5 0.973906 (+0.000051) (2min 6sec 324ms)   (x1.543) (0.949x) (1.05x of runtime)
# 4 0.975350 (+0.001444) (3min 47sec 333ms)  (x1.799) (0.527x) (1.89x of runtime)
# 3 0.975607 (+0.000256) (6min 58sec 119ms)  (x1.839) (0.286x) (3.48x of runtime)
# 2 0.976522 (+0.000914) (11min 22sec 811ms) (x1.633) (0.175x) (5.69x of runtime)
# 1 0.977456 (+0.000933) (26min 2sec 304ms)  (x2.288) (0.076x) (13.02x of runtime)

# Get latest ffmpeg build that includes svt 3.0 for a cool 15-35% speedup
#
# SSIM scores for presets (2min, 1080p, 30fps):
# | p | ssim     | time              | fps |
# | - | -------- | ----------------- | --- |
# | 1 | 0.975715 | 29m 3.9s (14.53x) | 2   |
# | 2 | 0.975    | 10m 53.5s (5.45x) | 5   |
# | 3 | 0.975352 | 6m 57s (3.48x)    | 8   |
# | 4 | 0.974002 | 3m 19.1s (1.66x)  | 18  |
# | 5 | 0.972721 | 1m 41.6s (0.85x)  | 35  |
# | 6 | 0.970879 | 1m 0.6s (0.51x)   | 59  |
# | 7 | 0.9694   | 49.6s (0.41x)     | 72  |
# | 8 | 0.962884 | 30s (0.25x)       | 119 |
# | 9 | 0.959705 | 22.8s (0.19x)     | 157 |
# | - | -------- | ----------------- | --- |
export def 'vid av1' [
    path: path
    --crf: int
    --preset: int = 6
    --audio-bitrate(-a): oneof<filesize, int> = 96kb
    --video-bitrate: filesize = 1.5mb # Variable bitrate, maps to --maxrate
    --verbosity: string = 'warning'
    --bin: string = "ffmpeg"
    --start: string = "0"
    --end: string = "10000000"
    --max: int = 1080
    --fps: int
    --overlays
    --scd
    --10bit
    --rm
    --filter: string
] {
    if $path =~ '\.min\.' {
        print (ansiwrap yellow $"Skipping ($path | path basename): looks already compressed")
        return
    }

    let stat = ls -D $path | first
    let scale = vid get-default-scaling $path --max=$max
    let target = vid get-default-filename $path --ext mp4
    let target_path = $path | path parse | get parent | path join $target
    if ($target_path | path exists) {
        print (ansiwrap yellow $"Skipping ($path | path basename): already compressed")
        return
    }

    # Total bitrate is video + audio bitrate, `maxrate` is just for the crf video encoder
    let video_bitrate = $video_bitrate | into int
    let audio_bitrate = $audio_bitrate | into int

    $env.SVT_LOG = 2 # Set to 3 to print encoder info

    mut log = $"Encoding (ansiwrap default_reverse ($path | path basename)): initial size (ansiwrap light_blue ($stat.size | into string))"

    try {
        let source_meta = vid get-meta $path
        let res = [$source_meta.width, $source_meta.height] | math min

        $log += $", duration (ansiwrap light_green (vid _format-duration $source_meta.duration)), "
        $log += (ansiwrap light_green $"($res)p") + ", "
        $log += (ansiwrap light_green $"($source_meta.fps | math round)fps")
    }

    print $log

    let video_filter = if $filter != null {
        $filter
    } else {
        $"scale=($scale.max_width):($scale.max_height)"
    }

    (^$bin
        -v $verbosity
        -stats
        -stats_period 0.2
        -y
        ...(if $start != "0" or $end != "10000000" { [-ss $start -to $end] } else { [] })
        -i $path
        -c:v libsvtav1
        -preset $preset
        ...(if $fps != null { [-r $fps]} else { [] })
        ...(if $crf != null { [-crf $crf] } else { [] }) # svt defaults to 35
        ...(if $10bit { [-pix_fmt yuv420p10le] } else { [-pix_fmt yuv420p] }) # 10bit is ~15% slower, but people seem to like it? it can also be a bit smaller
        # VQ over PSNR. I can't tell the difference, but it seems faster
        # consider: enable-overlays=1, slows down a little, improves quality considerably, but with larger file sizes
        # consider: scm=1, slows down considerably, smaller file sizes
        # consider: scd=1, except svt av1 warns when using it
        -svtav1-params $'tune=0:enable-overlays=($overlays | into int):scd=($scd | into int)'
        -metadata $"comment='Encoded from video of size ($stat.size | into string)'"
        # -g 300 # Keyframe interval, leave it default
        ...(if $video_bitrate > 0 { [
            -maxrate ($video_bitrate | $in / 1000 | $"($in)K")
            -bufsize ($video_bitrate | $in / 250 | $"($in)K")
        ] } else { [] })
        -vf $video_filter
        ...(if $audio_bitrate > 0 { [ -c:a libopus -b:a $audio_bitrate ] } else { [ '-an' ]})
        $target_path
    )

    let final_stat = ls -D $target_path | first

    let saved = $stat.size - $final_stat.size
    let color = if $saved > 0kb { 'green' } else { 'red' }
    let percentage = $final_stat.size / $stat.size * 100 | math round -p 1

    print $"Encoded (ansiwrap yellow_bold ($target | path basename)): final size (ansiwrap light_blue ($final_stat.size | into string)), saved (ansiwrap $color $saved), (ansiwrap light_blue $percentage)% of initial"

    if $rm and $saved > 0kb {
        rm $path
    }
}

export def yuv-pipe [
    path: string,
    scale: record<max_height: int, max_width: int> = { max_height: -1, max_width: -1 }
    --start: string = "0"
    --end: string = "10000000"
    --fps: int
] {
    mut video_filter = $"scale=($scale.max_width):($scale.max_height)"
    if $fps != null {
        $video_filter += $",fps=($fps)"
    }
    (ffmpeg
        -v warning
        -stats
        # TODO: Do like with vcut an option to put the -to to a -t after the -i for some compat issues
        ...(if $start != "0" or $end != "10000000" { [-ss $start -to $end] } else { [] })
        -i $path
        -map 0:v:0
        -vf $video_filter
        -pix_fmt yuv420p
        -f yuv4mpegpipe
        -strict -1
        -an
        -
    )
}

# Defines how much it can overshoot the bitrate assigned - it shouldn't matter for 2-pass, but it does
# It makes it (a tiny bit) more aggressive in spiking the bitrate. It's still good w/o this
const OVERSHOOT_PCT_PERCENT = 100
const RC_VBR = 1

export def 'vid 2p av1' [
    path: path
    target_size: filesize = 10mib
    --preset(-p): int = 4
    --audio-bitrate(-a): oneof<filesize, int>
    --max: int # The max dimensions of the smaller side (vertical for landscape, horizontal for portrait)
    --log-level: int = 1 # Set to 3 to print encoder info. SvtApp has useless, irremediable warnings
    --tune: int = 0 # 0: vq, 1: psnr, 2: ssim
    --tbr: filesize # Override total bitrate - ignores target_size parameter. Bytes interpreted as bits (1mb = 1mbit)
    --start: string = "0"
    --end: string = "10000000"
    --scd # Setting scd makes svt complain (but it always does)
    --rm
    --overwrite
    --count
] {
    def svt-app-2p [
        pass: int
        fps_ratio: list
        video_bitrate_kbits: int
        keyint: int
        target_stat: string
        target_ivf?: string
    ] {
        # We can do both passes in one invocation, but I don't know the implications on quality or mem/disk usage. It seems to be fine
        # Just set --passes to 2 (instead of --pass) and pass an output ivf path
        (SvtAv1EncApp
            -i stdin
            --rc $RC_VBR
            --tune $tune
            --progress 0
            # --lookahead 42 # It warns us if we don't force it to 42
            --scd ($scd | into int)
            --overshoot-pct $OVERSHOOT_PCT_PERCENT
            --fps-num $fps_ratio.0
            --fps-denom $fps_ratio.1
            --tbr $video_bitrate_kbits
            --preset $preset
            --keyint $keyint
            --pass $pass
            --stats $target_stat
            ...(if $target_ivf != null { [ -b $target_ivf ] } else { [] })
        ) e>| ignore
    }

    if $path =~ '\.min\.' {
        print (ansiwrap yellow $"Skipping ($path | path basename): looks already compressed")
        return
    }

    $env.SVT_LOG = $log_level

    # SVT vbr is really good at matching it as long as it's not unreasonable (bitrate for scale, or fast preset)
    # Faster presets (9+) can even be kinda bad and undershoot it by as much as 20%, giving us a 1.2 threshold
    let fallibility_threshold = if $preset <= 4 { 0.99 } else { 0.98 }

    let target = path interject $path min --ext mp4 --count=$count
    # let target = vid get-default-filename $path --ext mp4
    let target_ivf = vid get-default-filename $path --ext ivf
    let target_stat = vid get-default-filename $path --ext stat
    if ($target | path exists) and not ($overwrite or $count) {
        print (ansiwrap yellow $"Skipping ($path | path basename): already compressed")
        return
    }

    let meta = vid get-meta $path
    let start_time = parse-time $start
    let end_time = [(parse-time $end), ($meta.duration / 1sec)] | math min
    let duration_s = $end_time - $start_time

    let target_bitrate_bits = $tbr | default ($target_size / $duration_s * 8) | into int
    let audio_bitrate_bits = $audio_bitrate | default (match $target_bitrate_bits {
        0..<120000 => 0, # Sub 120kbps for total bit stream - we're so cooked, strip audio
        120000..<300000 => 32000,
        300000..<900000 => 64000,
        _ => 96000
    }) | into int
    let video_bitrate_kbits = ($target_bitrate_bits - $audio_bitrate_bits) / 1000 * $fallibility_threshold | math floor
    let max_res = $max | default (match $video_bitrate_kbits {
        # "real" bitrate floors:
        # 200-140kbps for 1080p video, depending on preset and complexity
        # 120-90kbps for 720p video, depending on preset and complexity
        # 75-55kbit for 480p video, depending on preset and complexity
        # (... but this is just a heuristic, and I choose the values)
        0..120 => 480,
        120..300 => 720,
        _ => 1080
    })
    print $max
    print $max_res
    let scale = vid get-default-scaling $path --max $max_res

    # GOP/keyframes; -2 for default of ~5 secs
    # "it is recommended to have keyint be a multiple of 32 + 1 (225 or 257 for instance) to respect the mini-gop structure."
    # I can't speak to its impact on quality, but it seems to measurably improve encode time
    let keyint = 289

    print $"($scale.max_width):($scale.max_height); ($target_bitrate_bits / 1000)kbit: ($audio_bitrate_bits / 1000) audio, ($video_bitrate_kbits) video; ($keyint) keyint"

    # SvtAv1EncApp calls take -w/-h for input stream, but seems to ignore it. We have to scale when piping it yuv stream
    # https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/svt-av1_encoder_user_guide.md

    # Pipe for stats.
    yuv-pipe $path $scale --start $start --end $end | svt-app-2p 1 $meta.fps_ratio $video_bitrate_kbits $keyint $target_stat

    # Second pass (it can't have 3 passes, thankfully, despite what the user guide says)
    yuv-pipe $path $scale --start $start --end $end | svt-app-2p 2 $meta.fps_ratio $video_bitrate_kbits $keyint $target_stat $target_ivf

    # Move ivf to new container
    (ffmpeg
        -v warning
        -i $target_ivf
        ...(if $start != "0" or $end != "10000000" { [-ss $start -to $end] } else { [] })
        -i $path
        -map 0:v
        -c:v copy
        # We could've done the audio transcode in parallel before, but it's fast enough... maybe as fast as I/O
        ...(if $audio_bitrate_bits > 0 { [ -map 1:a:0? -c:a libopus -b:a $audio_bitrate_bits -af 'aformat=channel_layouts=stereo|mono' ] } else { [ -an ] })
        -y
        $target
    )

    let final_size = ls -D $target | first | get size
    print $"Final size: ($final_size | into string)"

    rm $target_ivf $target_stat
    if $rm {
        rm $path
    }
}

export def 'vid av1 crf' [
    path: path
    --crf: int = 35
    --video-bitrate = 1.5mb
    --preset(-p): int = 6
    --audio-bitrate(-a): oneof<filesize, int>
    --max: int # The max dimensions of the smaller side (vertical for landscape, horizontal for portrait)
    --log-level: int = 1 # Set to 3 to print encoder info. SvtApp has useless, irremediable warnings
    --tune: int = 0 # 0: vq, 1: psnr, 2: ssim
    --start: string = "0"
    --end: string = "10000000"
    --scd # Setting scd makes svt complain (but it always does)
    --rm
    --overwrite
    --count

    # path: path
    # --crf: int
    # --preset: int = 6
    # --audio-bitrate(-a): oneof<filesize, int> = 96kb
    # --video-bitrate: filesize = 1.5mb # Variable bitrate, maps to --maxrate
    # --verbosity: string = 'warning'
    # --bin: string = "ffmpeg"
    # --start: string = "0"
    # --end: string = "10000000"
    # --max: int = 1080
    # --fps: int
    # --10bit
    # --rm
    # --filter: string
] {
    def svt-app-1p [
        fps_ratio: list
        video_bitrate_kbits: int
        keyint: int
        target_stat: string
        target_ivf?: string
    ] {
        (SvtAv1EncApp
            -i stdin
            --passes 1
            --tune $tune
            --progress 0
            --crf $crf
            # --lookahead 42 # It warns us if we don't force it to 42
            --scd ($scd | into int)
            --overshoot-pct $OVERSHOOT_PCT_PERCENT
            --fps-num $fps_ratio.0
            --fps-denom $fps_ratio.1
            --rc $RC_VBR
            # note: capped crf uses mbr, not tbr
            # set video-bitrate to 0 for uncapped crf, as some videos break the encoder on capped crf
            ...(if $video_bitrate_kbits > 0 { [-mbr $video_bitrate_kbits ]} else { [] })
            --preset $preset
            --keyint $keyint
            ...(if $target_ivf != null { [ -b $target_ivf ] } else { [] })
        ) #e>| ignore
    }

    $env.SVT_LOG = $log_level

    let target = path interject $path min --ext mp4 --count=$count
    # let target = vid get-default-filename $path --ext mp4
    let target_ivf = vid get-default-filename $path --ext ivf
    let target_stat = vid get-default-filename $path --ext stat
    if ($target | path exists) and not ($overwrite or $count) {
        print (ansiwrap yellow $"Skipping ($path | path basename): already compressed")
        return
    }

    let meta = vid get-meta $path
    let start_time = parse-time $start
    let end_time = [(parse-time $end), ($meta.duration / 1sec)] | math min
    let duration_s = $end_time - $start_time

    let target_bitrate_bits = $video_bitrate | into int
    let audio_bitrate_bits = $audio_bitrate | default 96000 | into int
    let video_bitrate_kbits = $target_bitrate_bits / 1000 | math floor
    let max_res = $max | default 1080
    let scale = vid get-default-scaling $path --max $max_res

    # GOP/keyframes; -2 for default of ~5 secs
    # "it is recommended to have keyint be a multiple of 32 + 1 (225 or 257 for instance) to respect the mini-gop structure."
    # I can't speak to its impact on quality, but it seems to measurably improve encode time
    let keyint = 289

    print $"($scale.max_width):($scale.max_height); ($target_bitrate_bits / 1000)kbit: ($audio_bitrate_bits / 1000) audio, ($video_bitrate_kbits) video; ($keyint) keyint"

    yuv-pipe $path $scale --start $start --end $end | svt-app-1p $meta.fps_ratio $video_bitrate_kbits $keyint $target_stat $target_ivf

    # Move ivf to new container
    (ffmpeg
        -v warning
        -i $target_ivf
        ...(if $start != "0" or $end != "10000000" { [-ss $start -to $end] } else { [] })
        -i $path
        -map 0:v
        -c:v copy
        # We could've done the audio transcode in parallel before, but it's fast enough... maybe as fast as I/O
        ...(if $audio_bitrate_bits > 0 { [ -map 1:a:0? -c:a libopus -b:a $audio_bitrate_bits -af 'aformat=channel_layouts=stereo|mono' ] } else { [ -an ] })
        -y
        $target
    )

    let final_size = ls -D $target | first | get size
    print $"Final size: ($final_size | into string)"

    rm $target_ivf
    if $rm {
        rm $path
    }
}

const RC_CRF = 1

export def get-crf-bitrate [
    path: path
    --crf: int = 35
    --preset(-p): int = 6
    --max: int = 1080
    --tune: int = 0
    --mbr: filesize = 1.5mb
    --keyint: int = 289
    --start: string = "0"
    --end: string = "300"
] {
    let target_ivf = vid get-default-filename $path --ext ivf
    let scale = vid get-default-scaling $path --max $max
    let meta = vid get-meta $path
    let stat = ls -D $path | first

    mut log = $"Gauging crf for (ansiwrap default_reverse ($path | path basename)): initial size (ansiwrap light_blue ($stat.size | into string))"

    try {
        let source_meta = vid get-meta $path
        let res = [$source_meta.width, $source_meta.height] | math min

        $log += $", duration (ansiwrap light_green (vid _format-duration $source_meta.duration)), "
        $log += (ansiwrap light_green $"($res)p") + ", "
        $log += (ansiwrap light_green $"($source_meta.fps | math round)fps")
    }

    print $log

    yuv-pipe $path $scale --start 0 --end $end | (SvtAv1EncApp
        -i stdin
        --rc $RC_CRF
        # --progress 0
        --crf $crf
        --mbr ($mbr / 1000 | into int)
        --preset $preset
        --keyint $keyint
        -b $target_ivf
    ) o+e>| ignore

    let duration_secs = [($end | into int) ($meta.duration / 1sec)] | math min
    let target_size = ls -D $target_ivf | get 0.size

    rm $target_ivf

    print $"($target_size) for ($duration_secs)secs"

    $target_size / $duration_secs * 8
}

export def 'vid 2p av1 crf' [
    path: path
    --crf: int = 35
    --preset(-p): int = 6
    --audio-bitrate(-a): oneof<filesize, int> = 96kb
    --max: int = 1080 # The max dimensions of the smaller side (vertical for landscape, horizontal for portrait)
    --log-level: int = 1 # Set to 3 to print encoder info. SvtApp has useless, irremediable warnings
    --tune: int = 0 # 0: vq, 1: psnr, 2: ssim
    --tbr: filesize = 1.5mb # Maximum total bitrate. Bytes interpreted as bits (1mb = 1mbit)
    --tbr2p: filesize = 3mb # Maximum bitrate used for the fallback 2-pass mode
    --rm
] {
    if $path =~ '\.min\.' {
        print (ansiwrap yellow $"Skipping ($path | path basename): looks already compressed")
        return
    }

    $env.SVT_LOG = $log_level

    let target = vid get-default-filename $path --ext mp4
    if ($target | path exists) {
        print (ansiwrap yellow $"Skipping ($path | path basename): already compressed")
        return
    }

    let predicted_crf = get-crf-bitrate $path
    # CRF overshoot tends to cap out at 15%, and we add a 10% floor for 25%
    # Why? Our prediction is based on the first 5min of video. This segment can be lower entropy (intros, low action)
    # and take up a larger portion of the "total" size. Fallback 2-pass encodes at a higher target, so we compensate
    let threshold = $tbr * 0.9

    print -e $"CRF prediction encoded at ($predicted_crf), (
        $predicted_crf - $threshold | into string | str replace - ''
    ) (
        if $predicted_crf > $threshold { "over" } else { "under" }
    ) threshold"

    if $predicted_crf > $threshold {
        # Encode it in two passes. And since the video is more complex to meet crf, we bump the $tbr2p value
        # It's quite a bit higher, but 2-pass has the opposite "problem", in that it often undershoots its target
        # (despite using it more efficiently). So 1.8mbit might be 1.4mbit, and 2.3mbit might be 2mbit
        vid 2p av1 $path --preset $preset --tbr $tbr2p --audio-bitrate $audio_bitrate --max $max --tune $tune --rm=$rm
    } else {
        vid av1 $path --preset $preset --audio-bitrate $audio_bitrate --max $max --rm=$rm
    }
}

export def 'vid plot' [
    ...paths: path
] {
    parallel ...($paths | each { |path| { plotbitrate $path e>| each { |chunk| print -en $chunk } } })
}

export def 'vid av1-folder' [
    --max: int = 1080
    --video-bitrate: filesize = 1.5mb
    --preset: int
] {
    let preset = $preset | default-param "vid av1" preset

    glob '**/*.{mp4,webm,mkv,avi,m4v,mpg,wmv,mov,flv,m2ts}' | each { |p|
        vid av1 $p --rm --max $max --video-bitrate $video_bitrate --preset $preset
    }
}

export def 'vid av1-folder-2p-crf' [] {
    glob '**/*.{mp4,webm,mkv,avi,m4v,mpg,wmv,mov,flv,m2ts}' | each { |p| vid 2p av1 crf $p --rm }
}

export def 'vid folder-duration' [] {
    glob '**/*.{mp4,webm,mkv,avi,m4v,mpg,wmv,mov,flv,m2ts}'
        | par-each { |v|
            try {
                vid get-meta $v | merge { path: $v, count: 1 } | insert pixels_capped { |r| [($r.width * $r.height), (1080 * 1980)] | math min }
            } catch {
                print $"Failed probing file: ($v)"
                null
            }
        }
        | select duration frames pixels_capped count
        | math sum
        | insert duration_1080p { |r| $r.duration * ($r.pixels_capped / (1080 * 1980) / $r.count) }
        | insert duration_30fps { |r| $r.frames / 30 | into duration -u sec }
        | insert duration_30fps1080p { |r| $r.duration_30fps * ($r.pixels_capped / (1080 * 1980) / $r.count) }
        | reject frames pixels_capped
}

export def 'vid h265-encode' [
    path: path,
    --bitrate: filesize = 1.5mb
    --preset: string = "medium"
    --crf: int = 24
] {
    let scale = vid get-default-scaling $path
    let target = vid get-default-filename $path
    if ($target | path exists) {
        return
    }

    (ffmpeg
        -v quiet
        -stats
        -i $path
        -c:v libx265
        -preset $preset
        -crf $crf
        -maxrate ($bitrate | into int)
        -bufsize ($bitrate * 2 | into int)
        -c:a aac
        -b:a 128k
        -vf $"scale=($scale.max_width):($scale.max_height)"
        $target
    )
}

export def 'vid vp9-encode' [
    path: path,
    --bitrate: filesize = 1.5mb
    --preset: string = "medium"
    --crf: int = 30
] {
    let scale = vid get-default-scaling $path
    let target = vid get-default-filename $path
    if ($target | path exists) {
        return
    }

    (ffmpeg
        -v quiet
        -stats
        -i $path
        -c:v libvpx-vp9
        -b:v ($bitrate | into int)
        -crf $crf
        -maxrate ($bitrate | into int)
        -bufsize ($bitrate * 2 | into int)
        -speed 2
        -c:a libopus
        -b:a 128k
        -vf $"scale=($scale.max_width):($scale.max_height)"
        $target
    )
}

export def 'vid h265-2pass' [
    path: path,
    filesize?: filesize,
    --preset: string = "medium" # Medium is good enough and 2x faster than slow
    --audio-codec: string = "opus" # opus or aac
    --audio-bitrate: filesize
    --no-audio
] {
    # 90-95% of the total bitrate seems to be enough to not jump over filesize
    # Rather tight and might need adjusting, however
    let exact = $filesize != null
    let filesize = if $filesize == null { 10mib } else { $filesize }
    let FALLIBILITY_THRESHOLD = if $exact { 1 } else { 0.95 }

    let scale = vid get-default-scaling $path
    let target = vid get-default-filename $path
    let meta = vid get-meta $path
    let duration = $meta.duration | into int | $in / 1000000000 # micros in 1sec
    let audio_bitrate = if $no_audio {
        0
    } else if $audio_bitrate != null {
        $audio_bitrate | into int
    } else if $audio_codec == 'opus' {
        96kb | into int
    } else if $audio_codec == 'aac' {
        128kb | into int
    } else {
        error make {
            msg: "codec must be 'aac' or 'opus'"
        }
    }
    let filesize_bits = ($filesize | into int) * 8 # Total bits
    let total_bitrate = ($filesize_bits / $duration) | into int | $in * $FALLIBILITY_THRESHOLD
    let video_bitrate = $total_bitrate - $audio_bitrate

    if ($target | path exists) {
        return
    }

    # First Pass
    (ffmpeg
        -v quiet
        -stats
        -y
        -i $path
        -c:v libx265
        -b:v $video_bitrate
        -pass 1
        -preset veryfast
        -x265-params "log-level=error"
        -an
        -f null /dev/null
    )

    # Second Pass
    (ffmpeg
        -v quiet
        -stats
        -y
        -i $path
        -c:v libx265
        -b:v $video_bitrate
        -pass 2
        -preset $preset
        -x265-params "log-level=error"
        ...(if $no_audio {
            ['-an']
        } else {
            [ -c:a, (if $audio_codec == 'opus' { 'libopus' } else { 'aac' }), -b:a, $audio_bitrate ]
        })
        -vf $"scale=($scale.max_width):($scale.max_height)"
        $target
    )
}

export def 'vid 2p vp9' [
    path: path,
    filesize?: filesize,
] {
    let exact = $filesize != null
    let filesize = if $filesize == null { 10mib } else { $filesize }
    let FALLIBILITY_THRESHOLD = if $exact { 1 } else { 0.95 }

    let scale = vid get-default-scaling $path
    let target = vid get-default-filename $path --ext webm
    let meta = vid get-meta $path
    let duration = $meta.duration | into int | $in / 1000000000 # micros in 1sec
    let audio_bitrate = 96 * 1000 # 96 kbps in bits per second

    let filesize_bits = ($filesize | into int) * 8 # Total bits
    let total_bitrate = ($filesize_bits / $duration) | into int | $in * $FALLIBILITY_THRESHOLD
    let video_bitrate = $total_bitrate - $audio_bitrate

    if ($target | path exists) {
        return
    }

    # First pass
    (ffmpeg
        -v quiet
        -stats
        -y
        -i $path
        -c:v libvpx-vp9
        -b:v $video_bitrate
        -pass 1
        -cpu-used 4
        -tile-columns 3
        -an
        -f null /dev/null
    )

    # Second pass
    (ffmpeg
        -v quiet
        -stats
        -i $path
        -c:v libvpx-vp9
        -b:v $video_bitrate
        -pass 2
        -cpu-used 4
        -tile-columns 3
        -c:a libopus
        -b:a $audio_bitrate
        -vf $"scale=($scale.max_width):($scale.max_height)"
        $target
    )
}

export def 'vid remote-encode' [
    path: path
] {
    let filename = $path | path basename
    let target = vid get-default-filename $path
    if ($target | path exists) {
        return
    }

    let elapsed_upload = timeit { ssh cp $path "worker:Downloads/encodes/" }
    print -e $"upload took (ansi yellow)($elapsed_upload)(ansi reset)"


    let start = "let v = from json; cd Downloads/encodes; vid h265-encode $v.filename"
    let elapsed_encode = timeit {
        { filename: $filename }
            | to json
            | ssh worker $"nu --stdin --config .config/nushell/config.nu -c \"($start)\""
    }
    print -e $"encode took (ansi yellow)($elapsed_encode)(ansi reset)"

    let elapsed_download = timeit { ssh cp $"worker:Downloads/encodes/($target)" $target }
    print -e $"download took (ansi yellow)($elapsed_download)(ansi reset)"

    let remove = "let v = from json; cd Downloads/encodes; rm $v.filename"
    { filename: $filename } | to json
        | ssh worker $'nu --stdin -c "($remove)"'
}

def dither-algorithms [] {
    [
        'none',
        'atkinson',
        'bayer',
        'burkes',
        'floyd_steinberg',
        'heckbert',
        'sierra2',
        'sierra2_4a',
        'sierra3'
    ]
}

export def 'vid to-gif' [
    file: path
    output?: path
    --fps: int # = 50
    --start: string
    --end: string
    --height: int
    --width: int
    --loops: int = 0 # -1 to not repeat, 0 to repeat forever, 1+ for counts
    --dither: string@dither-algorithms # none/atkinson/bayer/burkes/floyd_steinberg/heckbert/sierra2/sierra2_4a/sierra3
    --framepalettes # New palette per frame, for most varying colors, highly ruining compression
] {
    let output = $output | default (path interject $file --ext gif --count)
    let parsed = $file | path parse
    let fps = if $parsed.extension in ['png', 'jpg', 'jpeg'] {
        25 # Image input is interpreted as 25fps video with one frame
    } else {
        $fps
    }
    # Use -1, -2, -4 to keep multiples when rounding and automatically calculating the other dimension
    let height = $height | default (-1)
    let width = $width | default (-1)
    let dithercommand = if $dither != null {
        $":dither=($dither)"
    } else {
        ""
    }
    let fpsfilter = if $fps != null {
        $"fps=($fps),"
    } else {
        ""
    }
    let palettefilter = $"paletteuse=new=($framepalettes | into int)($dithercommand)"
    let palettegen = $"palettegen=stats_mode=(if $framepalettes { 'single' } else { 'full' })"

    let filter = $"($fpsfilter)scale=($width):($height):flags=lanczos,split[s0][s1];[s0]($palettegen)[p];[s1][p]($palettefilter)"

    (ffmpeg
        # ...(if $start != null { [-ss, $start] } else { [] })
        # ...(if $end != null { [-t, $end] } else { [] })
        ...(if $start != null { [-ss $start] } else { [] })
        ...(if $end != null { [-to $end] } else { [] })
        -i $file
        -vf $filter
        -loop $loops
        $output
    )
}

# export def position-gif-transparent [
#     file: path
#     --width: int
#     --height: int
#     --x: int
#     --y: int
#     --frame-width: int
#     --frame-height: int
#     --background: string = '0x00000000'
# ] {
#     let output = path interject $file positioned
#     let meta = vid get-meta $file
#     let fps = $meta.fps | into int
#     let frames = $meta.frames
#     let duration_secs = $meta.duration | into int | $in / 1000000000

#     (ffmpeg
#         -i $file
#         -filter_complex $"[0:v]scale=($width):($height)[resized];
#         color=($background):s=($frame_width)x($frame_height):d=($duration_secs),fps=($fps)[bg];
#         [bg][resized]overlay=($x):($y):shortest=0"
#         -c:v gif
#         $output
#     )
# }

export def 'vid position-gif-transparent' [
    file: path
    --width: int
    --height: int
    --x: int
    --y: int
    --frame-width: int
    --frame-height: int
    --background: string = '0x00000000'
] {
    let output = path interject $file positioned
    let palette = path interject $file "palette" --ext png
    let meta = vid get-meta $file
    let fps = $meta.fps | into int
    let frames = $meta.frames
    let duration_secs = ($meta.duration | into int) / 1000000000

    # Palettegen for transparency
    (ffmpeg
        -i $file
        -filter_complex $"
            [0:v]fps=($fps),scale=($width):($height)[resized];
            color=($background):s=($frame_width)x($frame_height):d=($duration_secs),fps=($fps)[bg];
            [bg][resized]overlay=($x):($y):shortest=0,fps=($fps),palettegen=reserve_transparent=1"
        -y $palette
        )

    # Generate file and position it
    (ffmpeg
        -i $file
        -i $palette
        -filter_complex $"
            [0:v]fps=($fps),scale=($width):($height)[resized];
            color=($background):s=($frame_width)x($frame_height):d=($duration_secs),fps=($fps)[bg];
            [bg][resized]overlay=($x):($y):shortest=0,fps=($fps)[out];
            [out][1:v]paletteuse=dither=bayer:bayer_scale=5"
        -loop 0
        -y
        $output
    )

    rm $palette
}

export def 'vid get-default-filename' [file: path, target?: path, --ext: string = 'mp4'] {
    let parsed_file = $file | path parse

    # let target = $target | default ($parsed_file.stem + ".min." + $parsed_file.extension)
    let target = $target | default ($parsed_file.stem + ".min." + $ext)

    return $target
}

export def "vid min gpu" [
    file: path # The path to the video
    bitrate_per_second: filesize = 1.5mb # The target video bitrate. mb = mbits. Nvenc tends to lowball, so make this higher than max
    target?: path # The target filename
    --preset: string = "p7" # The encoding preset to use
    --res-y: int # The target video height in pixels
    --res-x: int # The target video width in pixels
] {
    let target = vid get-default-filename $file $target

    let target_video_bitrate_argument = $"($bitrate_per_second / 1kb)K"

    let target_video_filter = if $res_x == null and $res_y == null {
        let scale = vid get-default-scaling $file

        $"scale=($scale.max_width | default (-2)):($scale.max_height | default (-2))"
    } else {
        $"scale=($res_x | default (-2)):($res_y | default (-2))"
    }

    # print "filter: " + $target_video_filter

    ^ffmpeg ...[
        -v quiet # No banner, metadata, streams
        -stats # Show progress bar
        # -hwaccel cuda # redundant?
        # -hwaccel_output_format cuda Full hardware doesn't support filters for resize, also isn't really faster?
        -i $file
        -c:v hevc_nvenc
        # -pix_fmt yuv420p # Output format supported by the GPU; redundant
        -preset $preset
        -rc vbr
        -multipass 2
        -tune hq
        ...(if $target_video_filter != '' { ['-vf', $target_video_filter] } else { [] })
        -b:v $target_video_bitrate_argument
        -bufsize 10M
        -c:a copy # copy audio; otherwise just aac 128k
        -y
        $target
    ]
}

export def "vid min many" [
    paths: list
    --bitrate: filesize = 1.5mb # Bits per second
    --threads(-t): int = 4
    --delete(-d) # Delete source files if larger than converted file
] {
    # Clear terminal but without losing data
    term clear-spaced

    let rows_mutex = mutex make
    let print_mutex = mutex make

    let instance_key = random chars

    stor open | query db "CREATE TABLE IF NOT EXISTS vid_min_rows (
        instance_id TEXT NOT NULL,
        position INTEGER NOT NULL
    )"

    $paths | enumerate | par-each -t $threads { |pair|
        let free_position = mutex with $rows_mutex {
            let taken_positions = (stor open
                | query db $"SELECT * FROM vid_min_rows WHERE instance_id = '($instance_key)'"
                | get position
            )

            let free_position = 0..1000 | where { |n| $n not-in $taken_positions } | first

            stor insert -t vid_min_rows -d { instance_id: $instance_key, position: $free_position }

            $free_position
        }

        # sleep (random int 0..5000 | into duration -u ms)

        let basename = $pair.item | path basename
        let scale = vid get-default-scaling $pair.item
        let target = vid get-default-filename $pair.item

        vid min gpu $pair.item $bitrate $target --res-y $scale.max_height --res-x $scale.max_width e>| reduce -f 1 { |chunk, column|
            let terminal_height = (term size | get rows) - 3

            let prefix = if $column == 1 {
                $"[($basename)] "
            } else {
                ""
            }

            let chunk = $"($prefix)($chunk)"

            mutex with $print_mutex {
                term move-cursor ($column - 1) ($free_position + 1)
                if $column == 1 {
                    # term clear-rest-of-line
                    # term move-cursor ($column - 1) ($free_position + 1)
                }

                print -n $chunk
            }

            let new_column = if ($chunk | str contains "\r") { 1 } else { $column + ($chunk | str length) }

            $new_column
        } | ignore

        try {
            let old_size = ls -D $pair.item | get size.0
            let new_size = ls -D $target | get size.0

            if $old_size > $new_size and $delete {
                rm $pair.item
            }
        }

        stor open | query db $"DELETE FROM vid_min_rows WHERE instance_id = ? AND position = ?" -p [$instance_key, $free_position]
    } | ignore
}

export def "vid min folder" [
    --glob: string = "**/*.{mp4,webm,mkv,avi,m4v,mpg,wmv,flv,mov}",
    --bitrate: filesize = 1.5mb # Bits per second
    --delete(-d) # Delete source files if larger than converted file
    --threads(-t): int = 4
] {
    let paths = glob $glob -DS | where $it !~ '.min.\w+'

    vid min many $paths --threads $threads --bitrate $bitrate --delete=$delete
}

export def 'vid validate' [
    path: path
] {
    let results = ffmpeg  -loglevel 24 -hide_banner -i $path -c:v copy -c:a copy -f null - | complete

    if $results.exit_code != 0 or $results.stderr != "" {
        return { ok: false, message: $results.stderr }
    } else {
        return { ok: true, message: null }
    }
}

export def "vid validate folder" [
    --glob: string = "**/*.{mp4,webm,mkv,avi,m4v,mpg,wmv,flv,mov}"
    --threads(-t): int = 1
] {
    timeit {
        glob $glob | par-each -t $threads { |path|
            let base = $path | path basename

            print -en $"\rValidating ($base)..."
            term clear-rest-of-line

            let valid = vid validate $path

            if not $valid.ok {
                print -en "\r"
                term clear-rest-of-line
                print $"\rInvalid file: ($base)\n($valid.message)"
            }
        }

        print
    }
}

# ChatGPT'd, it makes strange design decisions. It also thought we had destructuring T_T
def parse-time [input: string] {
    let mf = (
        if $input =~ '\.' {
            $input | split row '.'
        } else {
            [$input, '0']
        }
    )

    let parts = $mf.0 | split row ':' | reverse
    let seconds = ($parts.0 | into int)
    let minutes = (if ($parts | length) > 1 { $parts.1 | into int } else { 0 })
    let hours   = (if ($parts | length) > 2 { $parts.2 | into int } else { 0 })

    # Millis are aligned left, not right
    let millis = ($mf.1 | fill -w 3 -c 0 -a l | into int)

    $hours * 3600 + $minutes * 60 + $seconds + $millis / 1000
}

# Cuts a video from `start` to `end`, in nvenc p7 h265, with optional size target
export def vcut [
    path: string
    start: string = "0"
    end: string = "1000000"
    size?: filesize
    result?: string
    --audio: filesize
    --crf: int = 30 # Lower this for better quality, 21 is much better, much bigger; not useful for target sizes
    --max: int = 1080 # Lower this if nvenc really can't make it fit in `size`
    --rawtime # Use -to timestamp instead of calculating -t from parsing $end - $start
    --codec: string = hevc_nvenc
] {
    let outpath = $result | default (path interject $path cut --count --ext mp4)

    let end = if $end == "0" {
        "1000000"
    } else {
        $end
    }

    let meta = vid get-meta $path
    let total_duration = $meta.duration | into int | $in / 1000000000

    # We gotta parse them because we can't rely on vid get-meta for the duration after cut
    # And doing a temp --copy cut is meh, dirty?
    let start_time = parse-time $start
    let end_time = [(parse-time $end), $total_duration] | math min
    let duration = $end_time - $start_time

    mut audio_bitrate = ($audio | default 96kb) | into int

    mut bitrate_flags = []
    if $size != null {
        let filesize_bits = ($size | into int) * 8 # Total bits
        let total_bitrate = ($filesize_bits / $duration) | into int

        # Audio can take a hit on the excellent opus codec
        $audio_bitrate = if $audio != null {
            $audio | into int
        } else if $total_bitrate > 96kb / 1b * 10 {
            $audio_bitrate
        } else if $total_bitrate > 96kb / 1b * 5 {
            print $"bumped audio down to 64k \(max (96kb * 10), at ($total_bitrate * 1b))"
            64kb | into int
        } else {
            print $"bumped audio down to 32k \(max (96kb * 5), at ($total_bitrate * 1b))"
            32kb | into int
        }

        let video_bitrate = $total_bitrate - $audio_bitrate

        const target_fallibility = 0.95
        const max_fallibility = 0.97

        $bitrate_flags ++= [-b:v ($video_bitrate * $target_fallibility)]
        $bitrate_flags ++= [-maxrate ($video_bitrate * $max_fallibility)]
        # $bitrate_flags ++= [-bufsize ($video_bitrate * 2)]
    }

    let scale = vid get-default-scaling $path --max=$max

    let audio_flags = if $audio_bitrate == 0b {
        ['-an']
    } else {
        [
            -c:a libopus
            -b:a $audio_bitrate
        ]
    }

    print $"start: ($start) end: ($end) duration: ($duration)"

    (ffmpeg
        -v warning
        -stats
        # Conditionally including -ss helps with hard-to-seek video formats (like avi)
        ...(if $start != "0" { [-ss $start] } else { [] })
        # -to inserted before video input if raw, -t inserted after if not
        ...(if $rawtime { [-to $end] } else { [] })
        -i $path
        ...(if not $rawtime { [-t $duration] } else { [] })
        -c:v $codec
        -preset p7
        -rc vbr
        ...($bitrate_flags)
        # -bufsize 1000k
        -cq $crf
        -profile:v main # Discord mobile & desktop sometimes fail on main10, on different videos. TODO: investigate
        -pix_fmt yuv420p # Force 8-bit profile even for 10 bit input streams
        -rc-lookahead 32
        -spatial-aq 1
        -aq-strength 15
        -temporal-aq 1
        -bf 4
        -g 300
        -vf $"scale=($scale.max_width):($scale.max_height)"
        ...($audio_flags)
        $outpath
    )

    # (ffmpeg
    #     -v warning
    #     -stats
    #     -ss $start
    #     -to $end
    #     -i $path
    #     ...($bitrate_flags)
    #     -c:v libx265
    #     -preset medium
    #     -crf $crf
    #     -x265-params "rc-lookahead=32:aq-mode=1:aq-strength=1:bframes=4:keyint=300"
    #     -vf $"scale=($scale.max_width):($scale.max_height)"
    #     ...($audio_flags)
    #     $outpath
    # )
}
