#!/bin/bash
# Force a fan floor on the RX 6700s.
#
# Stock behaviour is pwm1_enable=2 (driver curve, zero-RPM idle): fans sit at
# 0 RPM at 72-75 C, then cannot react fast enough to an SDXL load — measured
# 72 -> 96 C between two consecutive 2s samples, and +7 C of overshoot AFTER the
# workload was killed, which is what makes a 110 C SW CTF poweroff reachable.
# With pwm1_enable=1 at this floor the same load climbs gradually and plateaus
# ~92-93 C with no overshoot.
#
# Trade-off: pwm1_enable=1 is manual, so this value is a floor AND a ceiling —
# the fan will not ramp higher on its own. Pick a value that covers your worst
# sustained load. Runs as root (writes sysfs).
set -u

PWM="${GPU_FAN_PWM:-200}"   # 0-255; 200 ~= 78%
MODE="${1:-start}"

# amdgpu creates the hwmon nodes a moment after the driver binds; on a cold boot
# this unit can win the race, so retry rather than silently doing nothing.
for _ in $(seq 1 30); do
  found=0
  for f in /sys/class/drm/card*/device/hwmon/hwmon*/pwm1_enable; do
    [ -e "$f" ] && found=1 && break
  done
  [ "$found" = 1 ] && break
  sleep 1
done

rc=1
for f in /sys/class/drm/card*/device/hwmon/hwmon*/pwm1_enable; do
  [ -e "$f" ] || continue
  h="$(dirname "$f")"
  dev="$(readlink -f "$h/../..")"
  # Only touch amdgpu cards; leave any other hwmon device alone.
  case "$(basename "$(readlink -f "$dev/driver" 2>/dev/null)")" in
    amdgpu) ;;
    *) continue ;;
  esac

  if [ "$MODE" = "stop" ]; then
    # Hand control back to the driver curve.
    echo 2 > "$f" 2>/dev/null && rc=0
    echo "$(basename "$dev"): pwm1_enable=2 (driver curve restored)"
  else
    echo 1 > "$f" 2>/dev/null || { echo "$(basename "$dev"): cannot write $f" >&2; continue; }
    echo "$PWM" > "$h/pwm1" 2>/dev/null || { echo "$(basename "$dev"): cannot write pwm1" >&2; continue; }
    rc=0
    echo "$(basename "$dev"): pwm1_enable=$(cat "$f") pwm1=$(cat "$h/pwm1") rpm=$(cat "$h/fan1_input" 2>/dev/null)"
  fi
done

[ "$rc" = 0 ] || { echo "no amdgpu hwmon nodes written" >&2; exit 1; }
