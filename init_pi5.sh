#!/usr/bin/env bash
# Setup script for a fresh Raspberry Pi 5 image. Interactive numbered menu;
# each item is idempotent and reports its current state.
#
# Adding a new setup item:
#   1. define <name>_apply and <name>_status functions
#   2. add "<name>|Human label" to the ITEMS array
set -u

# ---------- globals ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IFACE="wlan0"
POWERSAVE_CONF="/etc/NetworkManager/conf.d/wifi-powersave-off.conf"
LOGIND_DROPIN_DIR="/etc/systemd/logind.conf.d"
LOGIND_DROPIN="${LOGIND_DROPIN_DIR}/pi5-powerkey.conf"
PACKAGES=(vim jq tmux gh iperf3)
GIT_USER_NAME="Nathan Krueger"
GIT_USER_EMAIL="natekrueger805@gmail.com"
VIMRC_SRC="${SCRIPT_DIR}/.vimrc"
ALIASES_BEGIN="# >>> init_pi5 aliases >>>"
ALIASES_END="# <<< init_pi5 aliases <<<"

# ---------- helpers ----------
# Returns non-zero (instead of exiting) so the menu can continue when a
# user-level item is selected from a non-root invocation.
require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "must be run as root (try: sudo $0)" >&2
        return 1
    fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# Resolve the home dir of the real user even when invoked via sudo.
target_home() {
    if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
        getent passwd "$SUDO_USER" | cut -d: -f6
    else
        echo "$HOME"
    fi
}

# Run a command as the real user when invoked via sudo; otherwise run directly.
as_user() {
    if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
        sudo -u "$SUDO_USER" -H "$@"
    else
        "$@"
    fi
}

# ---------- wifi power-save ----------
wifi_powersave_apply() {
    require_root || return 1
    mkdir -p "$(dirname "$POWERSAVE_CONF")"
    cat > "$POWERSAVE_CONF" <<EOF
# Pi WiFi power-save makes SSH stall and breaks pycatalog worker heartbeats.
# Disable globally for all wifi connections.
[connection]
wifi.powersave = 2
EOF
    systemctl reload NetworkManager
    # NM reload only affects new activations; force the live interface now.
    if have iw; then
        iw dev "$IFACE" set power_save off 2>/dev/null || true
    fi
    echo "wrote $POWERSAVE_CONF and applied to $IFACE"
}

wifi_powersave_status() {
    local conf_ok=0 live_ok=0
    if [[ -f "$POWERSAVE_CONF" ]] && grep -q '^wifi.powersave *= *2' "$POWERSAVE_CONF"; then
        conf_ok=1
    fi
    if have iw && iw dev "$IFACE" get power_save 2>/dev/null | grep -q 'off'; then
        live_ok=1
    fi
    if (( conf_ok && live_ok )); then echo "ok"
    elif (( conf_ok || live_ok )); then echo "partial"
    else echo "missing"
    fi
}

# ---------- power button ----------
power_button_apply() {
    require_root || return 1
    mkdir -p "$LOGIND_DROPIN_DIR"
    cat > "$LOGIND_DROPIN" <<EOF
[Login]
HandlePowerKey=poweroff
PowerKeyIgnoreInhibited=yes
EOF
    systemctl restart systemd-logind
    systemctl --global mask pwrkey-handler.service
    echo "wrote $LOGIND_DROPIN and masked pwrkey-handler.service"
}

power_button_status() {
    local conf_ok=0 mask_ok=0
    if [[ -f "$LOGIND_DROPIN" ]] \
        && grep -q '^HandlePowerKey=poweroff' "$LOGIND_DROPIN" \
        && grep -q '^PowerKeyIgnoreInhibited=yes' "$LOGIND_DROPIN"; then
        conf_ok=1
    fi
    if systemctl --global is-enabled pwrkey-handler.service 2>/dev/null | grep -q '^masked$'; then
        mask_ok=1
    fi
    if (( conf_ok && mask_ok )); then echo "ok"
    elif (( conf_ok || mask_ok )); then echo "partial"
    else echo "missing"
    fi
}

# ---------- packages ----------
packages_apply() {
    require_root || return 1
    apt-get update
    apt-get install -y "${PACKAGES[@]}"
}

