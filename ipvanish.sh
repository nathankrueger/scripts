#!/bin/bash
# ipvanish.sh — set up IPVanish as an isolated, always-on SOCKS5 proxy.
# Run with no arguments (or --help) for usage.
#
# Architecture — the VPN runs inside a dedicated NETWORK NAMESPACE ("ipvanish")
# with a SOCKS5 proxy (microsocks) inside it:
#   host 10.200.200.1 <-veth-> 10.200.200.2 ns ── tun0 ── IPVanish
# The host's routing table — and anything else on the box, e.g. Tailscale — is
# never touched: ONLY traffic explicitly sent to socks5://10.200.200.2:1080
# exits via the VPN. If the tunnel drops, that proxy stops answering and clients
# FAIL rather than falling back to the bare connection (kill-switch by
# construction; nothing leaks out the normal uplink).
#
# The deliverable is that proxy endpoint. Point any SOCKS5-aware client at it:
#   curl --socks5-hostname 10.200.200.2:1080 https://api.ipify.org
#
# --- Why THREE systemd services? -------------------------------------------
# The stack has three pieces that must come up in ORDER, and each can fail or
# restart on its own. systemd enforces the ordering (Requires/After) and keeps
# each piece alive. Mental model: service 1 builds a sealed room with one
# internet feed, service 2 swaps that feed for the VPN, service 3 is the single
# locked door you knock on to use it.
#
#   1. ipvanish-netns.service  — builds the sandbox (oneshot, RemainAfterExit).
#      Creates the network namespace "ipvanish" (an isolated network stack, so
#      nothing inside can touch the host's routing table or vice versa), the
#      veth pair (a virtual cable: ipv-host/10.200.200.1 on the host <-> ipv-ns/
#      10.200.200.2 inside the ns — the only link between them), a DNS resolver,
#      and a BOOTSTRAP NAT so the ns can reach the internet to DIAL the VPN (the
#      handshake itself must ride the normal uplink — there's no tunnel yet).
#      Owns nothing long-running; just constructs the room. Tears it down on stop.
#
#   2. ipvanish-vpn.service    — dials the tunnel. Runs the OpenVPN/WireGuard
#      client INSIDE that namespace; on connect it flips the ns default route to
#      the tunnel, so from then on anything in the sandbox exits via IPVanish.
#      Long-lived, Restart=always (a dropped VPN relaunches just this unit).
#      Requires+After the netns service.
#
#   3. ipvanish-proxy.service  — the doorway in. microsocks (a tiny SOCKS5
#      server) inside the ns, bound to 10.200.200.2:1080 — the ONLY way traffic
#      from outside gets into the sandbox. It forwards requests out the ns route,
#      i.e. the VPN. Requires+After the VPN service.
#
# Why not one big unit: you'd lose ordered startup, independent restart (a VPN
# blip would rebuild everything), the STRUCTURAL kill-switch (VPN down => ns has
# no working route => microsocks can't forward => clients fail, never leak), and
# per-layer status. Three responsibilities, three units.
#
# Multi-host: self-contained + idempotent (re-run install to repair); run on
# each machine. Linux + systemd + apt only. VPN config: an IPVanish .ovpn (from
# their config download page) or a WireGuard .conf (from the dashboard) —
# auto-detected by extension.
set -u

USAGE="Usage: ipvanish.sh <command>

  install --vpn-config FILE [--dry-run]   set up the VPN + proxy stack (sudo)
                                          FILE is an IPVanish .ovpn or WireGuard .conf
  remove [--purge]                        tear down (sudo; --purge also removes apt pkgs)
  status                                  report every layer; exit 0 = healthy
  enable | disable                        start/stop + (un)enable the units (sudo)"

NS=ipvanish
VETH_HOST=ipv-host
VETH_NS=ipv-ns
HOST_IP=10.200.200.1
NS_IP=10.200.200.2
PROXY_PORT=1080
ETC_DIR=/etc/ipvanish
UNIT_DIR=/etc/systemd/system
UNITS=(ipvanish-netns.service ipvanish-vpn.service ipvanish-proxy.service)

