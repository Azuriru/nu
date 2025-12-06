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
