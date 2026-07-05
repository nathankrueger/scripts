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
# Self-waking, self-holding proxy for r16l (WSL sshd on the r16 Windows box).
#
# WSL2 idle-kills the VM ~60s after the last Windows-side session ends, and
# connections through the WSL-internal sshd do NOT count as activity. So this
# proxy keeps an "anchor" port-22 session (a Windows-side wsl.exe process)
# open for the ENTIRE life of the relayed connection — waking the VM if
# needed and preventing idle-kill mid-transfer. A watcher kills the anchor
# by PID when the relay exits (EOF alone doesn't close a -tt session).
H=192.168.1.89
P=2222
probe() { timeout 3 bash -c "exec 3<>/dev/tcp/$H/$P && head -c4 <&3" 2>/dev/null | grep -q 'SSH-'; }

( while kill -0 $$ 2>/dev/null; do sleep 10; done ) 2>/dev/null | \
    ssh -tt -o BatchMode=yes -o ConnectTimeout=5 "natek@$H" >/dev/null 2>&1 &
ANCHOR=$!
( while kill -0 $$ 2>/dev/null; do sleep 10; done; sleep 15; kill "$ANCHOR" 2>/dev/null ) >/dev/null 2>&1 &

for i in $(seq 1 20); do probe && break; sleep 2; done

# exec keeps our PID as the relay's, so the watcher tracks the relay itself
if command -v nc >/dev/null 2>&1; then
    exec nc "$H" "$P"
fi
exec python3 -c '
import os, select, socket, sys
h, p = sys.argv[1], int(sys.argv[2])
s = socket.create_connection((h, p))
fds = [s.fileno(), 0]
while True:
    r, _, _ = select.select(fds, [], [])
    if s.fileno() in r:
        d = s.recv(65536)
        if not d:
            break
        os.write(1, d)
    if 0 in r:
        d = os.read(0, 65536)
        if not d:
            s.shutdown(socket.SHUT_WR)
            fds.remove(0)
            continue
        s.sendall(d)
' "$H" "$P"
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
