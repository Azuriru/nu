alias core-mv = mv
alias mv = mv -n

# Cargo aliases
alias crun = cargo run --
alias crunrelease = cargo run --release --

# File explorer shortcuts
def ex [] { explorer . | complete | ignore }

# Node pnpm
alias pn = pnpm

# YTDL "config"
alias ytdl = yt-dlp.exe -o ($env.USERPROFILE + '\Downloads\%(title)s [%(id)s].%(ext)s')
alias ytdl-mp3 = yt-dlp.exe --extract-audio --audio-format mp3 -o ($env.USERPROFILE + '\Downloads\%(title)s [%(id)s].%(ext)s')
alias ytdlc = yt-dlp.exe -o ($env.PWD | path join '%(title)s [%(id)s].%(ext)s')
alias yt = ytdl (bp)

# Brain shortcuts
alias cwd = pwd

# Restart nushell without 17 nested layers
alias nux = exec nu

# Not strictly an alias but better than mkdir
def --env md [path: path] {
    mkdir $path
    cd $path
}

def pwd [] {
    $env.PWD
}

alias copyparty = python ~/Code/.tests/py/copyparty-sfx.py
