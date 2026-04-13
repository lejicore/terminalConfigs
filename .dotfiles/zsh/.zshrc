[[ -n $INSIDE_AIDER ]] && return
is_socket_x0() {
if [ -x "/tmp/.X11-unix/X0" ]; then
    echo "Socket X0 running."
else
    nohup socat -b65536 UNIX-LISTEN:/tmp/.X11-unix/X0,fork,mode=777 VSOCK-CONNECT:2:6000 &
    Echo "Socket starting."
fi
}

function_name (){
  toilet "Hello Ox"
  if [[ "$(uname -a | cut -d' ' -f2)" == "arch" ]]; then
    cowsay "The system is running Arch Linux"
    export XDG_RUNTIME_DIR=/run/user/$(id -u)
  elif [[ "$(uname -a | cut -d' ' -f1)" == "Darwin" ]]; then
    cowsay "The system is running macOS"
    #export XDG_RUNTIME_DIR=$TMPDIR
  elif [[ "$(uname -a | cut -d' ' -f3 | cut -d'-' -f4)" == "WSL2" ]]; then
    export XDG_RUNTIME_DIR=/run/user/$(id -u)
    cowsay "The system is running under WSL2"
    #sudo service ssh start
    #for wsl2 if gui application is set to true in c://Users/Myuser/.wslconfig
    # then i am not using vcxsrv and no need to export the DISPLAY var 
    #export DISPLAY=$(ip route|awk '/^default/{print $3}'):0.0
    #export DISPLAY=$(ip route|awk '/^default/{print $3}'):0.0

    #For X410 with socket connection "VSOCK"
    export DISPLAY=:0.0
    is_socket_x0
    export HOST_IP="$(ip route |awk '/^default/{print $3}')"
    export PULSE_SERVER="tcp:$HOST_IP"

    # export DISPLAY="`sed -n 's/nameserver //p' /etc/resolv.conf`:0.0"
    #export LIBGL_ALWAYS_INDIRECT=0
    # export DISPLAY=$(cat /etc/resolv.conf | grep nameserver | awk '{print $2; exit;}'):0.0

    #Only for wsl to have a notify-send like
    notify-send() { wsl-notify-send.exe --category $WSL_DISTRO_NAME "${@}"; }
  else
    echo "The system is running something strange O.O"

  fi
  #neofetch
  fortune > fortune;
  lolcat  fortune 2>/dev/null
  rm fortune
}
function_name

#Auto-launching ssh-agent to save passphrases

function sshe(){
  env=~/.ssh/agent.env

  agent_load_env () { test -f "$env" && . "$env" >| /dev/null ; }

  agent_start () {
    (umask 077; ssh-agent >| "$env")
    . "$env" >| /dev/null ; }

  agent_load_env

  # agent_run_state: 0=agent running w/ key; 1=agent w/o key; 2= agent not running
  agent_run_state=$(ssh-add -l >| /dev/null 2>&1; echo $?)

  if [ ! "$SSH_AUTH_SOCK" ] || [ $agent_run_state = 2 ]; then
    agent_start
    ssh-add ~/.ssh/id_* 2>/dev/null # Add all private keys
  elif [ "$SSH_AUTH_SOCK" ] && [ $agent_run_state = 1 ]; then
    ssh-add ~/.ssh/id_* 2>/dev/null
  fi

  unset env
  echo "ssh-agent running"
}
sshe

# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
# Initialization code that may require console input (password prompts, [y/n]
# confirmations, etc.) must go above this block; everything else may go below.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi


#nvr -s


# If you come from bash you might have to change your $PATH.
# export PATH=$HOME/bin:/usr/local/bin:$PATH

# Path to your oh-my-zsh installation.
export ZSH="$HOME/.oh-my-zsh"

# Set name of the theme to load --- if set to "random", it will
# load a random theme each time oh-my-zsh is loaded, in which case,
# to know which specific one was loaded, run: echo $RANDOM_THEME
# See https://github.com/ohmyzsh/ohmyzsh/wiki/Themes
ZSH_THEME=powerlevel10k/powerlevel10k
#ZSH_THEME="robbyrussell"

# Set list of themes to pick from when loading at random
# Setting this variable when ZSH_THEME=random will cause zsh to load
# a theme from this variable instead of looking in $ZSH/themes/
# If set to an empty array, this variable will have no effect.
# ZSH_THEME_RANDOM_CANDIDATES=( "robbyrussell" "agnoster" )

# Uncomment the following line to use case-sensitive completion.
# CASE_SENSITIVE="true"

