const NANOS_IN_SECOND = 1000000000

export def 'disk check' [
    --size: filesize = 8mib
    --limit: filesize = 1gib
    --threads: int = 16
] {
    rm -rf .data

    mkdir .data
    cd .data

    let start = date now
    let count = $limit / $size

    1..$count | par-each --threads=$threads { ||
        let payload = random binary $size
        let hash = $payload | hash sha256

        $payload | save $"($hash).bin"
    }

    let write_end = date now
    let write_seconds = ($write_end - $start) / 1sec

    print $"Wrote ($count) files, ($limit) in ($write_end - $start)"
    print $"Write speed: ($limit / $write_seconds)/s"
}

export def 'disk verify' [
    --threads: int = 16
] {
    let start = date now
    let files = glob .data/*.bin

    $files | par-each --threads=$threads { |path|
        let hash = $path | path parse | get stem
        let file_hash = open $path | hash sha256

        if $hash != $file_hash {
            print -e $"(ansi red)Hash mismatch: ($hash) != ($file_hash)(ansi reset)"
        }
    }

    let verify_end = date now
    let verify_seconds = ($verify_end - $start) / 1sec
    let total_size = ls .data/*.bin | get size | math sum

    print $"Verified ($files | length) files in ($verify_end - $start)"
    print $"Verification speed: ($total_size / $verify_seconds)/s"
}
