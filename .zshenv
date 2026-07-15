# Ensure zsh's built-in functions directory is in fpath for the running version.
# This guards against the compiled-in path becoming stale after a brew upgrade
# and against a stale FPATH being inherited from a pre-upgrade shell process.
fpath=("/opt/homebrew/Cellar/zsh/${ZSH_VERSION}/share/zsh/functions" "${(@)fpath:#*/Cellar/zsh/*/share/zsh/functions}")

export ZDOTDIR="${XDG_CONFIG_HOME:-${HOME}/.config}/zsh"

. "${ZDOTDIR}/.zshenv"
