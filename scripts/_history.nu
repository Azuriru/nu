export def 'history find' [
    ...terms
    --regex
] {
    let finder = if $regex {
        { |row| $terms | all { |term| $row.command =~ $term } }
    } else {
        { |row| $terms | all { |term| $row.command | str contains -i $term } }
    }

    history | where $finder | reject cwd duration exit_status
}

export def 'ansiwrap' [
    code: string
    text: any
] {
    $"(ansi $code)($text | to text)(ansi reset)"
}

export def sanitize-nu-clipboard [] {
    bp | lines | each { |line| $line | str replace -a "\t" "    " } | str join "\r\n" | bp
}
