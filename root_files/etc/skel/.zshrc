# zsh configuration (https://github.com/GitHub-MrAnnonymus/Shell-configs). The plugins
# come from the image (/usr/share/zsh/plugins), not from downloads into the home.

# Completions (zsh-completions installs into the default $fpath)
autoload -Uz compinit && compinit

# Prompt: oh-my-posh with the zen theme (~/.config/ohmyposh/zen.toml)
eval "$(oh-my-posh init zsh --config $HOME/.config/ohmyposh/zen.toml)"

# Keybindings
bindkey -e
bindkey '^p' history-search-backward
bindkey '^n' history-search-forward
bindkey '^[w' kill-region
bindkey "\e[3~" delete-char

# Esc Esc puts run0 in front of the current or the previous command.
run0-command-line() {
  [[ -z $BUFFER ]] && LBUFFER="$(fc -ln -1)"
  if [[ $BUFFER == run0\ * ]]; then
    LBUFFER="${LBUFFER#run0 }"
  else
    LBUFFER="run0 $LBUFFER"
  fi
}
zle -N run0-command-line
bindkey '\e\e' run0-command-line

# History
HISTSIZE=5000
HISTFILE=~/.zsh_history
SAVEHIST=$HISTSIZE
HISTDUP=erase
setopt appendhistory
setopt sharehistory
setopt hist_ignore_space
setopt hist_ignore_all_dups
setopt hist_save_no_dups
setopt hist_ignore_dups
setopt hist_find_no_dups

# Completion styling
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*' menu no
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'ls --color $realpath'
zstyle ':fzf-tab:complete:__zoxide_z:*' fzf-preview 'ls --color $realpath'

# Aliases
alias ls='ls --color'
alias vim='nvim'
alias c='clear'

# Shell integrations
eval "$(zoxide init --cmd cd zsh)"
eval "$(atuin init zsh)"

# Plugins: fzf-tab after compinit, syntax highlighting last.
source /usr/share/zsh/plugins/fzf-tab/fzf-tab.plugin.zsh
source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
