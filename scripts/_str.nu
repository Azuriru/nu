# Lazy implementation of repeating string.
# If `fill`'s implementation ever changes, I'm screwed
export def 'str repeat' [str: string, count: int] {
    '' | fill -w $count -c $str
}

def ansi-list [] {
    ansi -l | get name
}

export def 'ansiwrap' [
    code: string@ansi-list
    text: any
] {
    $"(ansi $code)($text | to text)(ansi reset)"
}

export def sanitize-nu-clipboard [] {
    bp | lines | each { |line| $line | str replace -a "\t" "    " } | str join "\r\n" | bp
}
