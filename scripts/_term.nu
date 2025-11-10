use _str.nu *

# Clear terminal but without losing data
export def 'term clear-spaced' [] {
    0..(term size | get rows) | each { print "" }
    clear -k
}

# Move the cursor in the terminal in absolute units
export def 'term move-cursor' [
    x: int # 0-indexed column to move the cursor to. Max to (term size).columns - 1
    y: int # 0-indexed row to move the cursor to. Max to (term size).rows - 1
] {
    print -n $"\e[($y + 1);($x + 1)H";
}

# Get the current position of the cursor
export def 'term get-cursor-pos' [
    --restore = true
]: [nothing -> record<x: int, y: int>] {
    print "\e[6n"

    let res = input -s -u R
        | parse -r '^\[(?<y>\d+);(?<x>\d+)' # Input does not include delimiting "R"
        | first
        | update x { ($in | into int) - 1 }
        | update y { ($in | into int) - 1 }

    # This seems redundant, but we have to do it to preserve the position.
    # Above input, despite being silent, moves the cursor down.
    if $restore {
        term move-cursor $res.x $res.y
    }

    $res
}

# Get the current position of the cursor
export def 'term retain-position' [ closure: closure ] {
    let pos = term get-cursor-pos

    do $closure

    term move-cursor $pos.x $pos.y
}

export def 'term clear-rest-of-line' [] {
    let size = term size
    let pos = term get-cursor-pos

    # Max - current column is the amount of characters remaining until wrapping
    # Current can never == max, so the empty space print can never be empty
    # After the print, the cursor will be at the end of the cleared line,
    # despite the fact that printing any more characters will spill onto the next line.
    # I'm not sure why this happens. Being on the last column should mean
    # that printing another character will be on that row, and then move to the next.
    let spaces_to_print = $size.columns - $pos.x

    print -n (str repeat " " $spaces_to_print)
}