# Uncomment the following line to use hyphen-insensitive completion.
# Case-sensitive completion must be off. _ and - will be interchangeable.
# HYPHEN_INSENSITIVE="true"

# Uncomment the following line to disable bi-weekly auto-update checks.
# DISABLE_AUTO_UPDATE="true"

# Uncomment the following line to automatically update without prompting.
# DISABLE_UPDATE_PROMPT="true"

# Uncomment the following line to change how often to auto-update (in days).
# export UPDATE_ZSH_DAYS=13

# Uncomment the following line if pasting URLs and other text is messed up.
# DISABLE_MAGIC_FUNCTIONS="true"

# Uncomment the following line to disable colors in ls.
# DISABLE_LS_COLORS="true"

# Uncomment the following line to disable auto-setting terminal title.
# DISABLE_AUTO_TITLE="true"

# Uncomment the following line to enable command auto-correction.
# ENABLE_CORRECTION="true"

# Uncomment the following line to display red dots whilst waiting for completion.
# Caution: this setting can cause issues with multiline prompts (zsh 5.7.1 and newer seem to work)
# See https://github.com/ohmyzsh/ohmyzsh/issues/5765
# COMPLETION_WAITING_DOTS="true"

# Uncomment the following line if you want to disable marking untracked files
# under VCS as dirty. This makes repository status check for large repositories
# much, much faster.
# DISABLE_UNTRACKED_FILES_DIRTY="true"

# Uncomment the following line if you want to change the command execution time
# stamp shown in the history command output.
# You can set one of the optional three formats:
# "mm/dd/yyyy"|"dd.mm.yyyy"|"yyyy-mm-dd"
# or set a custom format using the strftime function format specifications,
# see 'man strftime' for details.
# HIST_STAMPS="mm/dd/yyyy"

# Would you like to use another custom folder than $ZSH/custom?
# ZSH_CUSTOM=/path/to/new-custom-folder

# Which plugins would you like to load?
# Standard plugins can be found in $ZSH/plugins/
# Custom plugins may be added to $ZSH_CUSTOM/plugins/
# Example format: plugins=(rails git textmate ruby lighthouse)
# Add wisely, as too many plugins slow down shell startup.
#plugins=(git z zsh-autosuggestions zsh-syntax-highlighting)
plugins=(git z zsh-autosuggestions aliases web-search zsh-syntax-highlighting zsh-history-substring-search direnv direnv)
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=5'

source $ZSH/oh-my-zsh.sh

# User configuration

# export MANPATH="/usr/local/man:$MANPATH"
# You may need to manually set your language environment
export LANG=en_US.UTF-8

# Preferred editor for local and remote sessions
# if [[ -n $SSH_CONNECTION ]]; then
#   export EDITOR='vim'
# else
#   export EDITOR='mvim'
# fi
#export VISUAL='nvr -l'
#export VISUAL='nvim'
export VISUAL='emacsclient -n'
#export EDITOR="$VISUAL"
export EDITOR='emacsclient -n'

# Compilation flags
# export ARCHFLAGS="-arch x86_64"

# Set personal aliases, overriding those provided by oh-my-zsh libs,
# plugins, and themes. Aliases can be placed here, though oh-my-zsh
# users are encouraged to define aliases within the ZSH_CUSTOM folder.
# For a full list of active aliases, run `alias`.
#
# Example aliases
# alias zshconfig="mate ~/.zshrc"
# alias ohmyzsh="mate ~/.oh-my-zsh"

# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
ZSH_WEB_SEARCH_ENGINES=(dev "https://devdocs.io/#q=")
alias dev="web_search dev $@"

#alias home-manager="nix run home-manager -- $@"
#alias hms="nix run home-manager -- $@ switch --flake"
alias e="emacsclient -r -n"
alias ls='lsd --hyperlink=auto'
alias l='ls -l --hyperlink=auto'
alias la='ls -a --hyperlink=auto'
alias lla='ls -la --hyperlink=auto'
alias lt='ls --tree --hyperlink=auto'
alias c='cht.sh'
alias ecn='emacsclient -n'
#alias zz="z && ls"
alias kssh='kitty +kitten ssh'
alias kdeb='kitty +kitten ssh debian'
#with exec instead of alias to execute it from the file name it is stored
alias mg='kitty +kitten hyperlinked_grep --smart-case "$@"'
alias deb='ssh ledeb'
alias ts='tmux-sessionizer'
alias tt='tmux-attacher'
alias lg='lazygit'
export PATH="$HOME/scripts:$PATH"
export PATH="$PATH:/opt/nvim-linux64/bin"
export GOPATH="$HOME/go"
export PATH="$PATH:$GOPATH/bin"

