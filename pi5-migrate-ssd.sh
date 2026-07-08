#!/usr/bin/env bash
# pi5-migrate-ssd.sh — move Pi 5 OS+programs to the 1TB NVMe SSD, leave media on the SD card.
# Media dirs stay on the SD (never copied, never deleted) and are exposed via symlinks.
#
# Full write-up / history: https://github.com/nathankrueger/scripts/issues/2
#
# Two subcommands spanning a reboot:
#   clone   run while booted from the SD   -> clones OS to the SSD, excluding media dirs
#   link    run after rebooting from SSD   -> mounts SD at /mnt/sdcard, symlinks media dirs
#
# DRY-RUN BY DEFAULT. Real actions require --apply. Every destructive command is printed.
set -euo pipefail

# ---- config (real-world values for this Pi, override via env) ----------------
SSD_DEV="${SSD_DEV:-/dev/nvme0n1}"          # 1TB Samsung NVMe (NOT /dev/sda — that's the 4.5TB Passport)
SD_ROOT_PART="${SD_ROOT_PART:-/dev/mmcblk0p2}"
MOUNTPOINT="${MOUNTPOINT:-/mnt/sdcard}"
# Home dirs that stay on the SD and are symlinked. ~/dev, ~/git (code) + dotfiles ride the SSD.
MEDIA_DIRS=(Downloads Music Bookshelf Documents Pictures Videos Desktop Public Templates)
STOP_SERVICES=(qbittorrent.service minidlna.service)
APPLY=0

log()  { printf '>> %s\n' "$*"; }
run()  { if [ "$APPLY" = 1 ]; then eval "$@"; else printf 'DRY: %s\n' "$*"; fi; }
die()  { printf 'ABORT: %s\n' "$*" >&2; exit 1; }

confirm() {  # prompt only matters in --apply mode; dry-run auto-continues
  [ "$APPLY" = 1 ] || { log "(dry-run) would ask: $* [y/N]"; return 0; }
  local ans; read -r -p ">> $* [y/N] " ans </dev/tty || true
  case "$ans" in y|Y|yes|YES) return 0;; *) die "declined by user";; esac
}

real_home() { getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6; }
real_user() { echo "${SUDO_USER:-$USER}"; }

ensure_rpi_clone() {
  if command -v rpi-clone >/dev/null; then
    log "rpi-clone already installed: $(command -v rpi-clone)"
  else
    log "rpi-clone not found — installing billw2/rpi-clone into /usr/local/sbin"
    run "rm -rf /tmp/rpi-clone"
    run "git clone --quiet https://github.com/billw2/rpi-clone.git /tmp/rpi-clone"
    run "install -m 0755 /tmp/rpi-clone/rpi-clone /usr/local/sbin/rpi-clone"
  fi
  patch_rpi_clone
}

# billw2 rpi-clone only adds the 'p' partition separator for mmcblk, not nvme/loop,
# so an NVMe target becomes nvme0n11 instead of nvme0n1p1 and the clone aborts at mkfs/mount.
# Teach it that nvme/loop targets use 'p' too. Idempotent literal replace.
patch_rpi_clone() {
  local rc; rc="$(command -v rpi-clone || echo /usr/local/sbin/rpi-clone)"
  if [ "$APPLY" != 1 ]; then log "DRY: patch $rc for nvme/loop partition naming"; return 0; fi
  [ -f "$rc" ] || return 0
  python3 - "$rc" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'if [[ $dst_disk == *"mmcblk"* ]]'
new = 'if [[ $dst_disk == *"mmcblk"* || $dst_disk == *"nvme"* || $dst_disk == *"loop"* ]]'
if new in s:
    print(">> rpi-clone already patched for nvme/loop")
elif old in s:
    open(p, "w").write(s.replace(old, new, 1))
    print(">> patched rpi-clone for nvme/loop partition naming")
else:
    sys.exit("ABORT: rpi-clone partition-base pattern not found — inspect manually")
PYEOF
}

guard_disk() {
  local dev="$1"
  [ -b "$dev" ] || die "$dev is not a block device"
  [ "$(lsblk -dno TYPE "$dev")" = disk ] || die "$dev is not a whole disk (looks like a partition)"
  local rootsrc; rootsrc="$(findmnt -no SOURCE /)"
  case "$rootsrc" in "$dev"*) die "$dev is the current root device — refusing";; esac
  # extra guard: refuse if the device carries a mounted filesystem (e.g. the Passport)
  local mnts; mnts="$(lsblk -no MOUNTPOINT "$dev" | grep -v '^$' || true)"
  [ -z "$mnts" ] || die "$dev has mounted filesystems ($mnts) — wrong device? refusing"
  log "target $dev: $(lsblk -dno SIZE,MODEL "$dev")"
}

