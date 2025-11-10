export def 'http fetch-chunks' [
    urls: list
    --threads: int = 8
] {
    $urls | enumerate | par-each --keep-order --threads $threads { |elem|
        let index = $elem.index
        let url = $elem.item

        loop {
            try {
                print -e $"fetch chunk ($index)"
                let buf = http get --raw $url
                return $buf
            } catch { |e|
                print -e $"(ansi red)chunk ($index) failed, sleep and retry(ansi reset)"
                sleep 1sec
            }
        }
    }
}
