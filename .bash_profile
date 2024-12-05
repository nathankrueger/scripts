export PATH="${PATH}:~/bin"
export PATH="${PATH}:/Applications/Visual Studio Code.app/Contents/Resources/app/bin"

### NAVIGATION
alias cls=clear
alias u='cd ..'
alias u2='cd ../../'
alias u3='cd ../../../'
alias u4='cd ../../../../'
alias u5='cd ../../../../../'
alias u6='cd ../../../../../../'
alias als='vim ~/.bash_profile'
alias src='source ~/.bash_profile'
alias la='ls -laht'
alias l='ls -laht'
alias dir='ls -laht'

### COMMON DIRECTORIES
alias scripts='cd ~/Documents/Scripts/'
alias bk='cd ~/Documents/Scripts/Backup'
alias pcat='cd ~/Documents/Programming/Python/pycatalog'
alias pyp='cd ~/Documents/Programming/Python'
alias mp3='cd ~/Music/MP3s'

### MISC
alias als='vim ~/.bash_profile'
alias src='source ~/.bash_profile'
alias start='open -a Terminal "`pwd`"'
mcd_func() { mkdir -p $1 && cd $1; set +f; }
alias mcd='set -f;mcd_func'
alias m='make'
alias v='vim'
alias h='history'
open_func() { open $1; set +f; }
alias o='set -f;open_func'


### LAUNCHERS
pycatalog_func() { python3 /Users/nathankrueger/Documents/Programming/Python/pycatalog/pycatalog.py $@;set +f; }
tw_func() { open -a TextWrangler $@;set +f; }
ytubedl_v_func() { yt-dlp_macos $1 -R 1000 -f $(yt-dlp_macos $1 -F | tail -n 1 | cut -d ' ' -f1);set +f; }
ytubedl_a_func() { yt-dlp_macos $1 -x --audio-format=mp3 --audio-quality=0;set +f; }
alias pc='set -f;pycatalog_func'
alias tw='set -f;tw_func'
alias f='open -a Finder "`pwd`"'
alias ydlv='set -f;ytubedl_v_func'
alias ydla='set -f;ytubedl_a_func'

export BASH_SILENCE_DEPRECATION_WARNING=1
export PS1='[\w]\$ '
