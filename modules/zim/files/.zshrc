# ==== Homebrew ====
eval "$(/opt/homebrew/bin/brew shellenv)"

# ==== Zim ====
ZIM_HOME=~/.zim
if [[ ! -e ${ZIM_HOME}/zimfw.zsh ]]; then
  curl -fsSL --create-dirs -o ${ZIM_HOME}/zimfw.zsh \
    https://github.com/zimfw/zimfw/releases/latest/download/zimfw.zsh
fi
if [[ ! ${ZIM_HOME}/init.zsh -nt ${ZDOTDIR:-${HOME}}/.zimrc ]]; then
  source ${ZIM_HOME}/zimfw.zsh init -q
fi
source ${ZIM_HOME}/init.zsh

# ==== Mise ====
eval "$(mise activate zsh)"

# ==== fzf ====
export FZF_DEFAULT_OPTS="--layout=reverse --height=~100% --border --ansi --exit-0"
source <(fzf --zsh)

# ==== difftastic ====
export DFT_DISPLAY=side-by-side-show-both
git config --global diff.external difft

# ==== PATH ====
export PATH="$HOME/bin:$PATH"

# ==== Aliases ====
alias editrc="code ~/.config/zsh/.zshrc"

# ==== Functions ====

# Remove local branches whose remote tracking branch is gone
gitclean() {
  git fetch -p
  for branch in $(git for-each-ref --format '%(refname) %(upstream:track)' refs/heads | awk '$2 == "[gone]" {sub("refs/heads/", "", $1); print $1}'); do
    git branch -D "$branch"
  done
}

# Kill whatever process is listening on the given port
killport() {
  lsof -i "TCP:$1" | grep LISTEN | awk '{print $2}' | xargs kill -9
}
