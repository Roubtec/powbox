# History
HISTFILE=~/.zsh_history_dir/.zsh_history
HISTSIZE=5000
SAVEHIST=5000
bindkey -e

# Completion
autoload -Uz compinit
compinit

# Oh My Zsh
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"
plugins=(git)

# Disable auto-updates (container image is rebuilt for updates)
zstyle ':omz:update' mode disabled

source "$ZSH/oh-my-zsh.sh"

# Container identity
if [ -n "$CONTAINER_NAME" ]; then
  PROMPT="%{$fg[yellow]%}[$CONTAINER_NAME]%{$reset_color%} $PROMPT"
fi

# Note: the shared image store is mounted READ-ONLY in agent containers, so it
# can't be seeded from inside here (the launcher seeds it from a dedicated writer
# on each launch). `seed-image-store.sh status` still works (file checks only);
# use `podman images` to see which cached images resolve via additionalimagestores.