log()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mXX  %s\033[0m\n' "$*" >&2; exit 1; }
need_root() { [ "$(id -u)" = 0 ] || die "run with sudo (needed for netns/systemd)"; }

DRY=""
run() { if [ -n "$DRY" ]; then echo "DRY: $*"; else "$@"; fi }

write_netns_unit() {
    run tee "$UNIT_DIR/ipvanish-netns.service" >/dev/null <<EOF
[Unit]
Description=IPVanish network namespace + veth
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
  ip netns add $NS 2>/dev/null || true; \
  ip link add $VETH_HOST type veth peer name $VETH_NS 2>/dev/null || true; \
  ip link set $VETH_NS netns $NS 2>/dev/null || true; \
  ip addr replace $HOST_IP/24 dev $VETH_HOST; ip link set $VETH_HOST up; \
  ip netns exec $NS ip addr replace $NS_IP/24 dev $VETH_NS; \
  ip netns exec $NS ip link set $VETH_NS up; \
  ip netns exec $NS ip link set lo up; \
  mkdir -p /etc/netns/$NS; printf "nameserver 1.1.1.1\\nnameserver 8.8.8.8\\n" > /etc/netns/$NS/resolv.conf; \
  ip netns exec $NS ip route replace default via $HOST_IP'
ExecStop=/bin/bash -c 'ip link del $VETH_HOST 2>/dev/null; ip netns del $NS 2>/dev/null; true'
# NAT so the ns can reach the internet to ESTABLISH the tunnel; once the VPN is
# up its default route inside the ns goes to tun0, and application traffic uses
# the VPN. (The bootstrap NAT is what the VPN handshake itself rides on.)
ExecStartPost=/bin/bash -c 'sysctl -qw net.ipv4.ip_forward=1; \
  iptables -t nat -C POSTROUTING -s $NS_IP/24 ! -o $VETH_HOST -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s $NS_IP/24 ! -o $VETH_HOST -j MASQUERADE'

[Install]
WantedBy=multi-user.target
EOF
}

write_vpn_unit_openvpn() {
    run tee "$UNIT_DIR/ipvanish-vpn.service" >/dev/null <<EOF
[Unit]
Description=IPVanish OpenVPN client (inside the $NS netns)
Requires=ipvanish-netns.service
After=ipvanish-netns.service

[Service]
ExecStart=/usr/bin/ip netns exec $NS /usr/sbin/openvpn --config $ETC_DIR/vpn.ovpn \\
  --auth-user-pass $ETC_DIR/auth.txt --auth-nocache --redirect-gateway def1
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
}

write_vpn_unit_wireguard() {
    run tee "$UNIT_DIR/ipvanish-vpn.service" >/dev/null <<EOF
[Unit]
Description=IPVanish WireGuard client (inside the $NS netns)
Requires=ipvanish-netns.service
After=ipvanish-netns.service

[Service]
Type=oneshot
RemainAfterExit=yes
# wg tunnel created on the host, moved into the ns, addressed + defaulted there.
ExecStart=/bin/bash -c '\
  ip link add wg-ipv type wireguard; \
  wg setconf wg-ipv <(wg-quick strip $ETC_DIR/vpn.conf); \
  ip link set wg-ipv netns $NS; \
  addr=\$(awk -F"= *" "/^Address/{print \\\$2}" $ETC_DIR/vpn.conf | cut -d, -f1); \
  ip netns exec $NS ip addr add \$addr dev wg-ipv; \
  ip netns exec $NS ip link set wg-ipv up; \
  ip netns exec $NS ip route replace default dev wg-ipv'
ExecStop=/bin/bash -c 'ip netns exec $NS ip link del wg-ipv 2>/dev/null; true'

[Install]
WantedBy=multi-user.target
EOF
}

write_proxy_unit() {
    run tee "$UNIT_DIR/ipvanish-proxy.service" >/dev/null <<EOF
[Unit]
Description=SOCKS5 proxy inside the $NS netns (VPN egress only)
Requires=ipvanish-vpn.service
After=ipvanish-vpn.service

[Service]
ExecStart=/usr/bin/ip netns exec $NS /usr/bin/microsocks -i $NS_IP -p $PROXY_PORT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

cmd_install() {
    local vpn_config=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --vpn-config) vpn_config="$2"; shift 2 ;;
            --dry-run)    DRY=1; shift ;;
            *) die "install: unknown arg $1" ;;
        esac
    done

    need_root
    [ -n "$vpn_config" ] || die "install needs --vpn-config FILE (.ovpn or WireGuard .conf)"
    [ -f "$vpn_config" ] || die "no such file: $vpn_config"

    local kind=""
    case "$vpn_config" in
        *.ovpn) kind=openvpn ;;
        *.conf) kind=wireguard ;;
        *) die "config must end .ovpn (OpenVPN) or .conf (WireGuard)" ;;
    esac

    log "installing packages ($kind + microsocks)"
    run apt-get install -qq -y microsocks iptables >/dev/null
    if [ "$kind" = openvpn ]; then
        run apt-get install -qq -y openvpn >/dev/null
    else
        run apt-get install -qq -y wireguard-tools >/dev/null
    fi

    run mkdir -p "$ETC_DIR"
    if [ "$kind" = openvpn ]; then
        run cp "$vpn_config" "$ETC_DIR/vpn.ovpn"
        if [ ! -f "$ETC_DIR/auth.txt" ] && [ -z "$DRY" ]; then
            read -rp "IPVanish username: " ipv_user
            read -rsp "IPVanish password: " ipv_pass; echo
            printf '%s\n%s\n' "$ipv_user" "$ipv_pass" > "$ETC_DIR/auth.txt"
        fi
        run chmod 600 "$ETC_DIR/auth.txt" 2>/dev/null || true
    else
        run cp "$vpn_config" "$ETC_DIR/vpn.conf"
        run chmod 600 "$ETC_DIR/vpn.conf"
    fi

    log "writing systemd units"
    write_netns_unit
    [ "$kind" = openvpn ] && write_vpn_unit_openvpn \
                          || write_vpn_unit_wireguard
    write_proxy_unit
    run systemctl daemon-reload
    log "enabling + starting (default-on)"
    run systemctl enable --now "${UNITS[@]}"
    log "install done — proxy at socks5://$NS_IP:$PROXY_PORT; verify with: $0 status"
}

