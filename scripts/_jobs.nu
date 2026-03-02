const FREE_TAG = 64001
const WORK_TAG = 64002

def 'job flush tag' [ tag: int ] {
    loop {
        try {
            job recv --tag $tag --timeout 0sec
        } catch {
            break
        }
    }
}

export def 'job pool' [
    handle: closure

    --size: int # defaults to cpu count
] {
    let size = $size | default { sys cpu | length }

    let workers = 0..<$size | each {
        job spawn {
            loop {
                let payload = job recv

                match $payload.tag {
                    $tag if $tag == $FREE_TAG => {
                        let response = {
                            loopback: (job id)
                        }

                        $response | job send $payload.loopback --tag $FREE_TAG
                    },
                    $tag if $tag == $WORK_TAG => {
                        let payload = {
                            worker: (job id),
                            index: $payload.index,
                            count: $payload.count
                        }

                        let result = do $handle $payload
                    },
                    $tag => {}
                }
            }
        }
    }
    let announcer = job spawn {

    }

    return {
        workers: $workers,
        announcer: $announcer
    }
}

export def 'job pool join' [] {}

export def 'job pool kill' [] {}

export def 'job pool send' [
    payload
] {
    let pool = $in

    let free = $pool | job pool free

    $payload | job send $free --tag $WORK_TAG
}

export def 'job pool broadcast' [
    payload
    --tag: int
] {
    let pool = $in

    $pool.workers | each { |id| $payload | job send $id --tag $tag }
}

export def 'job pool free' [] {
    let pool = $in

    $pool | job pool broadcast { loopback: (job id) } --tag $FREE_TAG

    let available = job recv --tag $FREE_TAG

    job flush tag $FREE_TAG

    return $available | get loopback
}

# Stolem: https://discord.com/channels/601130461678272522/615253963645911060/1426978963242356896
#
# Returns all messages in the mailbox as a stream
#
# After the mailbox is emptied, continues to wait for
# more messages and returns them as part of the stream.
#
# If `--timeout` is specified, the stream will stop
# after not receiving any new messages for `$timeout`.
#
# The stream can be prematurely ended with the usual methods,
# ie using `first`, `take`, `take while` and other similar
# commands.
@example "Collect all the messages in the mailbox and stop." {
    let messages = job recv-all --timeout 0sec
}
export def 'job recv-all' [
    --tag: int # A tag for the messages
    --timeout: duration # The maximum time duration to wait for
    --stop-sentinel: any
]: [ nothing -> list<any> ] {
    # discard pipeline input just incase
    null

    generate {|e = null|
        let out = match {tag: $tag, timeout: $timeout} {
            {tag: null, timeout: null} => { job recv }
            {$tag, timeout: null} => { job recv --tag=$tag }
            {$tag, $timeout} => {
                try {
                    if $tag == null {
                        job recv --timeout=$timeout
                    } else {
                        job recv --timeout=$timeout --tag=$tag
                    }
                } catch {|err|
                    if $err.json has "recv_timeout" {
                        # stop stream
                        return {}
                    } else {
                        # rethrow error
                        return $err.raw
                    }
                }
            }
        }

        if $out == $stop_sentinel {
            { }
        } else {
            { out: $out, next: null }
        }
    }
}
