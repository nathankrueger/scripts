#!/bin/bash
# Sets up SSH client access to r16 (NathanR16, 192.168.1.89) from a Linux/Mac machine.
#
# Two doors into that box:
#   ssh r16   -> port 22, Windows OpenSSH, lands in an interactive WSL shell.
#                Interactive ONLY (scp/sftp/remote commands are broken by design
#                because DefaultShell=wsl.exe rejects sshd's "-c" exec wrapper).
#   ssh r16l  -> port 2222, real Linux sshd inside WSL. scp/sftp/rsync/remote
#                commands all work. Self-waking: if the WSL VM is asleep, the
#                ProxyCommand pokes port 22 to boot it (cold start ~45s).
#
# See the "r16 SSH access" issue in this repo for the full server-side scheme
# and troubleshooting notes.
set -e

R16_IP=192.168.1.89
SSH_DIR="$HOME/.ssh"
CONFIG="$SSH_DIR/config"
PROXY="$SSH_DIR/r16l-proxy.sh"

mkdir -p "$SSH_DIR" && chmod 700 "$SSH_DIR"

# --- self-waking proxy script ---------------------------------------------
cat > "$PROXY" <<'PROXY_EOF'
#!/bin/bash
# Self-waking proxy for r16l (WSL sshd on the r16 Windows box).
# If the WSL VM is asleep (2222 not answering with an SSH banner), a port-22
# login boots it (DefaultShell=wsl.exe) and sshd auto-starts with it. The wake
# session is held open in the background so the VM survives until the real
# connection is established.
H=192.168.1.89
probe() { timeout 3 bash -c "exec 3<>/dev/tcp/$H/2222 && head -c4 <&3" 2>/dev/null | grep -q 'SSH-'; }
if ! probe; then
    ( sleep 45 | timeout 50 ssh -tt -o BatchMode=yes -o ConnectTimeout=5 natek@$H >/dev/null 2>&1 & )
    for i in $(seq 1 15); do probe && break; sleep 2; done
fi
exec nc "$H" 2222
PROXY_EOF
chmod +x "$PROXY"
echo "installed $PROXY"

# --- ~/.ssh/config entries (idempotent) -----------------------------------
if ! grep -q '^Host r16l' "$CONFIG" 2>/dev/null; then
    cat >> "$CONFIG" <<CONFIG_EOF

# Windows box r16, port 22: Windows sshd, lands in WSL shell (interactive only).
Host r16
    HostName $R16_IP
    User natek

# Same box, real Linux sshd inside WSL (port 2222, self-waking).
# Use for scp/sftp/remote commands: scp file r16l:/mnt/c/Users/natek/...
Host r16l
    HostName $R16_IP
    Port 2222
    User nkrueger
    ProxyCommand $PROXY

# Catch-all: ANY tool dialing r16's WSL sshd by raw IP:2222 (publish.sh, rsync,
# scripts with hardcoded addresses) gets the same self-waking proxy. Port-22
# traffic is untouched (also keeps the proxy's own wake call from recursing).
Match host $R16_IP exec "test %p = 2222"
    ProxyCommand $PROXY
CONFIG_EOF
    echo "appended r16/r16l entries to $CONFIG"
else
    echo "r16l entry already present in $CONFIG"
fi
chmod 600 "$CONFIG"

# --- key setup -------------------------------------------------------------
if [ ! -f "$SSH_DIR/id_ed25519" ] && [ ! -f "$SSH_DIR/id_rsa" ]; then
    ssh-keygen -t ed25519 -N "" -f "$SSH_DIR/id_ed25519"
fi
PUBKEY=$(cat "$SSH_DIR/id_ed25519.pub" 2>/dev/null || cat "$SSH_DIR/id_rsa.pub")

if ssh -o BatchMode=yes -o ConnectTimeout=30 r16l true 2>/dev/null; then
    echo "key auth to r16l already works"
else
    echo "Installing your key on r16l (you'll be asked for nkrueger's WSL password once)..."
    ssh-copy-id r16l   # works! (real Linux sshd — unlike port 22)
fi

# Port 22 (Windows side) can't use ssh-copy-id, so plant the key through r16l.
ssh r16l "grep -qF '$PUBKEY' /mnt/c/Users/natek/.ssh/authorized_keys 2>/dev/null || \
    { printf '\n%s\n' '$PUBKEY' >> /mnt/c/Users/natek/.ssh/authorized_keys; echo 'key added for port 22'; }"

# --- verify ----------------------------------------------------------------
echo "--- verifying:"
ssh -o BatchMode=yes r16l "echo '  r16l OK (Linux sshd, scp/sftp ready)'"
echo "  try:  ssh r16   (interactive WSL shell)"
echo "done."