cmd_clone() {
  local home user excl
  home="$(real_home)"; user="$(real_user)"
  ensure_rpi_clone
  guard_disk "$SSD_DEV"

  excl="$(mktemp)"
  for d in "${MEDIA_DIRS[@]}"; do echo "$home/$d" >> "$excl"; done
  log "media dirs excluded from clone (stay on SD, anchored at /):"; sed 's/^/    /' "$excl"

  confirm "Clone OS to $SSD_DEV now (this initializes/overwrites the SSD)?"
  run "systemctl stop ${STOP_SERVICES[*]} 2>/dev/null || true"
  run "rpi-clone ${SSD_DEV#/dev/} --exclude-from='$excl'"
  run "systemctl start ${STOP_SERVICES[*]} 2>/dev/null || true"

  log "----- EEPROM boot order (NVMe must outrank SD) -----"
  run "rpi-eeprom-config | grep -i boot_order || true"
  log "Pi 5 NVMe boot = 6. Ensure BOOT_ORDER lists 6 before 1 (SD)."
  log "To edit by hand:  sudo rpi-eeprom-config --edit   # do NOT let me do this unattended"
}

cmd_link() {
  local home user uuid
  home="$(real_home)"; user="$(real_user)"
  case "$(findmnt -no SOURCE /)" in
    /dev/nvme*|/dev/sda*) : ;;
    *) die "root is still on $(findmnt -no SOURCE /) — reboot from the SSD before linking";;
  esac

  uuid="$(blkid -s UUID -o value "$SD_ROOT_PART")" || die "no SD root fs at $SD_ROOT_PART"
  log "SD root UUID: $uuid  -> mount at $MOUNTPOINT"

  run "mkdir -p '$MOUNTPOINT'"
  if grep -q "$uuid" /etc/fstab; then
    log "fstab already references $uuid — skipping fstab edit"
  else
    confirm "Add nofail ext4 mount for the SD to /etc/fstab?"
    run "printf 'UUID=%s  %s  ext4  defaults,nofail,x-systemd.device-timeout=10  0 2\n' '$uuid' '$MOUNTPOINT' | tee -a /etc/fstab"
    run "systemctl daemon-reload"
  fi

  # Release any desktop automount of the SD (e.g. /media/$user/rootfs) so we don't
  # double-mount the same fs. With the fstab entry present, udisks won't re-grab it.
  while read -r tgt; do
    [ -z "$tgt" ] && continue
    [ "$tgt" = "$MOUNTPOINT" ] && continue
    log "releasing stray SD automount at $tgt"
    run "umount '$tgt'"
  done < <(findmnt -rno TARGET "$SD_ROOT_PART")

  if findmnt -rno TARGET "$SD_ROOT_PART" | grep -qx "$MOUNTPOINT"; then
    log "$SD_ROOT_PART already mounted at $MOUNTPOINT"
  else
    run "mount '$MOUNTPOINT'"
  fi

  for d in "${MEDIA_DIRS[@]}"; do
    local target="$MOUNTPOINT/home/$user/$d" link="$home/$d"
    if [ -L "$link" ] && [ "$(readlink -f "$link")" = "$target" ]; then
      log "$link already correctly linked — skip"; continue
    fi
    [ -e "$link" ] && [ ! -L "$link" ] && [ ! -d "$link" ] && die "$link exists and is not a dir/symlink — refusing"
    run "rmdir '$link' 2>/dev/null || true"
    run "ln -s '$target' '$link'"
  done

  log "----- verify -----"
  run "ls -la '$home'"
  run "findmnt '$MOUNTPOINT' || true"
}

[ "${1:-}" = --apply ] && { APPLY=1; shift; }
case "${1:-}" in
  deps)  ensure_rpi_clone ;;
  clone) cmd_clone ;;
  link)  cmd_link ;;
  *) echo "usage: sudo $0 [--apply] {deps|clone|link}"; echo "  (dry-run unless --apply is given)"; exit 1 ;;
esac
