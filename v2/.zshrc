### Added by Zinit's installer
if [[ ! -f $HOME/.local/share/zinit/zinit.git/zinit.zsh ]]; then
    print -P "%F{33} %F{220}Installing %F{33}ZDHARMA-CONTINUUM%F{220} Initiative Plugin Manager (%F{33}zdharma-continuum/zinit%F{220})…%f"
    command mkdir -p "$HOME/.local/share/zinit" && command chmod g-rwX "$HOME/.local/share/zinit"
    command git clone https://github.com/zdharma-continuum/zinit "$HOME/.local/share/zinit/zinit.git" && \
        print -P "%F{33} %F{34}Installation successful.%f%b" || \
        print -P "%F{160} The clone has failed.%f%b"
fi

source "$HOME/.local/share/zinit/zinit.git/zinit.zsh"
autoload -Uz _zinit
(( ${+_comps} )) && _comps[zinit]=_zinit
### End of Zinit's installer chunk

## ==== Load Zsh plugins and CLI tools ====
zinit ice wait lucid --depth=1 atinit"zicompinit; zicdreplay"
zinit light zdharma-continuum/fast-syntax-highlighting

zinit ice wait lucid --depth=1 atload"bindkey '^[[A' history-substring-search-up; bindkey '^[[B' history-substring-search-down"
zinit light zsh-users/zsh-history-substring-search

zinit ice wait lucid --depth=1 atload"_zsh_autosuggest_start"
zinit light zsh-users/zsh-autosuggestions

zinit ice wait lucid --depth=1 as"program" from"gh-r" pick"difft" atclone"git config --global diff.external difft"
zinit light Wilfred/difftastic

zinit ice wait lucid --depth=1 \
    as"command" from"gh-r" mv"mise* -> mise" pick"mise/mise" atload'eval "$(mise activate zsh)"'
zinit light jdx/mise

export FZF_DEFAULT_OPTS="--layout=reverse --height=~100% --border --ansi --exit-0"
zinit ice wait lucid --depth=1 as"command" from"gh-r" mv"fzf* -> fzf" pick"fzf/fzf" atload"source <(fzf --zsh)"
zinit light junegunn/fzf

zinit ice wait lucid --depth=1 as"command" from"gh-r" mv"ripgrep* -> rg" pick"rg/rg"
zinit light BurntSushi/ripgrep

zinit ice wait lucid --depth=1 as"command" from"gh-r" mv"fd* -> fd" pick"fd/fd"
zinit light sharkdp/fd

zinit snippet OMZP::git

### Commented out until they release an aarm-apple-darwin version. 
### Not there as of 0.24.0 - already in master branch though, just need them to make another release
### Currently installed via brew
# zinit ice wait lucid --depth=1 as"command" from"gh-r" mv"bat* -> bat" pick"bat/bat"
# zinit light sharkdp/bat

zinit ice wait lucid --depth=1 as"command" from"gh-r" mv"jq* -> jq" pick"jq/jq"
zinit light jqlang/jq

zinit ice wait lucid --depth=1 atpull"zinit creinstall -q ." blockf
zinit light zsh-users/zsh-completions

## ======= Custom Scripts =======
export PATH=$PATH:~/bin

## ==== Prompt ====
zinit ice as"command" from"gh-r" \
          atclone"./starship init zsh > init.zsh; ./starship completions zsh > _starship" \
          atpull"%atclone" src"init.zsh"
zinit light starship/starship
