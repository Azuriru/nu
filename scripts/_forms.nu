use ./_combinators.nu *

const CURRENT_PATH = path self

def codegen-question [ question: record<type: string> ] {
    let code = match $question.type {
        # Text fields
        "text" => "
# Container
${key}Column = New-Object System.Windows.Forms.FlowLayoutPanel
${key}Column.Dock = 'Top'
${key}Column.AutoSize = $true
${key}Column.FlowDirection = 'TopDown'
${key}Column.AutoSizeMode = 'GrowAndShrink'
${key}Column.WrapContents = $false
${key}Column.Padding = '0,0,0,0'
${key}Column.Margin  = '0,0,0,0'

# Label
${key}Label = New-Object System.Windows.Forms.Label
${key}Label.Text = {label_json}
${key}Label.AutoSize = $true
${key}Column.Controls.Add(${key}Label)

${key}TextBox = New-Object System.Windows.Forms.TextBox
{postnew}
${key}TextBox.Width = {width-276}
# Enable autocomplete to make ctrl+backspace work
${key}TextBox.AutoCompleteMode = 'Append'
${key}TextBox.AutoCompleteSource = 'CustomSource'
${key}TextBox.Text = {default_json}
{postinit}
${key}Column.Controls.Add(${key}TextBox)

$flowPanel.Controls.Add(${key}Column)

if (${autofocus}) {
    $form.Add_Shown({ ${key}TextBox.Select() })
}
"
    # Numeric inputs
        "number" => "
# Container
${key}Column = New-Object System.Windows.Forms.FlowLayoutPanel
${key}Column.Dock = 'Top'
${key}Column.AutoSize = $true
${key}Column.FlowDirection = 'TopDown'
${key}Column.AutoSizeMode = 'GrowAndShrink'
${key}Column.WrapContents = $false
${key}Column.Padding = '0,0,0,0'
${key}Column.Margin  = '0,0,0,0'

# Label
${key}Label = New-Object System.Windows.Forms.Label
${key}Label.Text = {label_json}
${key}Label.AutoSize = $true
${key}Column.Controls.Add(${key}Label)

{preinit}
${key}Numeric = New-Object System.Windows.Forms.NumericUpDown
{postnew}
${key}Numeric.Width = {width-276}
${key}Numeric.Minimum = {min-null}
${key}Numeric.Maximum = {max-null}
${key}Numeric.Value   = {default-0}
${key}Numeric.Increment = {step-1}
${key}Numeric.DecimalPlaces = {decimals-0}
{postinit}
${key}Column.Controls.Add(${key}Numeric)

$flowPanel.Controls.Add(${key}Column)

if (${autofocus}) {
    $form.Add_Shown({ ${key}Numeric.Select() })
}"
        # Dropdowns
        "dropdown" => "
# Label
${key}Label = New-Object System.Windows.Forms.Label
${key}Label.Text = {label_json}
${key}Label.AutoSize = $true
$flowPanel.Controls.Add(${key}Label)

{preinit}
${key}ComboBox = New-Object System.Windows.Forms.ComboBox
{postnew}
${key}ComboBox.Width = 276
${key}ComboBox.DropDownStyle = 'DropDownList'

# Populate dropdown items
foreach ($option in ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String({options_jsonb64})) | ConvertFrom-Json)) {
    if (($option -is [string]) -or ($option -is [int])) {
        ${key}ComboBox.Items.Add($option) | Out-Null
    } else {
        ${key}ComboBox.Items.Add($option.label) | Out-Null
    }
}

${key}ComboBox.SelectedIndex = {default-0}

{postinit}
$flowPanel.Controls.Add(${key}ComboBox)

if (${autofocus}) {
    $form.Add_Shown({ ${key}ComboBox.Select() })
}
"
        # Pictures
        "picture" => "
{preinit}
${key}PictureBox = New-Object System.Windows.Forms.PictureBox
{postnew}
${key}PictureBox.Width = 276
${key}PictureBox.Height = 150
${key}PictureBox.ImageLocation = \"$env:TEMP\\modal_preview.jpg\"
${key}PictureBox.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom

# Better than a FileSystemWatcher, apparently!!
${key}PictureTimer = New-Object System.Windows.Forms.Timer
${key}PictureTimer.Interval = 120
${key}PictureTimer.Add_Tick({
    ${key}PictureBox.ImageLocation = ${key}PictureBox.ImageLocation
    # \"$env:NU_ROOT\" | Out-File -FilePath  \"$env:TEMP\\preview_watcher_log.txt\"
})
${key}PictureTimer.Start()

{postinit}
$flowPanel.Controls.Add(${key}PictureBox)
"
        # Rows
        "row-start" => "
$flowPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$flowPanel.FlowDirection = 'LeftToRight'
$flowPanel.AutoSize = $true
$flowPanel.WrapContents = $false
$flowPanel.Padding = '0,0,0,0'
$flowPanel.Margin  = '0,0,0,0'

$rootPanel.Controls.Add($flowPanel)
"
        "row-end" => "
