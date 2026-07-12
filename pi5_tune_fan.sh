#!/usr/bin/env bash
#
# pi5_tune_fan.sh — tune the Raspberry Pi 5 built-in fan curve.
#
# The Pi 5 firmware spins the fan based on 4 temperature trip points baked into
# the device tree. The STOCK curve starts the fan at 50°C (122°F), so a Pi with
# an SSD — which idles in the mid-50s°C — runs the fan almost constantly. This
# script raises the trips so the fan is FULLY OFF at idle and only spins under
# sustained load, ramping to full before the 85°C (185°F) throttle point.
#
# Usage:
#   ./pi5_tune_fan.sh            # show current-vs-planned curve, change nothing
#   ./pi5_tune_fan.sh live       # apply NOW via sysfs (instant, reverts on reboot)
#   ./pi5_tune_fan.sh persist    # write to config.txt (permanent, needs reboot)
#
# 'live' and 'persist' need sudo. Run 'live' first to hear the difference, then
# 'persist' once you're happy with the numbers.
#
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# TUNE HERE — the fan curve.
#
# One entry per trip level (0 = first spin-up, 3 = full speed). Edit the numbers
# and re-run. Temps are in °C (what the hardware uses); the °F equivalent is in
# the comment so you can eyeball it. Speed is the PWM value, 0–255.
#
# The fan is FULLY OFF (0 rpm) below FAN_TEMP_C[0]. That first value is your
# "silent below this temp" threshold — raise it for more silence, lower it to
# cool sooner. Keep the top trip under 85°C (185°F) so it beats the throttle.
# ─────────────────────────────────────────────────────────────────────────────
declare -A FAN_TEMP_C   # trip level -> temperature in °C (fan turns ON here)
declare -A FAN_SPEED    # trip level -> PWM 0–255 (fan speed at that trip)

FAN_TEMP_C[0]=65;  FAN_SPEED[0]=75    # 149°F — low   : first spin-up under sustained load
FAN_TEMP_C[1]=70;  FAN_SPEED[1]=125   # 158°F — med
FAN_TEMP_C[2]=75;  FAN_SPEED[2]=175   # 167°F — high
FAN_TEMP_C[3]=80;  FAN_SPEED[3]=250   # 176°F — full  : stays under the 85°C throttle

# ─────────────────────────────────────────────────────────────────────────────
# Internals — you shouldn't need to touch anything below here.
# ─────────────────────────────────────────────────────────────────────────────

# Device-tree fan_temp0..3 correspond to kernel sysfs trip_point_1..4
# (trip_point_0 is the 110°C "critical" shutdown trip, left untouched).
TZONE=/sys/class/thermal/thermal_zone0
FAN_HWMON=$(for h in /sys/class/hwmon/hwmon*; do \
  [[ "$(cat "$h/name" 2>/dev/null)" == "pwmfan" ]] && echo "$h" && break; done)

# Pick the config.txt location: Bookworm moved it under /boot/firmware.
CONFIG=/boot/firmware/config.txt
[[ -f "$CONFIG" ]] || CONFIG=/boot/config.txt

# Managed-block markers so 'persist' can be re-run without piling up duplicates.
BEGIN_MARK="# >>> pi5_tune_fan managed block >>>"
END_MARK="# <<< pi5_tune_fan managed block <<<"

# Unit helpers (awk handles the .5°C the stock curve uses at trip 3).
c_to_f()     { awk -v c="$1" 'BEGIN{printf "%.0f", c*9/5+32}'; }
c_to_milli() { awk -v c="$1" 'BEGIN{printf "%d",   c*1000}'; }
milli_to_f() { awk -v m="$1" 'BEGIN{printf "%.0f", (m/1000)*9/5+32}'; }

# Print one padded table cell + trailing gutter. printf's %-Ns counts BYTES, and
# '°' is a 2-byte UTF-8 char, so any column holding °F comes out short. ${#s}
# counts CHARACTERS in a UTF-8 locale, so we pad by hand off the visible length.
cell() {
  local s="$1" w="$2" n=${#1}
  printf '%s' "$s"
  while (( n < w )); do printf ' '; ((n++)); done
  printf '  '   # column gutter
}

# ── Print the comparison table: what's live now vs. what this script would set ──
print_table() {
  local cur_temp cur_state cur_pwm
  cur_temp=$(cat "$TZONE/temp" 2>/dev/null || echo 0)
  cur_state=$(cat /sys/class/thermal/cooling_device0/cur_state 2>/dev/null || echo '?')
  cur_pwm=$(cat "$FAN_HWMON/pwm1" 2>/dev/null || echo '?')

  echo "CPU now:   $(milli_to_f "$cur_temp")°F   |   fan level: $cur_state/4   |   pwm: $cur_pwm/255"
  echo "Throttle:  185°F (85°C) — keep the top trip below this."
  echo

  # Header + underline, using the same cell widths as the data rows.
  cell "Level" 5; cell "PWM" 4; cell "Current (live)" 15; cell "Planned (script)" 15; echo
  cell "-----" 5; cell "---" 4; cell "--------------" 15; cell "----------------" 15; echo

  # "Off below" row: the fan is silent under the first trip on each side.
  local live0 plan0
  live0=$(milli_to_f "$(cat "$TZONE/trip_point_1_temp")")
  plan0=$(c_to_f "${FAN_TEMP_C[0]}")
  cell "OFF" 5; cell "0" 4; cell "<${live0}°F" 15; cell "<${plan0}°F" 15; echo

  # One row per trip level; read the live value straight from sysfs to compare.
  for i in 0 1 2 3; do
    local live_f plan_f
    live_f=$(milli_to_f "$(cat "$TZONE/trip_point_$((i+1))_temp")")
    plan_f=$(c_to_f "${FAN_TEMP_C[$i]}")
    cell "$i" 5; cell "${FAN_SPEED[$i]}" 4; cell "${live_f}°F" 15; cell "${plan_f}°F" 15; echo
  done
  echo
}

# ── Apply live via sysfs: instant, no reboot, reverts on next boot ──
apply_live() {
  echo "Applying live (sysfs)… reverts on reboot."
  for i in 0 1 2 3; do
    # fan_tempN -> trip_point_(N+1); write millidegrees C.
    echo "$(c_to_milli "${FAN_TEMP_C[$i]}")" | sudo tee "$TZONE/trip_point_$((i+1))_temp" >/dev/null
  done
  echo "Done. Fan will re-evaluate against the new trips within a second or two."
}

# ── Persist to config.txt: permanent, takes effect after a reboot ──
apply_persist() {
  echo "Writing managed block to $CONFIG (permanent, needs reboot)…"
  # Drop any previous managed block so re-runs don't stack up.
  sudo sed -i "/^${BEGIN_MARK}$/,/^${END_MARK}$/d" "$CONFIG"
  {
    echo ""
    echo "$BEGIN_MARK"
    echo "# Quiet fan curve — silent at idle, only ramps under sustained load."
    for i in 0 1 2 3; do
      echo "dtparam=fan_temp$i=$(c_to_milli "${FAN_TEMP_C[$i]}")"
      echo "dtparam=fan_temp${i}_speed=${FAN_SPEED[$i]}"
    done
    echo "$END_MARK"
  } | sudo tee -a "$CONFIG" >/dev/null
  echo "Done. Reboot to apply:  sudo reboot"
}

# ── Dispatch ──
case "${1:-show}" in
  show|status|"") print_table ;;
  live)           print_table; apply_live ;;
  persist)        print_table; apply_persist ;;
  *) echo "usage: $0 [show|live|persist]" >&2; exit 1 ;;
esac
