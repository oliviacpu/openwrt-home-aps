# Root shell for this access point: zsh + Oh My Zsh (core) + Oh My Posh.
# Baked into the image by github.com/oliviacpu/openwrt-wax214v2 (overlay/root/.zshrc); edit it there.
# A per-site prompt config (~/.config/oh-my-posh/hosts.omp.json) and iTerm2 integration can be pushed
# separately; without them Oh My Posh uses its default theme.
export ZSH=/usr/share/oh-my-zsh
ZSH_CACHE_DIR=$HOME/.cache/oh-my-zsh   # keep it out of /usr/share; written rarely
ZSH_DISABLE_COMPFIX=true               # skip compaudit: slow on this CPU, and root is the only user
ZSH_THEME=""                           # prompt comes from Oh My Posh
zstyle ':omz:update' mode disabled     # updates come with the image
plugins=()
[ -r $ZSH/oh-my-zsh.sh ] && source $ZSH/oh-my-zsh.sh

# Oh My Posh rewrites its cache on every prompt, so keep it in RAM, not flash.
# It only uses XDG_CACHE_HOME if the directory already exists.
export XDG_CACHE_HOME=/tmp/.cache
[[ -d $XDG_CACHE_HOME ]] || mkdir -p $XDG_CACHE_HOME
export POSH_HOST=netgear
if [[ -x /usr/bin/oh-my-posh ]]; then
  if [[ -r ~/.config/oh-my-posh/hosts.omp.json ]]; then
    eval "$(oh-my-posh init zsh --config ~/.config/oh-my-posh/hosts.omp.json)"
  else
    eval "$(oh-my-posh init zsh)"
  fi
fi
iterm2_hostname=netgear
if [[ -e ~/.iterm2_shell_integration.zsh ]]; then source ~/.iterm2_shell_integration.zsh; fi

# Status card on interactive login (firmware, health, uplink, radios, roaming peers).
if [[ -o login ]] && (( $+commands[ap-status] )); then ap-status; fi