$flowPanel = $rootPanel
"
        _ => {
            error make {
                msg: $"unknown type: ($question.type)"
            }
        }
    }

    ($code
        | str replace -a "{key}" ($question.key? | default '')
        | str replace -a "{label_json}" ($question.label? | to json)
        | str replace -a "{default_json}" ($question.default? | default "" | to json)
        | str replace -a "{options_jsonb64}" ($question.options? | default [] | to json -r | encode base64 | to json)
        | str replace -a "{autofocus}" ($question.autofocus? | default false | to json)
        | str replace -a "{default-0}" ($question.default? | default "0" | into string)
        | str replace -a "{max-null}" ($question.max? | default "$null" | into string)
        | str replace -a "{min-null}" ($question.min? | default "$null" | into string)
        | str replace -a "{step-1}" ($question.step? | default "1" | into string)
        | str replace -a "{decimals-0}" ($question.decimals? | default "0" | into string)
        | str replace -a "{postinit}" ($question.postinit? | default "" | into string)
        | str replace -a "{postnew}" ($question.postnew? | default "" | into string)
        | str replace -a "{preinit}" ($question.preinit? | default "" | into string)
        | str replace -a "{width-276}" ($question.width? | default "276" | into string)
    )
}

def codegen-extract [ questions: list<record> ] {
    mut code = "[ordered]@{\n"

    for question in $questions {
        if $question.key? == null {
            continue
        }

        $code += $"    ($question.key) = "
        $code += match $question.type {
            "text" => $"$($question.key)TextBox.Text\n"
            "number" => $"$($question.key)Numeric.Value\n"
            "dropdown" => $"$($question.key)ComboBox.SelectedIndex\n"
            "picture" => "1\n"
        }
    }

    $code += "}"

    $code
}

def extract-results [ questions: list<record>, results: string ] {
    let results = $results | from json
    if $results == null {
        return $results
    }

    let qmap = $questions | where $it has key | group-by key

    $results | transpose key value | each { |row|
        let q = $qmap | get -o $row.key

        if $q.0?.type == 'dropdown' {
            let item = $q.0.options | get -o $row.value

            if $item == null {
                print -e $"SelectedItem returned an invalid index ($row.value)"

                error make {
                    msg: 'SelectedItem returned an invalid index'
                }
            }

            let mapped = if (type-is $item 'record') and 'label' in $item and 'value' in $item {
                {
                    key: $row.key,
                    value: $item.value
                }
            } else {
                {
                    key: $row.key,
                    value: $item
                }
            }

            return [
                {
                    key: $"($row.key)_index",
                    value: $row.value
                },
                $mapped
            ]
        }

        $row
    } | flatten | transpose -rd
}

export def ps-form [
    --title: string = "Form"
    --questions: list
    --options: record
    # --questions: list<record<key: string, label: string, type: string>>
] {
    let questions = $questions | where $it != null

    mut code = "
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

{preinit}
$form = New-Object System.Windows.Forms.Form
$form.Text = {title_json}
$form.Size = New-Object System.Drawing.Size(300,300)
$form.StartPosition = 'CenterScreen'

# Flow layout panel
$flowPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$flowPanel.Dock = 'Top'
$flowPanel.AutoSize = $true
$flowPanel.FlowDirection = 'TopDown'
$flowPanel.AutoSizeMode = 'GrowAndShrink'
$flowPanel.WrapContents = $false
$rootPanel = $flowPanel
$form.Controls.Add($flowPanel)

{codegen_questions}

# Buttons (put inside their own panel to align neatly)
$buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$buttonPanel.FlowDirection = 'LeftToRight'
$buttonPanel.AutoSizeMode = 'GrowAndShrink'
$buttonPanel.Dock = 'Right'
$buttonPanel.AutoSize = $true
$flowPanel.Controls.Add($buttonPanel)

$cancelButton = New-Object System.Windows.Forms.Button
$cancelButton.Text = 'Cancel'
$cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$buttonPanel.Controls.Add($cancelButton)
$form.CancelButton = $cancelButton

$okButton = New-Object System.Windows.Forms.Button
$okButton.Text = 'OK'
$okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
$buttonPanel.Controls.Add($okButton)
$form.AcceptButton = $okButton

$form.Height = $flowPanel.Height + 50

$form.Topmost = $true
# $form.Add_Shown({$textBox1.Select()})
$result = $form.ShowDialog()

if ($result -eq [System.Windows.Forms.DialogResult]::OK)
{
    echo ({codegen_extract} | ConvertTo-Json)
}
    "

    mut preinit = $options.preinit? | default "" | into string

    if $options.globals? != null {
        let decls = $options.globals | transpose k v | each { |row| $"$($row.k) = ($row.v)" } | str join "\n"

        $preinit = $"($decls)\n($preinit)"
    }

    $code = ($code
        | str replace -a "{preinit}" $preinit
        | str replace -a "{title_json}" ($title | to json)
        | str replace -a "{codegen_questions}" ($questions | each { |q| codegen-question $q } | str join "\n")
        | str replace -a "{codegen_extract}" (codegen-extract $questions)
    )

    # print $code

    let ps1_path = $nu.temp-dir | path join "ps-form.ps1"
    $code | save -f $ps1_path

    # let result = powershell -Command $code
    try {
        $env.NU_ROOT = ($CURRENT_PATH | path dirname | path dirname)

        let result = powershell -NoProfile -ExecutionPolicy Bypass -File $ps1_path | complete

        print $result

        extract-results $questions $result.stdout
    } catch { |e|
        print $e
    }
}
