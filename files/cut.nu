use ../scripts/_vid.nu *

def inputbox [ title, text, default ] {
    powershell -Command $"
        Add-Type -AssemblyName Microsoft.VisualBasic;
        [Microsoft.VisualBasic.Interaction]::InputBox\('($title)', '($text)', '($default)')
    "
}

def main [ file: string ] {
    let start = inputbox start time 0 | default -e '0'
    let end = inputbox end time 0 | default -e '0'

    vcut $file $start $end 50mib --codec h264_nvenc
    print $"($start) ($end)"
}