# Set GPG_TTY to the correct tty
if [ -n "$TMUX" ]; then
  export GPG_TTY=$(tmux display-message -p '#{pane_tty}')
else
  export GPG_TTY=$(tty)
fi
if [[ -f ~/terminalConfigs/.aider.gpg ]]; then
    source <(gpg --quiet --decrypt ~/terminalConfigs/.aider.gpg 2>/dev/null) 
fi
gpg-connect-agent updatestartuptty /bye >/dev/null


#bindkey -s '^o' 'tmux-sessionizer^M'

functin zz(){
z $1
ls
}
function bt(){
    if [[ "$OSTYPE" == "darwin"* ]]; then
	fzf --preview 'bat --color=always --style=numbers --line-range=:500 {}'
    elif [[ "$OSTYPE" == "linux"* ]]; then
	fzf --preview 'batcat --color=always --style=numbers --line-range=:500 {}'
    fi

}



alias luamake=$HOME/builds/lua-language-server/3rd/luamake/luamake

#node = "${node -v}"
#source /usr/share/nvm/init-nvm.sh
eval "$(nodenv init - zsh)"
Command() { echo "$(node -v)"; }
result=$(Command)
# Load Angular CLI autocompletion.
if [[ "$result" == "v16.10.0" ]]; then
  source <(ng completion script)
fi
#export TERM=tmux-256color
# export TERM=xterm-256color
#export NVIM_LISTEN_ADDRESS=/tmp/nvim-$(basename $PWD)
export NVIM_APPNAME="nvim"
## uncomment below line to allow shell integration with wezterm using wezterm.sh
#source ~/wezterm.sh
if [ "$INSIDE_EMACS" = 'vterm' ]; then
    export TERM=xterm-256color
else
    export TERM=xterm-kitty
fi
# for vterm of emacs to pass messages between vterm and the shell
vterm_printf(){
  if [ -n "$TMUX" ] && ([ "${TERM%%-*}" = "tmux" ] || [ "${TERM%%-*}" = "screen" ] ); then
    # Tell tmux to pass the escape sequences through
    printf "\ePtmux;\e\e]%s\007\e\\" "$1"
  elif [ "${TERM%%-*}" = "screen" ]; then
    # GNU screen (screen, screen-256color, screen-256color-bce)
    printf "\eP\e]%s\007\e\\" "$1"
  else
    printf "\e]%s\e\\" "$1"
  fi
}

HISTSIZE=20000
SAVEHIST=20000

[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh
export PYENV_ROOT="$HOME/.pyenv"
command -v pyenv >/dev/null || export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"

# to ini phpenv
eval "$(phpenv init -)"

# >>> conda initialize >>>
# !! Contents within this block are managed by 'conda init' !!
__conda_setup="$('$HOME/miniconda3/bin/conda' 'shell.zsh' 'hook' 2> /dev/null)"
if [ $? -eq 0 ]; then
    eval "$__conda_setup"
else
    if [ -f "$HOME/miniconda3/etc/profile.d/conda.sh" ]; then
        . "$HOME/miniconda3/etc/profile.d/conda.sh"
    else
        export PATH="$HOME/miniconda3/bin:$PATH"
    fi
fi
unset __conda_setup
# <<< conda initialize <<<


# To customize prompt, run `p10k configure` or edit ~/Documents/builds/terminalConfigs/.dotfiles/zsh/.p10k.zsh.
[[ ! -f ~/Documents/builds/terminalConfigs/.dotfiles/zsh/.p10k.zsh ]] || source ~/Documents/builds/terminalConfigs/.dotfiles/zsh/.p10k.zsh
#source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion

. "$HOME/.atuin/bin/env"
eval "$(atuin init zsh)"

#THIS MUST BE AT THE END OF THE FILE FOR SDKMAN TO WORK!!!

export SDKMAN_DIR="$HOME/.sdkman"
[[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]] && source "$HOME/.sdkman/bin/sdkman-init.sh"

# To customize prompt, run `p10k configure` or edit ~/terminalConfigs/.dotfiles/zsh/.p10k.zsh.
[[ ! -f ~/terminalConfigs/.dotfiles/zsh/.p10k.zsh ]] || source ~/terminalConfigs/.dotfiles/zsh/.p10k.zsh

. "$HOME/.local/bin/env"
