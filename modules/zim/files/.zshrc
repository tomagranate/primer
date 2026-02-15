# >>> PRIMER MANAGED START (modules/zim/files/.zshrc) >>>
# ------- Zim Setup -------

# Initialize zim
ZIM_HOME=~/.zim

# Download zimfw plugin manager if missing
if [[ ! -e ${ZIM_HOME}/zimfw.zsh ]]; then
  curl -fsSL --create-dirs -o ${ZIM_HOME}/zimfw.zsh \
      https://github.com/zimfw/zimfw/releases/latest/download/zimfw.zsh
fi

# Install missing modules, and update ${ZIM_HOME}/init.zsh if missing or outdated
if [[ ! ${ZIM_HOME}/init.zsh -nt ${ZIM_CONFIG_FILE:-${ZDOTDIR:-${HOME}}/.zimrc} ]]; then
  source ${ZIM_HOME}/zimfw.zsh init -q
fi

# Initialize modules.
source ${ZIM_HOME}/init.zsh

# ---- Configuration ----
# history
HISTFILE=~/.zsh_history
export HISTSIZE=10000000
export SAVEHIST=10000000
setopt appendhistory

# ghostty fix
export TERM=xterm-256color

# zsh-history-substring-search
export HISTORY_SUBSTRING_SEARCH_ENSURE_UNIQUE=1

# fzf
export FZF_DEFAULT_COMMAND="rg --files --hidden --glob '!.git'"
export FZF_DEFAULT_OPTS="--layout=reverse --style=full --border --ansi"

# ---- Aliases ----
alias ls="eza"
alias ll="ls -lah"
alias du="dust"
alias df="duf"
alias top="htop"
alias docker-kill-all='docker stop $(docker ps -q) && docker rm $(docker ps -aq)'
alias port="lsof -i -P | grep LISTEN | grep $1"
alias editrc="nvim ~/.zshrc"

# ---- Path updates ----
path+=~/bin
path+=~/.local/bin
path+=~/.bun/bin

# ---- Keybindings ----
bindkey '\ew' backward-kill-line  # cmd-backspace

# ---- pnpm ----
export PNPM_HOME="$HOME/Library/pnpm"
case ":$PATH:" in
  *":$PNPM_HOME:"*) ;;
  *) export PATH="$PNPM_HOME:$PATH" ;;
esac

# ---- Mise ----
eval "$(mise activate zsh)"

# ---- bun completions ----
[ -s "$HOME/.bun/_bun" ] && source "$HOME/.bun/_bun"

# ---- Android dev ----
export ANDROID_HOME=$HOME/Library/Android/sdk
path+=$ANDROID_HOME/emulator
PATH=$PATH:$ANDROID_HOME/platform-tools
# <<< PRIMER MANAGED END (modules/zim/files/.zshrc) <<<