packages_status() {
    local missing=()
    for pkg in "${PACKAGES[@]}"; do
        dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    done
    if (( ${#missing[@]} == 0 )); then
        echo "ok"
    elif (( ${#missing[@]} == ${#PACKAGES[@]} )); then
        echo "missing"
    else
        echo "partial: ${missing[*]} missing"
    fi
}

# ---------- gh auth ----------
gh_auth_apply() {
    if ! have gh; then
        echo "gh is not installed yet — run the packages step first" >&2
        return 1
    fi
    cat <<'NOTE'

gh auth login (device flow):
  - Pick GitHub.com, HTTPS, "Login with a web browser".
  - gh will print a one-time code; open this URL on any device with a browser:
        https://github.com/login/device
  - Paste the code, approve, then return here.

NOTE
    as_user gh auth login --hostname github.com --git-protocol https --web || return 1
    as_user gh auth setup-git || return 1
    as_user gh auth status
    echo
    # gh auth setup-git writes the helper under the per-host key
    # (credential.https://github.com.helper), NOT the unscoped credential.helper.
    # `git config --get-urlmatch` is what git itself uses to resolve a helper
    # for a URL, so it's the authoritative check.
    echo "verifying credential helper for https://github.com/..."
    local helper
    helper=$(as_user git config --get-urlmatch credential.helper https://github.com/x 2>/dev/null || true)
    echo "  resolved -> ${helper:-<unset>}"
    if [[ "$helper" == *"gh auth git-credential"* ]]; then
        echo "  OK: gh is the credential helper"
    else
        echo "  WARN: expected output to contain 'gh auth git-credential'"
        return 1
    fi
}

gh_auth_status() {
    if ! have gh; then echo "missing"; return; fi
    if ! as_user gh auth status >/dev/null 2>&1; then echo "missing"; return; fi
    if as_user git config --get-urlmatch credential.helper https://github.com/x 2>/dev/null \
        | grep -q 'gh auth git-credential'; then
        echo "ok"
    else
        echo "partial: logged in but gh not set as credential helper"
    fi
}

# ---------- git identity ----------
git_identity_apply() {
    as_user git config --global user.name "$GIT_USER_NAME"
    as_user git config --global user.email "$GIT_USER_EMAIL"
    echo "set git user.name='$GIT_USER_NAME', user.email='$GIT_USER_EMAIL'"
}

git_identity_status() {
    local cur_name cur_email
    cur_name=$(as_user git config --global user.name 2>/dev/null || true)
    cur_email=$(as_user git config --global user.email 2>/dev/null || true)
    if [[ "$cur_name" == "$GIT_USER_NAME" && "$cur_email" == "$GIT_USER_EMAIL" ]]; then
        echo "ok"
    elif [[ -z "$cur_name" && -z "$cur_email" ]]; then
        echo "missing"
    else
        echo "partial: name='$cur_name' email='$cur_email'"
    fi
}

# ---------- vimrc ----------
vimrc_apply() {
    if [[ ! -f "$VIMRC_SRC" ]]; then
        echo "source $VIMRC_SRC not found" >&2
        return 1
    fi
    local dst="$(target_home)/.vimrc"
    as_user cp "$VIMRC_SRC" "$dst"
    echo "installed $VIMRC_SRC -> $dst"
}

vimrc_status() {
    local dst="$(target_home)/.vimrc"
    if [[ ! -f "$dst" ]]; then echo "missing"
    elif cmp -s "$VIMRC_SRC" "$dst"; then echo "ok"
    else echo "partial: differs from repo copy"
    fi
}

# ---------- bash aliases ----------
aliases_block() {
    cat <<'EOF'
alias cls=clear
alias u='cd ..'
alias u2='cd ../../'
alias u3='cd ../../../'
alias u4='cd ../../../../'
alias u5='cd ../../../../../'
alias u6='cd ../../../../../../'
alias als='vim ~/.bashrc'
alias src='source ~/.bashrc'
alias la='ls -laht'
alias l='ls -laht'
alias dir='ls -laht'
mcd_func() { mkdir -p $1 && cd $1; set +f; }
alias mcd='set -f;mcd_func'
alias m='make'
alias v='vim'
alias h='history'
EOF
}

bash_aliases_apply() {
    local bashrc="$(target_home)/.bashrc"
    # Strip any prior block we previously installed, then append a fresh one.
    if [[ -f "$bashrc" ]] && grep -qF "$ALIASES_BEGIN" "$bashrc"; then
        as_user sed -i "/$ALIASES_BEGIN/,/$ALIASES_END/d" "$bashrc"
    fi
    {
        echo
        echo "$ALIASES_BEGIN"
        aliases_block
        echo "$ALIASES_END"
    } | as_user tee -a "$bashrc" >/dev/null
    echo "wrote alias block to $bashrc"
}

bash_aliases_status() {
    local bashrc current expected
    bashrc="$(target_home)/.bashrc"
    [[ -f "$bashrc" ]] || { echo "missing"; return; }
    if ! grep -qF "$ALIASES_BEGIN" "$bashrc" || ! grep -qF "$ALIASES_END" "$bashrc"; then
        echo "missing"; return
    fi
    current=$(sed -n "/$ALIASES_BEGIN/,/$ALIASES_END/p" "$bashrc" | sed '1d;$d')
    expected=$(aliases_block)
    if [[ "$current" == "$expected" ]]; then echo "ok"
    else echo "partial: block differs from repo definition"
    fi
}

# ---------- registry + menu ----------
ITEMS=(
    "wifi_powersave|Disable WiFi power-save"
    "power_button|Power button -> shutdown (double-press on this OS)"
    "packages|Install base packages (${PACKAGES[*]})"
    "gh_auth|gh auth login + set as git credential helper"
    "git_identity|Set git user.name and user.email"
    "vimrc|Install .vimrc from this repo into ~"
    "bash_aliases|Append shell aliases to ~/.bashrc"
)

show_menu() {
    echo
    echo "Pi5 setup"
    local i=1 entry id label status
    for entry in "${ITEMS[@]}"; do
        id="${entry%%|*}"
        label="${entry#*|}"
        status=$("${id}_status")
        printf "  %d) %-55s [%s]\n" "$i" "$label" "$status"
        i=$((i+1))
    done
    echo
    echo "  a) Apply all     s) Refresh statuses     q) Quit"
}

apply_all() {
    local entry id
    for entry in "${ITEMS[@]}"; do
        id="${entry%%|*}"
        echo "--- ${id} ---"
        "${id}_apply"
    done
}

main_menu() {
    local choice idx entry id
    while true; do
        show_menu
        if ! read -r -p "> " choice; then
            echo
            exit 0
        fi
        case "$choice" in
            q|Q) exit 0 ;;
            s|S) continue ;;
            a|A) apply_all ;;
            ''|*[!0-9]*) echo "invalid choice" ;;
            *)
                idx=$((choice - 1))
                if (( idx < 0 || idx >= ${#ITEMS[@]} )); then
                    echo "out of range"
                    continue
                fi
                entry="${ITEMS[$idx]}"
                id="${entry%%|*}"
                "${id}_apply"
                ;;
        esac
    done
}

main_menu
