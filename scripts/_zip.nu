use _jobs.nu *

export def 'zip list' [
    path: path
] {
    let result = 7z l -slt $path | split row -n 2 "----------"
    let entries_re = '(?m)((?:^.+? = .*$\n)+)'
    let props_re = '(?m)^(.+?) = (.*)$'

    let header = $result.0 | parse -r $entries_re
    let files = $result.1 | parse -r $entries_re

    let metadata = $header.capture0.0 | parse -r $props_re | transpose -rd
    let files = (
        $files.capture0
        | each { parse -r $props_re | transpose -rd }
        | rename -b { |col|
            let map = {
                Path: 'path',
                Folder: 'folder',
                Size: 'size',
                'Packed Size': 'packed',
                Created: 'created',
                Modified: 'modified',
                Accessed: 'accessed',
                Attributes: 'attributes',
                Encrypted: 'encrypted',
                Comment: 'comment',
                CRC: 'crc',
                Method: 'method',
                Characteristics: 'characteristics',
                'Host OS': 'host',
                Version: 'version',
                'Volume Index': 'volume',
                Offset: 'offset'
            }

            $map | get $col | default $col
        }
        | reject folder?
    )

    {
        metadata: $metadata,
        files: $files
    }
}

export def 'zip read' [
    zip: string
    file: string
] {
    7z e -so $zip $file
}

export def 'zip extract' [
    zip: string
    target: string
] {
    7z e $"-o($target)" $zip
}

export def 'zip remove' [
    zip: string
    file: string
] {
    7z d $zip $file
}

export def 'zip add' [
    zip: string
    file: string
    --store
] {
    mut flags = []

    if $store {
        $flags ++= ['-mx0']
    }

    7z a ...$flags $zip $file
}

export def 'zip map' [
    zip: string
    mapper: closure
    --parallelism: int = 4
    --store
] {
    # path expand is broken with canonicalization failures over ftp
    let expanded_zip = $env.PWD | path join $zip

    let temp_zip_target = mktemp --dry -t zip.XXXXXXXXXX.tmp
    let temp_directory = mktemp -dt tmpzip.XXXXXXXXXX

    # Faster for random access over network drives
    ^cp $zip $temp_zip_target

    # I couldn't get zip read to work inside a loop over zip list
    zip extract $temp_zip_target $temp_directory o+e>| ignore

    cd $temp_directory

    glob **/* -DS | path relative-to $env.PWD | par-each -t $parallelism { |path|
        let replacement_path = do $mapper $path

        {
            original: $path,
            replacement: $replacement_path
        }
    } | each { |result|
        if $result.replacement != null and ($result.replacement | path exists) {
            zip remove $temp_zip_target $result.original o+e>| ignore
            zip add --store=$store $temp_zip_target $result.replacement o+e>| ignore
        }
    }

    # Must use expanded since we moved with cd earlier, and moving back is brittle
    ^cp $temp_zip_target $expanded_zip

    rm -rf $temp_directory $temp_zip_target

    null
}

export def 'zip map-pipeline' [
    mapper: closure
    --parallelism: int = 4 # Worker parallelism; not extraction I/O parallelism
    --store
    --backpressure: int = 32
] {
    let zips = $in

    let parent = job id
    let mover = job spawn {
        job recv-all --stop-sentinel -1 | reduce -f { totals: {}, moved: {}, modified: {} } { |msg, counts|
            let counts = if $msg.type? == 'total' {
                {
                    moved: $counts.moved,
                    modified: $counts.modified,
                    totals: ($counts.totals | insert $msg.zip $msg.count)
                }
            } else {
                {
                    moved: ($counts.moved | upsert $msg.zip { default 0 | $in + 1 }),
                    modified: ($counts.modified | upsert $msg.zip { default 0 | $in + (if $msg.replacement != null { 1 } else { 0 }) }),
                    totals: $counts.totals
                }
            }

            if $msg.zip in $counts.totals and ($counts.moved | get -o $msg.zip) == ($counts.totals | get $msg.zip) {
                if ($counts.modified | get $msg.zip) > 0 {
                    print -e $"All files mapped: ($msg.zip) -> ($msg.target_zip)"

                    try {
                        ^cp $msg.zip $msg.target_zip
                    } catch {
                        print "Error during cp"
                    }

                    while (^stat -c '%s' $msg.zip) != (stat -c '%s' $msg.target_zip) {
                        print -e $"Corrupted transfer from ($msg.zip) to ($msg.target_zip)"

                        try {
                            ^cp $msg.zip $msg.target_zip
                        } catch {
                            print "Error during cp"
                        }
                    }

                } else {
                    print -e $"No files needed mapping: ($msg.target_zip)"

                }

                rm -rf $msg.zip $msg.directory
            }

            $counts
        }

        -1 | job send $parent
    }
    let replacer = job spawn {
        # This one's only needed because of `par-each` not streaming... eugh
        job recv-all --stop-sentinel -1 | each { |result|
            # Move to a safe directory for path functions to not error
            cd $result.directory

            # Perform the replacements sequentially; don't spawn 7z on the same archives in parallel
            if $result.replacement != null and ($result.replacement | path exists) {
                print -e $"Mapped: ($result.original) -> ($result.replacement)"

                zip remove $result.zip $result.original o+e>| ignore
                zip add --store=$store $result.zip $result.replacement o+e>| ignore
            }

            $result | job send $mover
        }

        -1 | job send $mover
        -1 | job send $parent
    }
    let worker = job spawn {
        job recv-all --stop-sentinel -1 | par-each --threads $parallelism { |msg|
            cd $msg.directory

            let replacement_path = do $mapper $msg.path

            let result = {
                original: $msg.path,
                zip: $msg.zip,
                target_zip: $msg.target_zip,
                directory: $msg.directory,
                replacement: $replacement_path
            }

            $result | job send $replacer
        }

        -1 | job send $replacer
        -1 | job send $parent
    }

    let zip_counts = $zips | each { |zip_path|
        let expanded_zip = $env.PWD | path join $zip_path

        let temp_zip_target = mktemp --dry -t zip.XXXXXXXXXX.tmp
        let temp_directory = mktemp -dt tmpzip.XXXXXXXXXX

        ^cp $zip_path $temp_zip_target

        while (^stat -c '%s' $zip_path) != (stat -c '%s' $temp_zip_target) {
            print -e $"Corrupted transfer from ($zip_path) to ($temp_zip_target)"
            ^cp $zip_path $temp_zip_target
        }

        zip extract $temp_zip_target $temp_directory o+e>| ignore

        cd $temp_directory

        # Note: This has no backpressure, so it'll keep extracting, potentially faster than worker can handle them
        let file_count = glob **/* -DS | path relative-to $env.PWD | each { |path|
            { path: $path, zip: $temp_zip_target, target_zip: $zip_path, directory: $temp_directory } | job send $worker

            $path
        } | length

        {
            type: 'total',
            zip: $temp_zip_target,
            target_zip: $zip_path,
            count: $file_count,
            directory: $temp_directory
        } | job send $mover
    }

    -1 | job send $worker

    # -1s from worker, replacer and mover
    job recv
    job recv
    job recv

    print -e "All zips mapped."
}
