# Insert `interjection` after the filename but before the extension
# With `--count` provided, also adds a counter for each collision
export def 'path interject' [
    path: string
    interjection?: string # Maybe oneof<string, closure> once it's stable
    --count # Suffix .count. for path collisions
    --ext: string
] {
    mut parsed = $path | path parse
    let stem = $parsed.stem
    if $interjection != null and $interjection != "" {
        $parsed.stem += $".($interjection)"
    }
    if $ext != null {
        $parsed.extension = $ext
    }
    mut result = $parsed | path join

    if $count {
        mut failures = 1
        while ($result | path exists) {
            # No second dot for windows file system ordering
            $parsed.stem = $"($stem).($interjection)($failures)"
            # $parsed.stem = $"($stem).($interjection).($failures)"
            $result = $parsed | path join
            $failures += 1
        }
    }

    $result
}
