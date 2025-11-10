use _combinators.nu *

const mutex_key = "__mutex_key"
const guard_key = "__guard_key"
const guard_value = "__guard_value"

def _init_db [] {
    stor open | query db "CREATE TABLE IF NOT EXISTS nu_held_mutexes (
        mutex_key TEXT NOT NULL PRIMARY KEY
    )"

    stor open | query db "CREATE TABLE IF NOT EXISTS nu_mutex_values (
        mutex_key TEXT NOT NULL PRIMARY KEY,
        mutex_value TEXT NOT NULL
    )"
}

def _assert_mutex [ mutex: record ] {
    if not ((type-is $mutex "record") and (type-is ($mutex | get -o $mutex_key) "string")) {
        error make {
            msg: "Mutex methods must be passed in a mutex",
            label: {
                text: "This must be a mutex",
                span: (metadata $mutex).span
            }
        }
    }
}

def _assert_guard [ guard: record ] {
    if not ((type-is $guard "record") and (type-is ($guard | get -o $guard_key) "string")) {
        error make {
            msg: "Guard methods must be passed in a guard",
            label: {
                text: "This must be a guard",
                span: (metadata $guard).span
            }
        }
    }
}

export def 'mutex make' [] {
    _init_db

    {
        $mutex_key: (random chars)
    }
}

export def 'mutex lock' [ mutex: record ] {
    _assert_mutex $mutex

    let key = $mutex | get $mutex_key

    # Busy loop as long as unique constraint is enforced
    loop {
        try {
            stor insert -t nu_held_mutexes -d { mutex_key: $key }
            break
        }
    }

    {
        $guard_key: $key
    }
}

export def 'mutex get' [ guard: record ] {
    _assert_guard $guard

    (stor open
        | query db "SELECT * FROM nu_mutex_values WHERE mutex_key = ?" -p [($guard | get -o $guard_key)]
        | get 0?.mutex_value
        | default "null"
        | from json
    )
}

export def 'mutex set' [ guard: record, value ] {
    _assert_guard $guard

    (stor open
        | query db "REPLACE INTO nu_mutex_values (mutex_key, mutex_value) VALUES (?, ?)" -p [
            ($guard | get -o $guard_key),
            ($value | to json)
        ]
    )
}

export def 'mutex unlock' [ guard: record ] {
    _assert_guard $guard

    stor open | query db $"DELETE FROM nu_held_mutexes WHERE mutex_key = ?" -p [($guard | get $guard_key)]

    null
}

export def 'mutex with' [ mutex: record, block: closure ] {
    let guard = mutex lock $mutex

    let value = do $block $guard (mutex get $guard)

    mutex unlock $guard

    $value
}

export def 'mutex with-get' [ mutex: record ] {
    mutex with $mutex { |guard| mutex get $guard }
}
