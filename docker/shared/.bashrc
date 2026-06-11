# Shared bash configuration. bash is the container's default shell ($SHELL), so
# the agent harnesses' Bash tools inherit bash/POSIX semantics (word-splitting,
# 0-indexed arrays) that match the models' prior — see docker/base/Dockerfile.
# Humans get zsh instead (the login shell, and what `launch-agent --shell` opens),
# configured by the sibling .zshrc. PATH and EDITOR come from the image ENV, so
# they are deliberately not set here.

# Everything below is an interactive nicety; a non-interactive shell (the agent's
# one-shot `bash -c`) needs none of it, so bail out early.
case $- in
  *i*) ;;
  *) return ;;
esac

# History — reuse the existing persistent shell-history volume (mounted at
# ~/.zsh_history_dir) rather than declaring a second one.
HISTFILE=~/.zsh_history_dir/.bash_history
HISTSIZE=5000
HISTFILESIZE=5000
shopt -s histappend

# Git-aware completion, when the package is present (guarded — absence is fine).
if [ -f /usr/share/bash-completion/bash_completion ]; then
  # shellcheck source=/dev/null
  . /usr/share/bash-completion/bash_completion
fi

# Container identity in the prompt (mirrors the zsh prompt).
if [ -n "$CONTAINER_NAME" ]; then
  PS1='\[\e[33m\][$CONTAINER_NAME]\[\e[0m\] \w \$ '
fi