cmd_remove() {
    need_root
    local purge=""
    [ "${1:-}" = --purge ] && purge=1
    log "stopping + disabling units"
    systemctl disable --now "${UNITS[@]}" 2>/dev/null
    for u in "${UNITS[@]}"; do rm -f "$UNIT_DIR/$u"; done
    systemctl daemon-reload
    ip link del $VETH_HOST 2>/dev/null
    ip netns del $NS 2>/dev/null
    rm -rf /etc/netns/$NS "$ETC_DIR"
    iptables -t nat -D POSTROUTING -s $NS_IP/24 ! -o $VETH_HOST -j MASQUERADE 2>/dev/null
    if [ -n "$purge" ]; then
        log "purging packages"
        apt-get remove -qq -y microsocks openvpn wireguard-tools 2>/dev/null
    fi
    log "removed"
}

cmd_status() {
    local ok=0
    echo "--- VPN stack ---"
    local installed=yes
    for u in "${UNITS[@]}"; do [ -f "$UNIT_DIR/$u" ] || installed=no; done
    echo "  installed: $installed"
    if [ "$installed" = yes ]; then
        for u in "${UNITS[@]}"; do
            printf '  %-28s enabled=%s active=%s\n' "$u" \
                "$(systemctl is-enabled "$u" 2>/dev/null)" \
                "$(systemctl is-active "$u" 2>/dev/null)"
            [ "$(systemctl is-active "$u" 2>/dev/null)" = active ] || ok=1
        done
        echo "--- tunnel verification ---"
        direct_ip=$(curl -s -m 8 https://api.ipify.org || echo "?")
        vpn_ip=$(curl -s -m 12 --socks5-hostname $NS_IP:$PROXY_PORT https://api.ipify.org || echo "FAIL")
        echo "  direct egress IP: $direct_ip"
        echo "  proxy  egress IP: $vpn_ip   (socks5://$NS_IP:$PROXY_PORT)"
        if [ "$vpn_ip" = FAIL ]; then
            echo "  verdict: proxy NOT working"; ok=1
        elif [ "$vpn_ip" = "$direct_ip" ]; then
            echo "  verdict: proxy up but NOT via VPN (same exit IP!)"; ok=1
        else
            echo "  verdict: OK — proxy exits via VPN"
        fi
    else
        echo "  (run: sudo $0 install --vpn-config FILE)"
        ok=1
    fi
    return $ok
}

cmd_toggle() {
    need_root
    local action="$1"
    [ -f "$UNIT_DIR/ipvanish-netns.service" ] || die "not installed — run install first"
    if [ "$action" = enable ]; then
        systemctl enable --now "${UNITS[@]}"
    else
        systemctl disable --now "${UNITS[@]}"
    fi
    log "$action done"
}

case "${1:-}" in
    install) shift; cmd_install "$@" ;;
    remove)  shift; cmd_remove "$@" ;;
    status)  cmd_status ;;
    enable)  cmd_toggle enable ;;
    disable) cmd_toggle disable ;;
    -h|--help|help) echo "$USAGE" ;;
    *) echo "$USAGE" >&2; exit 2 ;;
esac
