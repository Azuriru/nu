# Insert a table of rows into a sqlite handle efficiently
export def 'sqlite batchsert' [
    table_name: string,
    data,
    --group-size: int = 128
] {
    let db = $in

    let columns = $data | columns

    let coldec = $columns | each { |col| $"'($col)'" } | str join ","
    let prefix = $"INSERT INTO '($table_name)' \(($coldec)\) VALUES "

    let batch_values = 0..<$group_size
        | each { |i| '(' + ($columns | each { '?' } | str join ',') + ')' }
        | str join ","
    let batch_stmt = $prefix + $batch_values + ";"

    $data | window $group_size --stride $group_size | each { |g|
        let params = $g | each { |row| $row | values } | flatten

        $db | query db $batch_stmt -p $params | ignore
    }

    let remainder = ($data | length) mod $group_size
    if $remainder > 0 {
        let remainder_values = 0..<$remainder
            | each { |i| '(' + ($columns | each { '?' } | str join ',') + ')' }
            | str join ","
        let remainder_stmt = $prefix + $remainder_values + ";"

        let params = ($data | last $remainder) | each { |row| $row | values } | flatten
        $db | query db $remainder_stmt -p $params | ignore
    }
}

export def 'sqlite init' [
    path: path
    init?: oneof<list, string>
] {
    let exists = $path | path exists

    if not $exists {
        { x: 'y' } | into sqlite $path -t _init_sentinel
    }

    if $init != null {
        if ($init | describe -d | get type) == "list" {
            let handle = open $path
            $init | each { |sql| $handle | query db $sql }
        } else {
            open $path | query db $init
        }
    }
}
