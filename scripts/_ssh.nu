
export def 'ssh perms' [filepath: path] {
    icacls $filepath /inheritance:r
    icacls $filepath /grant:r "$($env:USERNAME):(F)"

    icacls $filepath
}

export def 'ssh get-deferred' [ key: string, compute?: closure, --wait-if-missing ] {
    const CREATE = "
        CREATE TABLE IF NOT EXISTS deferred_results (
            key TEXT PRIMARY KEY,
            value_json TEXT NOT NULL
        )
    "
    const UPSERT = "
        REPLACE INTO deferred_results (key, value_json)
        VALUES (:key, :value_json)
    "
    const FIND = "
        SELECT *
        FROM deferred_results
        WHERE key = :key
    "

    stor open | query db $CREATE

    let tag = random int
    if $compute != null {
        let self = job id
        let child = job spawn {
            let v = do $compute

            stor open | query db $UPSERT -p { key: $key, value_json: ($v | to json) }

            'done' | job send $self --tag $tag # send never blocks, hope it doesn't leak either
        }
    }

    mut values = stor open | query db $FIND -p { key: $key }
    if $wait_if_missing and ($values | is-empty) {
        # `job join` should be a builtin
        job recv --tag $tag

        $values = stor open | query db $FIND -p { key: $key }
    }

    $values | each { get value_json | from json } | get 0?
}

def ide-parse [ code: string ] {
    # let t = mktemp
    # $code | save -f $t
    # let ast = nu --ide-ast $t | from json
    # rm $t

    # $ast
    ast $code --flatten
}

export def 'ssh ssh-paths' [ worker: string, path: string ] {
    let parent = $"($path)_" | path parse | get parent
    let glob = if $parent == '' {
        "*"
    } else {
        $"($parent)/*"
    }

    ssh get-deferred $"ssh-paths-($worker)-($parent)" --wait-if-missing {
        let results = $glob | ssh $worker $"nu -l --stdin -c \"glob $in -d 1 | path relative-to $env.PWD | to json\"" | complete | get stdout | from json

        if $results == null {
            return []
        }

        return $results
    }
}

def machine-paths [ context: string, position: int ] {
    let last = ide-parse $context | last | get content
    let target = $last | parse -r '^(\u{27}|"|)(..+?):(.*?)\1?$' | get 0?

    # print ($target)

    if $target == null {
        # IDK no machine prefix, no way to fallback to the default path listing
        # Use a glob ($path)*, which is unreliable, but sorta works most of the time
        let completions = glob $"($last)*" -d 1 | path relative-to $env.PWD | each { |s|
            $"($last)($s | str substring ($last | str length)..)"
        }
        return $completions
    }

    # destructuring, please
    let quote = $target.capture0
    let machine = $target.capture1
    let path = $target.capture2

    try {
        let path_regex = $path | str replace -ar '[\\/]' '[\\/]'
        let results = ssh ssh-paths $machine $path
        let results = $results | where $it =~ $path_regex

        let completions = $results | each { |s|
            $"($quote)($machine):($path)($s | str substring ($path | str length)..)"
        }

        return $completions
    } catch {
        return []
    }
}

export def 'ssh cp' [
    from: string@machine-paths,
    to: string@machine-paths
] {
    # Fix scp quoting of spaced paths (without breaking windows abs paths)
    # let from = $from | str replace -r "^(..+?):(.+)$" "$1:\"$2\""
    # let to = $to | str replace -r "^(..+?):(.+)$" "$1:\"$2\""
    # let from = $from | str replace -a " " "\\ "
    # let to = $to | str replace -a " " "\\ "

    print $"from: ($from)"
    print $"to: ($to)"

    # ^echo -T -r $from $to

    # -r enables recursive copying
    # -C enables compression
    # -T does something (makes the command accept weird file paths?)
    scp -C -r $from $to
}

export def 'ssh sync-my-shit' [] {
    ssh cp $"($nu.home-path)/.config/nushell" worker:.config
    ssh cp $"($nu.home-path)/Code/ahk" worker:Code
}

# todo
export def 'ssh fs' [
    from: string@machine-paths,
    to: string@machine-paths
] {
    ssh cp $from $to

    watch $to { |op, path, new_path|
        print $op $path $new_path

        match $op {
            "rename" => {

            },
            "delete" => {

            },
            "edit" => {

            },
            _ => idk
        }
    }
}
